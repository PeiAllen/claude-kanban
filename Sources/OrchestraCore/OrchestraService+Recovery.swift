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
    public func resume(_ id: UUID, graceSeconds: Int? = nil, source: ActivitySource = .daemon) async throws -> Task {
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
                                 sessionId: task.agentSessionId, name: task.title, hooksPath: Config.hooksPath,
                                 trustCwd: trustDecision == .trusted)
        guard let sid = task.agentSessionId,
              let info = adapter.sessionInfo(ctx, current: sid, prior: task.priorSessionIds),
              let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp),
              let argv = adapter.resume(ctx) else {
            return try await failResume(id, detail: "transcript gone", source: source)
        }

        // Recreate the session off the actor so a mass revival overlaps (and report() stays serviced).
        try? adapter.prepareToLaunch(ctx)
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(task, argv: argv)
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
                                 name: task.title, hooksPath: Config.hooksPath,
                                 trustCwd: trustDecision == .trusted)
        let launchTask = task
        try? adapter.prepareToLaunch(ctx)
        try await offActor { [sessions] in
            _ = try sessions.kill(sessions.sessionName(id))
            _ = try sessions.ensure(launchTask, argv: adapter.start(ctx))
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
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, hooksPath: Config.hooksPath)
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
