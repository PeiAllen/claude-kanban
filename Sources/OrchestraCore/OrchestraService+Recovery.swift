import Foundation

/// The outcome of awaiting a resume relaunch's confirmation. `.superseded` is distinct from `.timedOut`
/// so a resume displaced by a newer resume for the same card exits quietly (the survivor owns the card)
/// instead of being treated as a failure and marked dead.
enum ResumeOutcome: Sendable { case confirmed, timedOut, superseded }

extension OrchestraService {

    /// Daemon-startup recovery pass. For every non-archived card whose tmux session is not alive
    /// (true for ALL after a reboot; a no-op after a daemon-only crash since the external tmux server
    /// outlived it): resumable cards (agentSessionId + transcript on disk) are revived via a throttled
    /// `resume`; the rest are marked `.dead` (rebootUnrevived). Idempotent.
    public func recoverSessions() async {
        let tasks = await store.all().filter { !$0.archived && $0.status != .dead }
        let grace = config.revivalGraceSeconds
        var jobs: [@Sendable () async -> Void] = []

        // One `tmux list-sessions` instead of an `has-session` per card.
        let aliveNames = Set((try? sessions.list())?.map(\.name) ?? [])

        for t in tasks {
            if aliveNames.contains(sessions.sessionName(t.id)) { continue }   // daemon-crash no-op / still-running
            let id = t.id
            if isResumable(t) {
                jobs.append { _ = try? await self.resume(id, graceSeconds: grace, source: .daemon) }
            } else if t.titleProvisional {
                // Never-prompted (or freshly restarted/cleared): no current-session work to lose and no
                // transcript to resume, so relaunch a blank session rather than killing the card.
                jobs.append { _ = try? await self.restart(id, source: .daemon) }
            } else {
                await markDead(t.id, reason: .rebootUnrevived, detail: nil, source: .daemon)
            }
        }

        guard !jobs.isEmpty else { return }
        let cap = max(1, config.maxConcurrentRevivals)
        // Windowed task group: keep at most `cap` revivals (resume or restart) in flight (start one more
        // each time one finishes). resume is inert until prompted, so the cap only paces process launches.
        await withTaskGroup(of: Void.self) { group in
            var iter = jobs.makeIterator()
            func startNext() {
                guard let job = iter.next() else { return }
                group.addTask { await job() }
            }
            for _ in 0..<cap { startNext() }
            while await group.next() != nil { startNext() }
        }
    }

    /// Revive THIS card's existing session: recreate the tmux session + relaunch `claude --resume`.
    /// Confirmed by the SessionStart(resume) hook calling `report` within the grace window. On success
    /// → `.waiting` + deadReason cleared. On failure → `.dead` (resumeFailed) + throw.
    @discardableResult
    public func resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil,
                       source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)
        let grace = graceSeconds ?? config.revivalGraceSeconds

        // INVARIANT: `recovering` must stay set across kill → ensure → awaitResume so that a stale
        // SessionEnd from the killed process (and the poll's liveness reconcile) is ignored mid-revival
        // — both gate on `!recovering.contains(id)`. Do not narrow this window.
        recovering.insert(id)
        var keepRecoveringAfterReturn = false
        defer { if !keepRecoveringAfterReturn { recovering.remove(id) } }
        // Start clean: drop any confirmation left over from a prior attempt so only THIS relaunch's
        // SessionStart(resume) callback can confirm it.
        pendingResumeConfirmations.remove(id)

        // Pre-check: must have a tracked id whose transcript still exists.
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                 trustCwd: trustDecision == .trusted, seed: seed)
        guard let sid = task.agentSessionId,
              let info = adapter.sessionInfo(ctx, current: sid, prior: task.priorSessionIds),
              let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp),
              let argv = adapter.resume(ctx) else {
            return try await failResume(id, detail: "transcript gone", source: source)
        }

        // Recreate the session off the actor so a mass revival overlaps (and report() stays serviced).
        try? adapter.prepareToLaunch(ctx)
        let env = adapter.env
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(task, argv: argv, env: env)
            }
        } catch {
            return try await failResume(id, detail: "\(error)", source: source)
        }

        // Confirm the relaunch is alive — HOW depends on the agent (capability, never identity):
        switch adapter.capabilities.resumeConfirmation {
        case .sessionStartHook:
            // Wait for the agent's own SessionStart(resume) telemetry (Claude), or time out.
            switch await awaitResume(id, graceSeconds: grace) {
            case .confirmed:
                break
            case .timedOut:
                return try await failResume(id, detail: "no SessionStart callback in \(grace)s", source: source)
            case .superseded:
                // A newer resume(id) took over this card (overlapping kill+relaunch collapse to the latest).
                // Exit quietly WITHOUT markDead or a status write — the surviving resume owns the outcome AND
                // the `recovering` lifecycle (leave it set; do NOT schedule a release here).
                keepRecoveringAfterReturn = true
                return task
            }
        case .relaunchLiveness:
            // No resume marker exists (e.g. `codex resume` writes no rollout at resume time); the successful
            // `ensure` above IS the confirmation. Do NOT wait for a hook that never comes — that would time
            // out and fail-DANGEROUSLY kill a live idle card. reconcileLiveness catches a relaunch that died.
            break
        }
        keepRecoveringAfterReturn = true
        scheduleRecoveringRelease(id, after: grace)

        let updated = try await store.update(id) {
            $0.status = .waiting; $0.deadReason = nil; $0.deadDetail = nil
        }
        emit(.taskUpserted(updated))
        emitActivity(.recovered, updated, source, "resumed “\(updated.title)”")
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
    @discardableResult
    public func restart(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)

        recovering.insert(id)
        // On the error path, release immediately; on success we hand off to a delayed release (below) so
        // the killed old process's stale SessionEnd is absorbed during a grace window.
        var launched = false
        defer { if !launched { recovering.remove(id) } }

        // Same capability gate as spawn: only a `.seeded` agent mints a fresh id on restart.
        let freshId: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     freshId = adapter.newSessionId()
        case .discovered: freshId = nil
        }
        // Build the new task state first so the launch uses the new id.
        var prior = task.priorSessionIds
        if let old = task.agentSessionId, !old.isEmpty { prior.append(old) }

        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 startIn: task.startIn, sessionId: freshId, prompt: nil,
                                 name: task.title, orchestraBin: orchestraBin,
                                 trustCwd: trustDecision == .trusted)
        let launchTask = task
        try? adapter.prepareToLaunch(ctx)
        let env = adapter.env
        let startArgv = adapter.start(ctx)
        try await offActor { [sessions] in
            _ = try sessions.kill(sessions.sessionName(id))
            _ = try sessions.ensure(launchTask, argv: startArgv, env: env)
        }
        // The fresh session is up: keep `recovering` set across a grace window (instead of dropping it
        // on return) so a late SessionEnd from the process we just killed is ignored, not treated as the
        // NEW session exiting. See scheduleRecoveringRelease / resume's kill→ensure→grace invariant.
        launched = true
        scheduleRecoveringRelease(id, after: config.revivalGraceSeconds)

        let updated = try await store.update(id) {
            $0.agentSessionId = freshId
            $0.priorSessionIds = prior
            $0.status = .waiting
            $0.titleProvisional = true
            $0.deadReason = nil
            $0.deadDetail = nil
            $0.desc = ""
        }
        emit(.taskUpserted(updated))
        emitActivity(.recovered, updated, source, "new session “\(updated.title)”")
        return updated
    }

    /// Reopen an archived (Done) card: recreate the run dir the archive reclaimed, put the card back on
    /// the board (keeps its column), and bring the agent back — `resume` its transcript when resumable,
    /// else a fresh `restart` in the recreated tree. Idempotent: a non-archived card is returned as-is.
    /// Agent-agnostic — it reuses the same `resume`/`restart` primitives every adapter already implements.
    @discardableResult
    public func reopen(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await require(id)
        guard t.archived else { return t }

        // Give the resumed agent its cwd back — archive removed it (branch kept for .worktree cards).
        switch t.origin {
        case .worktree:
            _ = try worktrees.ensure(repo: t.repo, branch: t.branch)
        case .scratch:
            try? FileManager.default.createDirectory(atPath: t.cwd, withIntermediateDirectories: true)
        case .borrowed:
            break   // never removed on archive
        }

        // Back on the board (original column preserved); clear any stale dead state before reviving.
        let unarchived = try await store.update(id) {
            $0.archived = false; $0.status = .waiting; $0.deadReason = nil; $0.deadDetail = nil
        }
        emit(.taskUpserted(unarchived))
        emitActivity(.recovered, unarchived, source, "Reopened “\(unarchived.title)”")

        // resume keeps the transcript; a card whose transcript is gone gets a fresh blank session.
        if isResumable(unarchived) {
            return try await resume(id, source: source)
        } else {
            return try await restart(id, source: source)
        }
    }

    /// Background poll's continuous liveness reconcile (safety net when no SessionEnd fires). A
    /// non-archived, non-done/dead card whose tmux session vanished → `.dead` (sessionVanished),
    /// guarded against cards mid-resume/restart.
    public func reconcileLiveness() async {
        let tasks = await store.all()
        // One `tmux list-sessions` per poll tick, not one `has-session` per card.
        let aliveNames = Set((try? sessions.list())?.map(\.name) ?? [])
        for t in tasks where !t.archived && t.status != .dead && t.status != .done {
            if recovering.contains(t.id) { continue }
            // A freshly-spawned card is watched for an immediate exit BEFORE the generic vanish check: its
            // session is still present (remain-on-exit kept the dead pane), so `aliveNames` can't see the
            // abort — only the pane state can. This branch also graduates a card that survived its grace.
            if let deadline = spawnPending[t.id] {
                await confirmSpawnStartup(t, deadline: deadline)
                continue
            }
            if !aliveNames.contains(sessions.sessionName(t.id)) {
                await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
            }
        }
    }

    /// Resolve a startup-pending card by inspecting its `agent` pane (remain-on-exit keeps a dead one
    /// visible):
    ///  • `.alive` past its deadline → GRADUATE: clear remain-on-exit + drop pending (normal monitoring
    ///    resumes, so a later exit vanishes the session and reads as `.sessionVanished` as before).
    ///  • `.alive` before its deadline → keep watching.
    ///  • `.dead` (session present, pane process exited) → STARTUP ABORT → capture evidence + bounded retry
    ///    / mark dead.
    ///  • `.gone` (session absent — a deliberate kill or a lost remain-on-exit race) → hand to the normal
    ///    `.sessionVanished` path (revivable), NOT a startup abort, and never re-spawned (don't fight a kill).
    func confirmSpawnStartup(_ t: Task, deadline: Date) async {
        let id = t.id
        let name = sessions.sessionName(id)
        let state = (try? await offActor { [sessions] in try sessions.agentPaneState(name) }) ?? .gone
        switch state {
        case .alive:
            guard Date() >= deadline else { return }   // still within grace — keep watching
            try? await offActor { [sessions] in try? sessions.setRemainOnExit(name, window: "agent", on: false) }
            clearSpawnPending(id)
        case .dead:
            await handleStartupAbort(t)
        case .gone:
            clearSpawnPending(id)
            await markDead(id, reason: .sessionVanished, detail: nil, source: .daemon)
        }
    }

    /// A startup abort: capture the dying pane's final output as evidence, then bounded-retry the launch
    /// (an immediate exit is usually a transient launch hiccup) or give up with `.spawnExitedImmediately`.
    /// The retry re-`ensure`s the SAME session + cwd (kill-then-ensure — no double-create, no worktree churn).
    private func handleStartupAbort(_ t: Task) async {
        let id = t.id
        let name = sessions.sessionName(id)
        let evidence = (try? await offActor { [sessions] in
            (try? sessions.capture(name, window: "agent", maxChars: 4096))?.text
        }).flatMap { Self.startupEvidence(from: $0) }

        let attempt = spawnAttempts[id] ?? 0
        if attempt < maxStartupRetries,
           let spec = spawnRelaunch[id],
           let adapter = try? registry.get(spec.adapterId) {
            spawnAttempts[id] = attempt + 1
            try? adapter.prepareToLaunch(spec.ctx)
            let env = adapter.env
            let argv = adapter.start(spec.ctx)
            let launchTask = t
            do {
                try await offActor { [sessions] in
                    _ = try sessions.kill(name)                      // reap the dead-pane session first
                    _ = try sessions.ensure(launchTask, argv: argv, env: env)
                    try? sessions.setRemainOnExit(name, window: "agent", on: true)
                }
                spawnPending[id] = Date().addingTimeInterval(Double(spawnGraceSeconds))
                emitActivity(.recovered, t, .daemon,
                             "restarted “\(t.title)” after a startup abort (retry \(attempt + 1))")
                return
            } catch {
                clearSpawnPending(id)
                await markDead(id, reason: .spawnExitedImmediately,
                               detail: evidence ?? "\(error)", source: .daemon)
                return
            }
        }
        // Out of retries → give up. Reap the dead-pane session, then mark dead WITH the captured evidence.
        clearSpawnPending(id)
        try? await offActor { [sessions] in try? sessions.kill(name) }
        await markDead(id, reason: .spawnExitedImmediately, detail: evidence, source: .daemon)
    }

    /// Drop a card's startup-pending bookkeeping (on graduation, give-up, or any death).
    func clearSpawnPending(_ id: UUID) {
        spawnPending[id] = nil; spawnAttempts[id] = nil; spawnRelaunch[id] = nil
    }

    /// Test hook: tighten the startup-confirmation grace + retry budget (production uses the defaults).
    func setStartupConfirmation(graceSeconds: Int, maxRetries: Int) {
        spawnGraceSeconds = graceSeconds; maxStartupRetries = maxRetries
    }

    /// Distil captured pane text to its meaningful tail (last few non-empty lines), trimmed + capped, so
    /// `deadDetail` surfaces the real error ("usage limit", "unauthorized", a config parse error) not noise.
    static func startupEvidence(from pane: String) -> String? {
        let lines = pane.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(6).joined(separator: " | ").prefix(500))
    }

    // MARK: - helpers

    /// Whether a card can be resumed. Capability-gated (design §5): resumability is an adapter answer
    /// keyed on `capabilities.sessionId` + `sessionInfo`, NOT a hardcoded `~/.claude` transcript stat in
    /// core. Both current variants require a stored session id and the adapter's own state path to be
    /// present on disk; a discovered agent with no id short-circuits.
    func isResumable(_ t: Task) -> Bool {
        guard let adapter = try? registry.get(t.agentId) else { return false }
        switch adapter.capabilities.sessionId {
        case .seeded, .discovered:
            guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, orchestraBin: orchestraBin)
            guard let statePath = adapter.sessionInfo(ctx, current: sid, prior: t.priorSessionIds)?.transcriptPath
            else { return false }
            return FileManager.default.fileExists(atPath: statePath)
        }
    }

    @discardableResult
    private func failResume(_ id: UUID, detail: String, source: ActivitySource) async throws -> Task {
        await markDead(id, reason: .resumeFailed, detail: detail, source: source)
        throw OrchestraError.resumeFailed(detail)
    }

    /// Remove `id` from `recovering` (actor-isolated) — the target of a delayed release.
    func releaseRecovering(_ id: UUID) { recovering.remove(id) }

    /// Keep `id` in `recovering` for `seconds`, then release it. Used by `restart` so a stale `SessionEnd`
    /// from the just-killed old process (delivered out-of-band shortly after restart returns) is ignored
    /// instead of re-killing the fresh session as `.agentExited`. Mirrors `resume`'s kill→ensure→grace
    /// window, which `restart` otherwise lacked.
    func scheduleRecoveringRelease(_ id: UUID, after seconds: Int) {
        _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(max(0, seconds)))
            await self?.releaseRecovering(id)
            await self?.wakeIfPending(id)   // deliver a send that no-op'd at wake gate A during this window
        }
    }

    /// Deliver an inbox that a `send`/inbox-add queued WHILE this card was in the `recovering` grace window
    /// — its `wake` no-op'd at gate A and, uniquely, nothing else retries it (a running card's Stop-drain,
    /// a not-yet-resumable card's next turn, and a watching parent's reinvoke all cover their own gates).
    /// Called once the window closes. `wake` re-checks every gate, so this is a no-op unless there is a
    /// genuinely stranded message, and it self-terminates: the resumed turn drains the inbox.
    func wakeIfPending(_ id: UUID) async {
        guard let t = await store.get(id), t.status == .waiting, !t.archived,
              !(await inbox.peek(id)).isEmpty else { return }
        await wake(id)
    }

    func markDead(_ id: UUID, reason: DeadReason, detail: String?, source: ActivitySource) async {
        guard let updated = try? await store.update(id, {
            $0.status = .dead; $0.deadReason = reason; $0.deadDetail = detail
        }) else { return }
        clearSpawnPending(id)   // a dead card is never startup-pending (covers give-up + any other death)
        emit(.taskUpserted(updated))
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
    }

    private func awaitResume(_ id: UUID, graceSeconds: Int) async -> ResumeOutcome {
        // The confirmation may already have landed while we were relaunching off-actor (see
        // `pendingResumeConfirmations`). Consume it synchronously — before registering a waiter —
        // so an early callback confirms instantly instead of waiting out (or timing out) the grace.
        // This block and the registration below run without an intervening `await`, so no callback
        // can slip between the check and the registration on this serialized actor.
        if pendingResumeConfirmations.remove(id) != nil { return .confirmed }
        resumeTokenSeq &+= 1
        let token = resumeTokenSeq
        return await withCheckedContinuation { (cont: CheckedContinuation<ResumeOutcome, Never>) in
            // A second resume for this id must NEVER leak the earlier continuation: resolve the displaced
            // waiter `.superseded` (the newer resume now owns the session + `recovering` lifecycle). Without
            // this, `resumeWaiters[id] = …` would drop the old continuation unresumed → that resume() hangs
            // forever → `recovering` sticks → `wake` no-ops every future send (the idle-Claude bug).
            if let old = resumeWaiters[id] { old.cont.resume(returning: .superseded) }
            resumeWaiters[id] = (token, cont)
            let grace = max(0, graceSeconds)
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(grace))
                await self?.timeoutResume(id, token: token)
            }
        }
    }

    func resolveResume(_ id: UUID, _ ok: Bool) {
        if let w = resumeWaiters.removeValue(forKey: id) {
            w.cont.resume(returning: ok ? .confirmed : .timedOut)
        } else if ok {
            // No waiter yet: `awaitResume` hasn't registered (resume() is still relaunching off-actor).
            // Remember this confirmation so the waiter picks it up rather than losing the wakeup.
            pendingResumeConfirmations.insert(id)
        }
    }

    /// Time out ONLY the waiter this timer was scheduled for. A newer resume that superseded it (or a
    /// confirmation that already resolved it) advanced the slot's token, so a stale timer is a no-op —
    /// it must never resolve an unrelated, still-pending waiter.
    private func timeoutResume(_ id: UUID, token: UInt64) {
        guard let w = resumeWaiters[id], w.token == token else { return }
        resumeWaiters.removeValue(forKey: id)
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
