/// Serializes all normalized observations for one card and rejects positively identified events
/// from a turn that has already been superseded, so delayed activity for prompt A cannot mutate
/// prompt B after B has started.
///
/// `submit` is ONE-WAY BY DESIGN: it appends and returns as soon as the actor hop completes — it does
/// NOT wait for `apply` to run. This is load-bearing, not an oversight. `apply` ultimately calls
/// `OrchestraService.transition`, which calls `reconcileAgentObservation`
/// (`OrchestraService+Lifecycle.swift`), which — whenever a card's observation identity is rebuilt
/// (boot adoption, a Claude `/clear` session-id rollover) — calls back into THIS actor's `submit` while
/// `drain()` is still suspended awaiting that very `apply`. A blocking `submit` (the previous
/// `CheckedContinuation` design) deadlocks the instant that nested call lands: only `drain()` can
/// resume the continuation, and `drain()` is the one suspended waiting for it. Same failure shape as
/// `gen_server:call` to self in OTP (`calling_self`) and `dispatch_sync` on the current queue in GCD.
///
/// Ordering and the correlation fence (`filter`, below) are unaffected: they come from the FIFO
/// `submissions` array plus `isDraining` serializing the drain loop, never from a caller blocking on
/// its own submission — so a one-way `submit` loses nothing but the wait.
///
/// This is the same shape `armNativeInbox` (`OrchestraService+NativeInbox.swift`) already uses for an
/// identical problem (a per-card FIFO, an async apply, multiple producers) with no continuation at all.
/// `BranchLineage`'s op-serialization gate (`BranchLineage.swift`, "op serialization") solves a
/// DIFFERENT reentrancy hazard the same way `armNativeInbox` doesn't: it keeps ONE gated public entry
/// point but gives its own internal cross-calls (`set` -> `ancestors`) ungated private methods, so
/// nothing ever re-enters the gate. That two-shape pattern does not fit here — the seam that goes
/// re-entrant (`reconcileAgentObservation`) is reachable from arbitrary external callers too (a live
/// hook), not only from this actor's own internals, so there is no clean "private, ungated" twin to
/// hand it. A second, non-blocking entry point alongside a blocking one would also just be a
/// mixed-mode hazard: whichever caller picks the blocking shape reintroduces the deadlock. One-way for
/// every caller is the only shape with no wrong door.
///
/// Termination note (now load-bearing, since nothing else bounds a re-entrant chain): the nested
/// `reconcileAgentObservation` call terminates because `reconcileAgentObservation` writes the card's
/// new `agentObservationIdentity` BEFORE it submits (`OrchestraService+AgentObservation.swift`), so a
/// second, immediately-following `reconcileAgentObservation` for the same card sees a matching identity
/// and takes its early-return branch instead of submitting again. Do not reorder that write after the
/// submit, and do not restore the continuation.
actor AgentObservationCoordinator {
    private struct Submission: Sendable {
        let scope: AgentSignalContext
        let signals: [AgentSignal]
        let apply: @Sendable ([AgentSignal]) async -> Void
    }

    private var submissions: [Submission] = []
    private var isDraining = false
    private var scope: AgentSignalContext?
    private var activeTurnID: String?
    private var lastCompletedTurnID: String?

    /// Exact and race-free: `submissions.append` and `isDraining = true` below have no suspension point
    /// between them, so there is no window where a nested submit (appended while `isDraining` is still
    /// true) could be missed. Tests use this to restore the old "wait for the submission to land"
    /// contract without reintroducing a blocking `submit`.
    var isIdle: Bool { !isDraining && submissions.isEmpty }

    func submit(
        scope: AgentSignalContext,
        signals: [AgentSignal],
        apply: @escaping @Sendable ([AgentSignal]) async -> Void
    ) async {
        guard !signals.isEmpty else { return }

        submissions.append(.init(scope: scope, signals: signals, apply: apply))
        guard !isDraining else { return }
        isDraining = true
        _Concurrency.Task { await self.drain() }
    }

    private func drain() async {
        while !submissions.isEmpty {
            let submission = submissions.removeFirst()
            let accepted = filter(submission.signals, in: submission.scope)
            if !accepted.isEmpty {
                await submission.apply(accepted)
            }
        }
        isDraining = false
    }

    private func filter(
        _ signals: [AgentSignal],
        in newScope: AgentSignalContext
    ) -> [AgentSignal] {
        if scope != newScope {
            scope = newScope
            activeTurnID = nil
            lastCompletedTurnID = nil
        }

        return signals.compactMap(accept)
    }

    private func accept(_ signal: AgentSignal) -> AgentSignal? {
        switch signal.kind {
        case .turnStarted:
            guard let turnID = currentTurnID(signal) else { return nil }
            guard activeTurnID != turnID else { return nil }
            activeTurnID = turnID
            lastCompletedTurnID = nil
            return signal

        case .turnActivity:
            guard let turnID = currentTurnID(signal) else { return nil }
            // Activity for the active prompt is state-silent, while activity from another prompt is
            // stale until the active prompt completes.
            guard activeTurnID == nil else { return nil }

            // Exact activity after completion proves a blocked Stop continuation. A different valid
            // identity proves a distinct turn whose UserPromptSubmit edge was not observable.
            let isSameTurnContinuation = lastCompletedTurnID == turnID
            activeTurnID = turnID
            lastCompletedTurnID = nil
            if isSameTurnContinuation { return signal }
            return .init(sessionEpoch: signal.sessionEpoch, turnID: turnID, kind: .turnStarted)

        case .turnCompleted:
            guard let turnID = currentTurnID(signal) else {
                activeTurnID = nil
                lastCompletedTurnID = nil
                return .init(sessionEpoch: signal.sessionEpoch, kind: .observationLost)
            }
            if let activeTurnID {
                guard activeTurnID == turnID else { return nil }
                self.activeTurnID = nil
                lastCompletedTurnID = turnID
                return signal
            }
            if lastCompletedTurnID == turnID {
                return signal
            }
            lastCompletedTurnID = nil
            return .init(sessionEpoch: signal.sessionEpoch, kind: .observationLost)

        case .humanNeedChanged(let humanNeed):
            guard let turnID = currentTurnID(signal) else { return nil }
            if let activeTurnID {
                return activeTurnID == turnID ? signal : nil
            }
            // A terminal event may clear its own need immediately after completing the turn. A
            // delayed positive fact must never resurrect a completed prompt.
            if humanNeed == nil, lastCompletedTurnID == turnID {
                return signal
            }
            return nil

        case .activity:
            guard let turnID = currentTurnID(signal), activeTurnID == turnID else { return nil }
            return signal

        case .observationLost:
            activeTurnID = nil
            lastCompletedTurnID = nil
            return signal

        case .turnReconciled(let status, _):
            // A current-session running snapshot refines the active turn without erasing an exact ID that
            // event notifications already established. If there is no active ID, the snapshot represents
            // an uncorrelated open turn and any older completed-turn history is no longer usable. Codex
            // reports idle before turn/completed, so a waiting snapshot closes the active fence but keeps
            // its ID long enough to recognize the matching terminal notification as a duplicate.
            switch status {
            case .running:
                if activeTurnID == nil { lastCompletedTurnID = nil }
            case .waiting:
                if let activeTurnID { lastCompletedTurnID = activeTurnID }
                activeTurnID = nil
            case .unavailable:
                activeTurnID = nil
                lastCompletedTurnID = nil
            }
            return signal
        }
    }

    private func currentTurnID(_ signal: AgentSignal) -> String? {
        guard let turnID = signal.turnID, !turnID.isEmpty else { return nil }
        return turnID
    }
}
