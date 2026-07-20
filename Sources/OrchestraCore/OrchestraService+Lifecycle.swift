import Foundation

/// Outcome of a `transition` funnel call.
/// - `.applied`  — the edge was legal and the phase (plus companion `mutate` writes) was persisted.
/// - `.noop`     — nothing to do (same-phase idempotency, an unknown card, or a stale-epoch signal).
/// - `.rejected` — the edge is not in the legal set; the stored phase is left untouched.
public enum TransitionResult: Equatable, Sendable {
    case applied
    case noop
    case rejected(from: Phase, to: Phase)
}

extension OrchestraService {

    /// Merge the `ORCH_EPOCH` generation stamp into an adapter's launch env (agent-agnostic — the value
    /// rides the tmux `-e` env at every launch call site, and the agent's hooks echo it back on `_report`).
    func withEpoch(_ env: [String: String], _ epoch: Int) -> [String: String] {
        var e = env
        e["ORCH_EPOCH"] = String(epoch)
        return e
    }

    // MARK: - Stage 2 · the single phase-transition funnel

    /// The ONE writer of `Task.phase` (Stage 2 convergence). Every lifecycle mover — spawn, launch,
    /// liveness, restart/resume, archive (rerouted in 2.4/2.5) — routes its phase change through here so
    /// the legal-edge invariant, the epoch bump, conclusions, and wake-on-live all live in one place.
    ///
    /// - Parameters:
    ///   - to: the target phase.
    ///   - observedEpoch: non-nil ⇒ this is a *signal* (a liveness poll / late hook) carrying the epoch
    ///     it observed. It admits the `dead → live` revival edge AND is fenced against a stale generation
    ///     (a signal from a superseded session is dropped). nil ⇒ a verb-driven transition.
    ///   - mutate: companion field-writes applied INSIDE the same `store.update` patch as the phase write,
    ///     so they land atomically with it (restart clears `agentSessionId`, handoff sets `pendingSeed`,
    ///     spawn-fail sets `deadDetail`, …). Consumed by 2.4/2.5.
    ///   - expecting: non-nil ⇒ apply ONLY if the card is still in this phase kind. The epoch fence below
    ///     cannot cover a supersede that leaves the generation alone — `markDead` (e.g. the launch timeout)
    ///     does not bump `sessionEpoch`, and `dead → live` is a legal revival edge, so a bring-up that was
    ///     dispatched at `.launching`, timed out of the board, and only THEN had its readiness confirmed
    ///     would otherwise flip the card back to `.live` — re-animating a card whose conclusion a parent's
    ///     `wait` has already been told. The steppers pass the phase they were dispatched for, so the
    ///     landing carries the same single-winner fence as the bring-up.
    @discardableResult
    func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil, expecting: Phase.Kind? = nil,
                    mutate: @Sendable (inout Task) -> Void = { _ in }) async -> TransitionResult {
        guard let card = await store.get(id) else { return .noop }
        let from = card.phase

        // 0 · The dispatched-phase fence (see `expecting`): the card left the phase this write was computed
        //     for, so a newer owner has it — drop the write rather than resurrect a stale landing.
        if let expecting, from.kind != expecting { return .noop }

        // 1 · Idempotency — but the `relaunching → relaunching` supersede self-edge must NOT be swallowed
        //     (it re-arms a fresh generation), so it falls through to apply.
        if to == from && from.kind != .relaunching { return .noop }

        // 2 · A signal carries the epoch it observed (`viaSignal`); a verb-driven transition carries none.
        //     Fence out a superseded generation: a signal whose `observedEpoch` no longer matches the card's
        //     `sessionEpoch` is from a session we've since torn down/relaunched, so it is dropped. This is
        //     what makes a late/stale liveness signal harmless. The NIL-epoch kill-class discipline (a
        //     pre-upgrade signal with no epoch must be probed for real liveness before it may kill) is gated
        //     at the signal's call site — `report()`'s SessionEnd `isAlive` probe — NOT here, because
        //     internal deliberate classifications (`markDead`) are not signals and must not be second-guessed.
        let viaSignal = (observedEpoch != nil)
        if let observedEpoch, observedEpoch != card.sessionEpoch { return .noop }

        // 3 · Reject anything outside the legal edge set; the stored phase is untouched.
        guard Self.isLegalEdge(from: from, to: to, viaSignal: viaSignal) else {
            FileHandle.standardError.write(Data(
                "orchestra: rejected illegal phase transition \(from) → \(to) for card \(id)\n".utf8))
            return .rejected(from: from, to: to)
        }

        // 4 · One field-delta patch: phase + timestamp + epoch bump + companion writes, atomically.
        let updated: Task, rev: Int
        do {
            (updated, rev) = try await store.update(id) { t in
                let transitionAt = Date()
                t.phase = to
                t.phaseChangedAt = transitionAt
                // Bump the generation on every (re)launch entry — spawn's `creatingWorktree`, reopen's
                // `creatingWorktree`, and every `relaunching` entry INCLUDING the supersede self-edge.
                // `launching` is intentionally omitted (the machine only enters it from the already-bumped
                // `creatingWorktree`); revisit this predicate if a direct-entry-to-`launching` edge is added.
                if to.kind == .creatingWorktree || to.kind == .relaunching { t.sessionEpoch += 1 }
                mutate(&t)
                // A discovered agent can reach `.live` through N=3 before its rollout metadata appears.
                // Keep the launch boundary until an id binds so a later telemetry tick can reject stale cwd
                // history while still accepting its own delayed rollout.
                if to.kind == .creatingWorktree {
                    t.sessionDiscoverySince = nil
                } else if to.kind == .launching || to.kind == .relaunching {
                    t.sessionDiscoverySince = t.agentSessionId == nil ? transitionAt : nil
                } else if to.kind == .live, t.agentSessionId != nil {
                    t.sessionDiscoverySince = nil
                }
            }
        } catch {
            return .noop   // unknown card raced away between the load and the patch
        }

        // Temporary media follows the same session boundary as the transition itself. Run this only after
        // the durable state write succeeds: a failed/rejected transition must never erase a still-current
        // reference, while a new epoch or archive intent invalidates prior data immediately.
        if to.kind == .creatingWorktree || to.kind == .relaunching {
            // FIRST, before any unrelated cleanup. This is the one EAGER lease-invalidation duty an
            // epoch bump owes (contract §lease-lifecycle): prior-epoch leases are re-owned LAZILY by
            // the next claim, but a parked poll must die NOW — while `removePriorEpochs` suspends, an
            // in-flight `wake` holding the pre-bump epoch could still push into that stale poll, and
            // the resulting ack deletes a batch the superseded session never received. `epoch:` is
            // the POST-bump value (bumped inside the update above) and the comparison is strictly
            // `<`, so the generation that just claimed is never revoked.
            await broker.revokeOlderEpochs(updated.id, epoch: updated.sessionEpoch)
            // The attach-grace stamp is PER-GENERATION: a new session must get a full fresh window in
            // which its pump can reconnect. Reusing the old expired stamp would cold-restart the
            // brand-new session on its first queued message (B4 attach-grace).
            channelUnattachedSince[updated.id] = nil
            await mediaStore.removePriorEpochs(cardId: updated.id, keeping: updated.sessionEpoch)
        } else if to.kind == .archivedPending {
            await mediaStore.removeCard(updated.id)
        }

        // 5 · Conclusions — the funnel is the sole concluder. Only the ENTRY into a terminal phase from a
        //     non-terminal one concludes; `dead → archived` (terminal → terminal) is guarded out.
        if !from.isTerminal, to.isTerminal, let c = Self.terminalConclusion(for: to) {
            await concludeCard(id, c.kind, deadReason: c.deadReason)
        }

        // 6 · Broadcast the new state FIRST — before any wake. `wake` may record a `.relaunching`
        //     intent INLINE (B4: it holds `deliveriesInFlight` across the ladder, so it no longer
        //     detaches), and that nested transition emits its own upsert. Broadcasting this `.live`
        //     one first keeps the pair in causal order (`.live` then `.relaunching`) instead of
        //     inverted. Recursion is bounded by `deliveriesInFlight`: a nested wake sees the outer
        //     claim and returns at once.
        emit(.taskUpserted(updated), rev: rev)

        // 7 · Wake-on-live — the single structural release point for a message parked while the card
        //     was provisioning. `wakeIfPending` gates on `hasClaimable`, so a card holding a `.ticks`
        //     relaunchSeed lease is left alone (B3 D5) and a `.live(.running)` entry falls through.
        if to.kind == .live { await wakeIfPending(id) }
        return .applied
    }

    /// The `(kind, deadReason)` a terminal phase concludes with — or nil if `phase` is non-terminal.
    /// `.done` (archived / a completed retire) carries no `deadReason`; any other dead reason concludes
    /// `.exited` and carries the reason (so `wait` resolves on every terminal reason — the bug-#2 fix).
    static func terminalConclusion(for phase: Phase) -> (kind: Conclusion.Kind, deadReason: DeadReason?)? {
        switch phase {
        case .archived: return (.done, nil)
        case .dead(let r): return r == .completed ? (.done, nil) : (.exited, r)
        default: return nil
        }
    }

    /// The legal phase-transition edge set (§P1 / 01-design's stateDiagram) — a PURE function of the two
    /// kinds plus the `viaSignal` gate. `viaSignal` admits ONLY the `dead → live` revival (no verb may
    /// drive it); every other edge ignores it. Everything not enumerated here is illegal.
    static func isLegalEdge(from: Phase, to: Phase, viaSignal: Bool) -> Bool {
        switch (from.kind, to.kind) {
        // Provisioning.
        case (.creatingWorktree, .launching): return true
        case (.launching, .live): return true
        // Live sub-state churn + restart entry.
        case (.live, .live): return true
        case (.live, .relaunching): return true
        // Relaunch: supersede self-edge + up to live/dead/archived.
        case (.relaunching, .relaunching): return true
        case (.relaunching, .live): return true
        // Restart of a dead card + the signal-gated revival.
        case (.dead, .relaunching): return true
        case (.dead, .live): return viaSignal
        // Archive teardown false→true (only) + reopen from either archived kind.
        case (.archivedPending, .archivedComplete): return true
        case (.archivedPending, .creatingWorktree), (.archivedComplete, .creatingWorktree): return true
        // Any non-archived phase may die.
        case (.creatingWorktree, .dead), (.launching, .dead), (.live, .dead), (.relaunching, .dead):
            return true
        // Any non-archived phase may be archived — but ONLY into `.archivedPending` (the archive INTENT).
        // A card reaches `.archivedComplete` SOLELY via `archivedPending → archivedComplete` (above, the
        // TeardownStepper's final flip) — the direct `(X, .archivedComplete)` edges are removed (PR4b Task 4:
        // archive is intent-only, so nothing drives a non-`archivedPending` phase straight to complete; the
        // migration seeds `.archivedComplete` in `Task.init` decode, which is not a funnel edge).
        case (.creatingWorktree, .archivedPending),
             (.launching, .archivedPending),
             (.live, .archivedPending),
             (.relaunching, .archivedPending),
             (.dead, .archivedPending):
            return true
        default:
            return false
        }
    }
}
