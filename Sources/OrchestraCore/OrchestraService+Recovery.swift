import Foundation

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
        defer { recovering.remove(id) }

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

        // Await the SessionStart(resume) callback (resolved in report()) or time out.
        let confirmed = await awaitResume(id, graceSeconds: grace)
        guard confirmed else {
            return try await failResume(id, detail: "no SessionStart callback in \(grace)s", source: source)
        }

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
    /// seed" (design §8 F1) — drained BEFORE resume so a `.sessionSeed` agent (Codex, no Stop hook) still
    /// receives its queued messages, and they are not double-delivered by a later Claude Stop-drain.
    /// Backs D1's `handoff` Command.
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
        defer { recovering.remove(id) }

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
            if !aliveNames.contains(sessions.sessionName(t.id)) {
                await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
            }
        }
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

    func markDead(_ id: UUID, reason: DeadReason, detail: String?, source: ActivitySource) async {
        guard let updated = try? await store.update(id, {
            $0.status = .dead; $0.deadReason = reason; $0.deadDetail = detail
        }) else { return }
        emit(.taskUpserted(updated))
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
    }

    private func awaitResume(_ id: UUID, graceSeconds: Int) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            resumeWaiters[id] = cont
            let grace = max(0, graceSeconds)
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(grace))
                await self?.timeoutResume(id)
            }
        }
    }

    func resolveResume(_ id: UUID, _ ok: Bool) {
        if let cont = resumeWaiters.removeValue(forKey: id) { cont.resume(returning: ok) }
    }

    private func timeoutResume(_ id: UUID) { resolveResume(id, false) }

    /// Run a synchronous (possibly slow: git/tmux/process-launch) closure off the actor so the actor
    /// keeps servicing `report` and parallel revivals genuinely overlap.
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }
}
