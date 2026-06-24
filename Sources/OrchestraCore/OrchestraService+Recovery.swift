import Foundation

extension OrchestraService {

    /// Daemon-startup recovery pass. For every non-archived card whose tmux session is not alive
    /// (true for ALL after a reboot; a no-op after a daemon-only crash since the external tmux server
    /// outlived it): resumable cards (agentSessionId + transcript on disk) are revived via a throttled
    /// `resume`; the rest are marked `.dead` (rebootUnrevived). Idempotent.
    public func recoverSessions() async {
        let tasks = await store.all().filter { !$0.archived && $0.status != .dead }
        var toRevive: [UUID] = []

        for t in tasks {
            let alive = (try? sessions.isAlive(sessions.sessionName(t.id))) ?? false
            if alive { continue }   // daemon-crash no-op / still-running card
            if isResumable(t) {
                toRevive.append(t.id)
            } else {
                await markDead(t.id, reason: .rebootUnrevived, detail: nil, source: .daemon)
            }
        }

        guard !toRevive.isEmpty else { return }
        let cap = max(1, config.maxConcurrentRevivals)
        let grace = config.revivalGraceSeconds
        // Bounded-concurrency drain: at most `cap` resume() calls outstanding at once.
        await withTaskGroup(of: Void.self) { group in
            var iter = toRevive.makeIterator()
            var inFlight = 0
            func startNext() {
                guard let id = iter.next() else { return }
                inFlight += 1
                group.addTask { _ = try? await self.resume(id, graceSeconds: grace, source: .daemon) }
            }
            for _ in 0..<cap { startNext() }
            while inFlight > 0 {
                await group.next()
                inFlight -= 1
                startNext()
            }
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

        recovering.insert(id)
        defer { recovering.remove(id) }

        // Pre-check: must have a tracked id whose transcript still exists.
        let ctx = AdapterContext(cwd: task.worktree, model: task.model, sessionId: task.agentSessionId,
                                 name: task.title, hooksPath: Config.hooksPath)
        guard let sid = task.agentSessionId,
              let info = adapter.sessionInfo(ctx, current: sid, prior: task.priorSessionIds),
              let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp),
              let argv = adapter.resume(ctx) else {
            return try await failResume(id, detail: "transcript gone", source: source)
        }

        // Recreate the session off the actor so a mass revival overlaps (and report() stays serviced).
        let task2 = try await require(id)
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(task2, argv: argv)
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

        let freshId = adapter.newSessionId()
        // Build the new task state first so the launch uses the new id.
        var prior = task.priorSessionIds
        if let old = task.agentSessionId, !old.isEmpty { prior.append(old) }

        let ctx = AdapterContext(cwd: task.worktree, model: task.model, startIn: task.startIn,
                                 sessionId: freshId, prompt: nil, name: task.title,
                                 hooksPath: Config.hooksPath)
        let launchTask = task
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
        for t in tasks where !t.archived && t.status != .dead && t.status != .done {
            if recovering.contains(t.id) { continue }
            let alive = (try? sessions.isAlive(sessions.sessionName(t.id))) ?? false
            if !alive {
                await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
            }
        }
    }

    // MARK: - helpers

    func isResumable(_ t: Task) -> Bool {
        guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
        let adapter = (try? registry.get(t.agentId))
        let ctx = AdapterContext(cwd: t.worktree, sessionId: sid, name: t.title, hooksPath: Config.hooksPath)
        guard let tp = adapter?.sessionInfo(ctx, current: sid, prior: t.priorSessionIds)?.transcriptPath
        else { return false }
        return FileManager.default.fileExists(atPath: tp)
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
