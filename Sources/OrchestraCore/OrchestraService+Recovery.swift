import Foundation

/// The outcome of awaiting a relaunch's inline readiness confirmation. `.superseded` is distinct from
/// `.timedOut` so a relaunch displaced by a newer relaunch for the same card exits quietly (the survivor
/// owns the card) instead of being treated as a failure and marked dead.
public enum ReadinessOutcome: Sendable { case confirmed, timedOut, superseded }

/// How spawn / reopen bring the agent session up once the card is being walked to `.live`. `.blank`
/// starts a fresh session (readiness is the successful `ensure` — the 2.5 sync-spawn readiness stub;
/// dedicated signals arrive in 2.6) and lands on the given run-state. `.resume` relaunches the vendor
/// transcript and confirms readiness via `awaitReadiness` (the SessionStart(resume) hook / relaunch
/// liveness), landing `.waiting`.
public enum LaunchFlavor: Sendable {
    case blank(landing: RunState, prompt: String?)
    case resume(seed: String?)
}

extension OrchestraService {

    /// INTENT-ONLY (PR4b Task 4): record the relaunch intent (`transition(→ .relaunching)` — bumps the
    /// generation, the atomic single-winner claim + closes the ghost-SessionEnd window) and RETURN. The
    /// reconciler's `RelaunchStepper` drives the walk: re-materializes a missing worktree, kills+ensures the
    /// session off-actor, confirms readiness (capability-gated), and finalizes `→ .live` epoch-fenced (a
    /// relaunch superseded by a newer one no-ops its finalize; a genuine failure → `.dead(.resumeFailed)`).
    /// A `seed` (handoff / seeded-wake) is persisted as `pendingSeed` in the SAME patch (carried #1 write
    /// side); the RelaunchStepper consumes + clears it on readiness. No subprocess runs before the return.
    @discardableResult
    public func resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil,
                       source: ActivitySource = .daemon) async throws -> Task {
        _ = try await require(id)
        // The `relaunching → relaunching` supersede self-edge is legal, so a newer relaunch bumps the epoch
        // again and an earlier attempt's finalize is dropped by the epoch fence (single-winner discipline).
        _ = await transition(id, to: .relaunching, mutate: { t in
            t.deadReason = nil; t.deadDetail = nil
            if let seed { t.pendingSeed = seed }   // folded handoff/wake seed rides the relaunch (carried #1)
        })
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, updated, source, "resuming “\(updated.title)”")
        return updated
    }

    /// F1 (C3) — resume THIS card into a fresh process with CLEAN context, seeded with the handoff/fork
    /// context AND its pending inbox (folded into one seed delivered as the resumed session's opening
    /// turn). This is **resume, not a blank restart**: `agentSessionId` is KEPT, so the vendor transcript
    /// carries forward and the seed adds new context to a continued session. The inbox "folds into the
    /// seed" (design §8 F1) — drained BEFORE resume so the queued messages ride the opening turn, and are
    /// not double-delivered by a later Stop-drain. This is F1 (handoff) AND the idle-wake path for a
    /// `.relaunch` agent (`resumeSeedWake`). Backs D1's `handoff` Command.
    @discardableResult
    public func resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil,
                             source: ActivitySource = .daemon) async throws -> Task {
        let drained = (try? await inbox.drain(id)) ?? []
        let folded = HandoffSeed.fold(handoff: seed, inbox: drained)
        return try await resume(id, graceSeconds: graceSeconds, seed: folded, source: source)
    }

    /// Start a NEW blank session for a (dead or live) card in the SAME worktree. Fresh id, no prompt
    /// re-handed; status → waiting, titleProvisional → true. Never touches worktree contents.
    ///
    /// INTENT-ONLY (PR4b Task 4): `transition(→ .relaunching, mutate:)` carries the real persist block
    /// (fresh id, rolled prior ids, provisional, cleared dead/desc) atomically with the phase write, then
    /// RETURNS. The reconciler's `RelaunchStepper` blank-launches the fresh id (capability-gated — it goes
    /// through `confirmReadiness`, never an immediate `.live`). The `relaunching → relaunching` supersede
    /// self-edge + `inFlightSteps` give verb-vs-verb restart a single-winner (carried #5).
    @discardableResult
    public func restart(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)

        // Same capability gate as spawn: only a `.seeded` agent mints a fresh id on restart.
        let freshId: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     freshId = adapter.newSessionId()
        case .discovered: freshId = nil
        }
        var priorIds = task.priorSessionIds
        if let old = task.agentSessionId, !old.isEmpty { priorIds.append(old) }
        let prior = priorIds

        // Enter `.relaunching` with the REAL persist block applied atomically (bumps the generation — a stale
        // signal from the prior session is epoch-fenced; a provisional card blank-restarts under the stepper).
        _ = await transition(id, to: .relaunching, mutate: {
            $0.agentSessionId = freshId
            $0.priorSessionIds = prior
            $0.titleProvisional = true
            $0.deadReason = nil
            $0.deadDetail = nil
            $0.desc = ""
            $0.pendingSeed = nil   // a blank restart carries no seed
        })
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, updated, source, "new session “\(updated.title)”")
        return updated
    }

    /// Reopen an archived (Done) card: put the card back on the board (keeps its column) and bring the agent
    /// back — `resume` its transcript when resumable, else a fresh blank launch in the recreated tree.
    /// Idempotent: a non-archived card is returned as-is.
    ///
    /// INTENT-ONLY (PR4b Task 4): enter `.creatingWorktree` (bumps the generation — closes the ghost
    /// SessionEnd window), unarchiving, and RETURN. The reconciler's `MaterializeStepper` re-cuts the run dir
    /// the archive reclaimed → `LaunchStepper` brings the agent up (resume vs blank re-derived from the
    /// persisted fields by `deriveLaunchFlavor`), its `.live` finalize `observedEpoch`-fenced (carried #5:
    /// epoch-fence reopen resume-finalize). No `.dead(.completed)→.archived` normalize is needed — after the
    /// intent-only archive + the migration seeds, an archived card is ALWAYS `.archived(_)`, so the
    /// `archivedPending/archivedComplete → creatingWorktree` reopen edge applies directly.
    @discardableResult
    public func reopen(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await require(id)
        guard t.archived else { return t }
        let adapter = try registry.get(t.agentId)
        let resumable = await isResumable(t)

        // Enter `.creatingWorktree` (bumps the generation), clearing the archived Bool + dead metadata. The
        // resume path keeps the id so the transcript carries forward; the blank path mints a fresh id / rolls
        // prior ids / resets provisional+desc (restart semantics), so `deriveLaunchFlavor` derives a blank launch.
        if resumable {
            _ = await transition(id, to: .creatingWorktree, mutate: {
                $0.archived = false; $0.deadReason = nil; $0.deadDetail = nil
            })
        } else {
            let freshId: String?
            switch adapter.capabilities.sessionId {
            case .seeded:     freshId = adapter.newSessionId()
            case .discovered: freshId = nil
            }
            var priorIds = t.priorSessionIds
            if let old = t.agentSessionId, !old.isEmpty { priorIds.append(old) }
            let prior = priorIds
            _ = await transition(id, to: .creatingWorktree, mutate: {
                $0.archived = false
                $0.agentSessionId = freshId
                $0.priorSessionIds = prior
                $0.titleProvisional = true
                $0.desc = ""
                $0.deadReason = nil
                $0.deadDetail = nil
            })
        }
        guard let reopening = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, reopening, source, "Reopened “\(reopening.title)”")
        return reopening
    }

    /// Confirm a being-born card (launch OR relaunch) is alive — HOW depends on the agent (capability, never
    /// identity). `.sessionStartHook` waits for the agent's own SessionStart telemetry (Claude), or times
    /// out. `.rolloutMeta` ALSO waits (Codex): a fresh launch's rollout `session_meta` line resolves the
    /// waiter via the tail observer; a `codex resume` writes no rollout, so the N=3 `launchReadyTicks`
    /// fallback resolves it within the grace — either way it stays ON the readiness gate (never immediate,
    /// which would leave no waiter and bypass the gate). `.relaunchLiveness` takes the successful `ensure`
    /// as the confirmation because the agent emits no marker at all, so it must NOT wait for one.
    func confirmReadiness(_ id: UUID, adapter: any Adapter, graceSeconds: Int) async -> ReadinessOutcome {
        switch adapter.capabilities.readinessConfirmation {
        case .sessionStartHook, .rolloutMeta: return await awaitReadiness(id, graceSeconds: graceSeconds)
        case .relaunchLiveness:                return .confirmed
        }
    }

    /// Background poll's continuous liveness reconcile (safety net when no SessionEnd fires). Phase-gated:
    /// the being-born phases (`.creatingWorktree`, `.relaunching`, `.launching`) are NEVER killed here — their
    /// session is legitimately absent mid-bring-up and each is owned by a SYNCHRONOUS launch/relaunch that
    /// handles its own readiness + spawnFailed timeout; killing them would race the owner's own
    /// `transition`→`ensure` window and false-kill a live spawn. Only a `.live` card whose session vanished is
    /// concluded (crashed → `.dead(.sessionVanished)`). Terminal cards are excluded outright. Deaths that DO
    /// fire route through the funnel (`markDead`) so they conclude.
    public func reconcileLiveness() async {
        let tasks = await store.all()
        // One `tmux list-sessions` per poll tick, not one `has-session` per card. Hopped off-actor
        // (mirrors `reconcile()`'s hop exactly) so this slow tmux probe never freezes the actor.
        let s = sessions
        let aliveNames = Set((try? await offActor { try? s.list() })??.map(\.name) ?? [])
        for t in tasks where !t.phase.isTerminal {
            let alive = aliveNames.contains(sessions.sessionName(t.id))
            switch t.phase.kind {
            case .creatingWorktree:
                launchReadyTicks[t.id] = nil   // not yet awaiting readiness — nothing to tick
                continue   // being born — the session is legitimately not up yet
            case .relaunching:
                // A relaunch's session IS up once `ensure` returned (resume/restart bring it up off-actor),
                // but the phase stays `.relaunching` until the inline waiter resolves. If the session is
                // live and a waiter is still pending, tick the N=3 fallback (covers Codex `codex resume`
                // with no rollout, a missed hook). Never markDead a relaunching card (its absence is legit).
                if alive { tickLaunchReady(t.id) } else { launchReadyTicks[t.id] = nil }
                continue
            case .launching:
                // Being born under the reconciler-driven LaunchStepper, which owns readiness; the reconcile tick owns
                // the spawnFailed launch timeout via `phaseChangedAt`. Mirror `.relaunching`: tick the N=3 fallback while
                // a waiter is pending; NEVER markDead here — killing a launching card races the launch's own
                // `transition(.launching)`→`ensure` window and would false-kill a live spawn.
                if alive { tickLaunchReady(t.id) } else { launchReadyTicks[t.id] = nil }
                continue
            case .live:
                launchReadyTicks[t.id] = nil   // reached live — reset the being-born counter
                if !alive {
                    await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
                }
            case .dead, .archivedPending, .archivedComplete:
                launchReadyTicks[t.id] = nil
                continue   // terminal — excluded by `isTerminal`, but keep the switch exhaustive
            }
        }
    }

    /// N=3 readiness fallback tick (see `launchReadyTicks`). Only counts while an inline waiter is actually
    /// pending; at the threshold it resolves that waiter so the verb reaches `.live` before the await's grace
    /// timeout would fail it. No pending waiter → reset (e.g. a `.relaunchLiveness` restart that never awaits,
    /// or the instant after the waiter already resolved).
    private func tickLaunchReady(_ id: UUID) {
        guard readinessWaiters[id] != nil else { launchReadyTicks[id] = nil; return }
        let n = (launchReadyTicks[id] ?? 0) + 1
        if n >= launchReadyTickThreshold {
            launchReadyTicks[id] = nil
            resolveReadiness(id, true)
        } else {
            launchReadyTicks[id] = n
        }
    }

    // MARK: - helpers

    /// Whether a card can be resumed. Capability-gated (design §5): resumability is an adapter answer
    /// keyed on `capabilities.sessionId` + `sessionInfo`, NOT a hardcoded `~/.claude` transcript stat in
    /// core. Both current variants require a stored session id and the adapter's own state path to be
    /// present on disk; a discovered agent with no id short-circuits.
    func isResumable(_ t: Task) async -> Bool {
        guard let adapter = try? registry.get(t.agentId) else { return false }
        switch adapter.capabilities.sessionId {
        case .seeded, .discovered:
            guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, orchestraBin: orchestraBin)
            let a = adapter, priorIds = t.priorSessionIds
            return (try? await offActor {
                guard let statePath = a.sessionInfo(ctx, current: sid, prior: priorIds)?.transcriptPath
                else { return false }
                return FileManager.default.fileExists(atPath: statePath)
            }) ?? false
        }
    }

    /// Deliver an inbox that a `send`/inbox-add queued WHILE this card was mid-relaunch — its `wake` no-op'd
    /// (the `relaunchClaimed` gate / a non-`.live` phase) and, uniquely, nothing else retries it (a running
    /// card's Stop-drain, a not-yet-resumable card's next turn, and a watching parent's reinvoke all cover
    /// their own gates). Called once the relaunch settles (`clearRelaunchClaimed`). `wake` re-checks every
    /// gate, so this is a no-op unless there is a genuinely stranded message, and it self-terminates: the
    /// resumed turn drains the inbox.
    func wakeIfPending(_ id: UUID) async {
        guard let t = await store.get(id), case .live(.waiting) = t.phase, !t.archived,
              !(await inbox.peek(id)).isEmpty else { return }
        await wake(id)
    }

    /// The single terminal-death classifier. Routes through the funnel so a non-terminal → terminal death
    /// fires `concludeCard` (bug-#2 fix — a suspended `wait` resolves on a crash/reboot/resume-fail death,
    /// not just a clean exit). Callers pass a DELIBERATE classification (aliveNames miss / a fresh liveness
    /// probe / a definitive resume failure), so this transitions with `observedEpoch: nil` — exempt from
    /// the nil-epoch kill-probe gate (which lives at the inbound-SessionEnd signal site).
    func markDead(_ id: UUID, reason: DeadReason, detail: String?, source: ActivitySource) async {
        let result = await transition(id, to: .dead(reason), mutate: {
            $0.deadReason = reason; $0.deadDetail = detail
        })
        guard result == .applied, let updated = await store.get(id) else { return }
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
    }

    private func awaitReadiness(_ id: UUID, graceSeconds: Int) async -> ReadinessOutcome {
        // The confirmation may already have landed while we were relaunching off-actor (see
        // `pendingReadiness`). Consume it synchronously — before registering a waiter — so an early callback
        // confirms instantly instead of waiting out (or timing out) the grace. This block and the
        // registration below run without an intervening `await`, so no callback can slip between the check
        // and the registration on this serialized actor.
        if pendingReadiness.remove(id) != nil { return .confirmed }
        readinessTokenSeq &+= 1
        let token = readinessTokenSeq
        return await withCheckedContinuation { (cont: CheckedContinuation<ReadinessOutcome, Never>) in
            // A second relaunch for this id must NEVER leak the earlier continuation: resolve the displaced
            // waiter `.superseded` (the newer relaunch now owns the session). Without this,
            // `readinessWaiters[id] = …` would drop the old continuation unresumed → that relaunch hangs
            // forever → the idle card can never be woken again.
            if let old = readinessWaiters[id] { old.cont.resume(returning: .superseded) }
            readinessWaiters[id] = (token, cont)
            let grace = max(0, graceSeconds)
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(grace))
                await self?.timeoutReadiness(id, token: token)
            }
        }
    }

    func resolveReadiness(_ id: UUID, _ ok: Bool) {
        if let w = readinessWaiters.removeValue(forKey: id) {
            w.cont.resume(returning: ok ? .confirmed : .timedOut)
        } else if ok {
            // No waiter yet: `awaitReadiness` hasn't registered (the relaunch is still bringing the session
            // up off-actor). Remember this confirmation so the waiter picks it up rather than losing it.
            pendingReadiness.insert(id)
        }
    }

    /// Time out ONLY the waiter this timer was scheduled for. A newer relaunch that superseded it (or a
    /// confirmation that already resolved it) advanced the slot's token, so a stale timer is a no-op —
    /// it must never resolve an unrelated, still-pending waiter.
    private func timeoutReadiness(_ id: UUID, token: UInt64) {
        guard let w = readinessWaiters[id], w.token == token else { return }
        readinessWaiters.removeValue(forKey: id)
        w.cont.resume(returning: .timedOut)
    }

    /// Run a synchronous (possibly slow: git/tmux/process-launch) closure off the actor so the actor
    /// keeps servicing `report` and parallel revivals genuinely overlap.
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }
}
