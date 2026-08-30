/// Serializes all normalized observations for one card and rejects positively identified events
/// from a turn that has already been superseded. Claude hooks and OTLP share this path, so a delayed
/// terminal span for prompt A cannot close prompt B after B has started.
actor AgentObservationCoordinator {
    private struct Submission: Sendable {
        let scope: AgentSignalContext
        let signals: [AgentSignal]
        let apply: @Sendable ([AgentSignal]) async -> Void
        let continuation: CheckedContinuation<Void, Never>
    }

    private var submissions: [Submission] = []
    private var isDraining = false
    private var scope: AgentSignalContext?
    private var activeTurnID: String?
    private var lastCompletedTurnID: String?

    func submit(
        scope: AgentSignalContext,
        signals: [AgentSignal],
        apply: @escaping @Sendable ([AgentSignal]) async -> Void
    ) async {
        guard !signals.isEmpty else { return }

        await withCheckedContinuation { continuation in
            submissions.append(.init(
                scope: scope,
                signals: signals,
                apply: apply,
                continuation: continuation
            ))
            guard !isDraining else { return }
            isDraining = true
            _Concurrency.Task { await self.drain() }
        }
    }

    private func drain() async {
        while !submissions.isEmpty {
            let submission = submissions.removeFirst()
            let accepted = filter(submission.signals, in: submission.scope)
            if !accepted.isEmpty {
                await submission.apply(accepted)
            }
            submission.continuation.resume()
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
            // an uncorrelated open turn and any older completed-turn history is no longer usable. Waiting
            // and unavailable snapshots retire all turn-pair history.
            if case .running = status {
                if activeTurnID == nil { lastCompletedTurnID = nil }
            } else {
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
