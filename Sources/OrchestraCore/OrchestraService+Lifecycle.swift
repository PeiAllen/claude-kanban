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
    @discardableResult
    func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil,
                    mutate: @Sendable (inout Task) -> Void = { _ in }) async -> TransitionResult {
        guard let card = await store.get(id) else { return .noop }
        let from = card.phase

        // 1 · Idempotency — but the `relaunching → relaunching` supersede self-edge must NOT be swallowed
        //     (it re-arms a fresh generation), so it falls through to apply.
        if to == from && from.kind != .relaunching { return .noop }

        // 2 · A signal carries the epoch it observed. Fence out a stale generation (finalized in 2.4).
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
                t.phase = to
                t.phaseChangedAt = Date()
                // Bump the generation on every (re)launch entry — spawn's `creatingWorktree`, reopen's
                // `creatingWorktree`, and every `relaunching` entry INCLUDING the supersede self-edge.
                // `launching` is intentionally omitted (the machine only enters it from the already-bumped
                // `creatingWorktree`); revisit this predicate if a direct-entry-to-`launching` edge is added.
                if to.kind == .creatingWorktree || to.kind == .relaunching { t.sessionEpoch += 1 }
                mutate(&t)
            }
        } catch {
            return .noop   // unknown card raced away between the load and the patch
        }

        // 5 · Conclusions — the funnel is the sole concluder. Only the ENTRY into a terminal phase from a
        //     non-terminal one concludes; `dead → archived` (terminal → terminal) is guarded out.
        if !from.isTerminal, to.isTerminal, let c = Self.terminalConclusion(for: to) {
            await concludeCard(id, c.kind, deadReason: c.deadReason)
        }

        // 6 · Wake-on-live — the single structural release point for a message parked while the card was
        //     provisioning. `wakeIfPending` is a no-op unless the card is now `.live(.waiting)` with a
        //     non-empty inbox, so a `.live(.running)` entry harmlessly falls through.
        if to.kind == .live { await wakeIfPending(id) }

        // 7 · Broadcast the new state.
        emit(.taskUpserted(updated), rev: rev)
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
        // Any non-archived phase may be archived (into either teardown state).
        case (.creatingWorktree, .archivedPending), (.creatingWorktree, .archivedComplete),
             (.launching, .archivedPending), (.launching, .archivedComplete),
             (.live, .archivedPending), (.live, .archivedComplete),
             (.relaunching, .archivedPending), (.relaunching, .archivedComplete),
             (.dead, .archivedPending), (.dead, .archivedComplete):
            return true
        default:
            return false
        }
    }
}
