import Foundation

/// The core coordinator. Every mutation funnels through here; it emits `Event`s that the
/// `ControlServer` fans out to subscribed clients. Holds the single source of coordination; ground
/// truth is federated (tasks.json + tmux liveness + git).
public actor OrchestraService {
    public private(set) var config: Config
    let store: TaskStore
    let registry: AgentRegistry
    var worktrees: any WorktreeManaging
    var sessions: any SessionManaging
    let launcher: Launcher
    var resolver: PathResolver

    // Event fan-out.
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    // Per-card monotonic seq guard for snapshot reports.
    var lastSeqStore: [UUID: UInt64] = [:]
    // Pending resume confirmations (resolved by the SessionStart(resume) callback or a timeout).
    var resumeWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Cards currently being revived/restarted — guarded against the liveness reconcile.
    var recovering: Set<UUID> = []

    public init(config: Config,
                store: TaskStore? = nil,
                registry: AgentRegistry = AgentRegistry(),
                worktrees: (any WorktreeManaging)? = nil,
                sessions: (any SessionManaging)? = nil,
                launcher: Launcher? = nil,
                resolver: PathResolver? = nil) {
        self.config = config
        let r = resolver ?? PathResolver(config: config)
        self.resolver = r
        self.store = store ?? TaskStore()
        self.registry = registry
        self.worktrees = worktrees ?? WorktreeManager(config: config, resolver: r)
        self.sessions = sessions ?? SessionManager()
        self.launcher = launcher ?? Launcher(resolver: r)
    }

    // MARK: - Subscriptions / events

    public func subscribe() -> AsyncStream<Event> {
        let sid = UUID()
        return AsyncStream { cont in
            subscribers[sid] = cont
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                _Concurrency.Task { await self.unsubscribe(sid) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    func emit(_ event: Event) {
        for cont in subscribers.values { cont.yield(event) }
    }

    func emitActivity(_ kind: ActivityKind, _ task: Task?, _ source: ActivitySource, _ text: String) {
        let item = ActivityItem(taskId: task?.id, ref: task?.ref(), source: source, kind: kind, text: text)
        emit(.activity(item))
    }

    // MARK: - spawn

    public func spawn(_ input: SpawnInput, source: ActivitySource = .daemon) async throws -> Task {
        let adapter = try registry.get(input.agentId ?? config.defaultAgentId)
        // Security: reject a non-allowlisted repo BEFORE creating anything.
        let realRepo = try resolver.resolveRepo(input.repo)
        let (wt, _) = try worktrees.ensure(repo: realRepo, branch: input.branch)
        let sid = adapter.newSessionId()
        // Resolve the chosen launch id (explicit / config default / adapter's first) to a full model.
        let modelId = input.model ?? config.defaultModel ?? adapter.models().first?.id ?? ""
        let model = adapter.model(for: modelId)
        let startIn = input.startIn ?? .plan
        // No initial prompt → the card is named off the first prompt the user types (titleProvisional),
        // showing the branch as a placeholder until then. A real prompt seeds the title immediately.
        let provisional = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = provisional ? (input.branch.isEmpty ? "New agent" : input.branch)
                                 : titleSeed(from: input.prompt)

        let task = Task(
            title: title, titleProvisional: provisional, desc: "",
            repo: realRepo, branch: input.branch, worktree: wt,
            agentId: adapter.id, model: model, startIn: startIn,
            column: startIn.column, order: 0, status: .running,
            ctxPct: 0, agentSessionId: sid, initialPrompt: input.prompt
        )
        let created = try await store.create(task)

        let ctx = AdapterContext(cwd: wt, repo: realRepo, model: model.id, startIn: startIn,
                                 sessionId: sid, prompt: input.prompt, name: title,
                                 hooksPath: Config.hooksPath)
        try? adapter.prepareToLaunch(ctx)
        try sessions.ensure(created, argv: adapter.start(ctx))

        emit(.taskUpserted(created))
        emitActivity(.spawned, created, source, "Spawned “\(title)”")
        return created
    }

    /// Spawn many at once. A failed entry is recorded (not thrown) so the rest still spawn and the
    /// caller learns exactly which ones failed and why.
    public func batchSpawn(_ inputs: [SpawnInput], source: ActivitySource = .daemon) async -> BatchSpawnResult {
        var spawned: [Task] = []
        var failed: [BatchSpawnFailure] = []
        for (i, input) in inputs.enumerated() {
            do { spawned.append(try await spawn(input, source: source)) }
            catch { failed.append(BatchSpawnFailure(index: i, prompt: input.prompt, error: "\(error)")) }
        }
        return BatchSpawnResult(spawned: spawned, failed: failed)
    }

    // MARK: - steer / move / status / list

    public func send(_ id: UUID, _ message: String) async throws {
        let t = try await require(id)
        try sessions.sendKeys(sessions.sessionName(t.id), text: message, window: "agent")
    }

    @discardableResult
    public func move(_ id: UUID, to column: Column, source: ActivitySource = .daemon) async throws -> Task {
        let updated = try await store.move(id, to: column)
        emit(.taskUpserted(updated))
        emitActivity(.moved, updated, source, "→ \(column.displayName)")
        return updated
    }

    public func status(_ id: UUID) async throws -> TaskStatus {
        let t = try await require(id)
        let running = (try? sessions.isAlive(sessions.sessionName(id))) ?? false
        return TaskStatus(task: t, running: running)
    }

    public func list(_ filter: Column? = nil, includeArchived: Bool = false) async -> [Task] {
        var tasks = await store.all()
        if !includeArchived { tasks = tasks.filter { !$0.archived } }
        if let filter { tasks = tasks.filter { $0.column == filter } }
        return tasks.sorted { ($0.column.rawValue, $0.order) < ($1.column.rawValue, $1.order) }
    }

    public func archivedTasks() async -> [Task] {
        await store.all().filter(\.archived).sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - archive

    public func archive(_ id: UUID, source: ActivitySource = .daemon, removeWorktree: Bool = true) async throws {
        let t = try await require(id)
        try? sessions.kill(sessions.sessionName(id))
        if removeWorktree {
            // Keep the branch; never silently delete a dirty tree — keep the dir if dirty.
            do { try worktrees.remove(worktree: t.worktree, force: false) }
            catch OrchestraError.worktreeDirty { /* keep the worktree on archive */ }
        }
        let updated = try await store.update(id) { $0.status = .done; $0.archived = true }
        lastSeqStore[id] = nil   // the agent is gone; don't leak its seq cursor
        emit(.taskUpserted(updated))
        emitActivity(.archived, updated, source, "Archived “\(updated.title)”")
    }

    // MARK: - shells / exec / sessions

    public func openShell(_ id: UUID) async throws -> ShellTab {
        let t = try await require(id)
        let name = sessions.sessionName(id)
        if try !sessions.isAlive(name) { _ = try sessions.ensure(t, argv: ["/bin/sh"]) }
        let win = try sessions.newShellWindow(name, cwd: t.worktree)
        return ShellTab(window: win, label: win, pwd: t.worktree)
    }

    public func exec(_ id: UUID, _ cmd: String, timeout: Duration? = nil) async throws -> ExecResult {
        let t = try await require(id)
        try resolver.assertAllowed(t.worktree)
        let r = try Proc.run(["sh", "-c", cmd], cwd: t.worktree, timeout: timeout ?? .seconds(120))
        let cap = 256 * 1024
        return ExecResult(stdout: String(r.stdout.prefix(cap)), stderr: String(r.stderr.prefix(cap)), exitCode: r.exitCode)
    }

    public func sessions(_ id: UUID) async throws -> CardSessions {
        let t = try await require(id)
        let adapter = try registry.get(t.agentId)
        let name = sessions.sessionName(id)
        let targets = (try? sessions.windows(name)) ?? []
        let running = !targets.isEmpty
        let ctx = AdapterContext(cwd: t.worktree, model: t.model.id, sessionId: t.agentSessionId,
                                 name: t.title, hooksPath: Config.hooksPath)
        let info = adapter.sessionInfo(ctx, current: t.agentSessionId, prior: t.priorSessionIds)
            ?? AgentSessionInfo(agentId: t.agentId, sessionId: t.agentSessionId, transcriptPath: nil,
                                priorSessionIds: t.priorSessionIds, priorTranscripts: [], resumeCmd: nil)
        return CardSessions(ref: t.ref(), id: t.id, worktree: t.worktree, tmuxSocket: Config.tmuxSocket,
                            session: name, running: running, targets: targets, agent: info)
    }

    public func openInZed(_ id: UUID) async throws {
        let t = try await require(id)
        try launcher.openInZed(t.worktree)
    }

    // MARK: - config

    public func getConfig() -> Config { config }

    @discardableResult
    public func setConfig(_ patch: (inout Config) -> Void) -> Config {
        patch(&config)
        resolver = PathResolver(config: config)
        worktrees = WorktreeManager(config: config, resolver: resolver)
        return config
    }

    // MARK: - helpers

    func require(_ id: UUID) async throws -> Task {
        guard let t = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        return t
    }

    /// Resolve a free-form handle (UUID / shortId / orchestra:// URI) to its current Task.
    public func resolveRef(_ raw: String) async throws -> Task {
        let all = await store.all()
        return try resolve(TaskRef(parsing: raw), in: all)
    }

    // (column display names live on `Column.displayName`)

    public func models(agentId: String? = nil) -> [AgentModel] {
        (try? registry.get(agentId ?? config.defaultAgentId).models()) ?? []
    }

    /// Emit a generic `.command` activity for a public verb arriving over CLI/MCP that doesn't already
    /// emit its own semantic activity (list/status/send/shell/exec/sessions).
    public func logCommand(_ verb: String, ref task: Task?, source: ActivitySource) {
        emitActivity(.command, task, source, "\(verb)\(task.map { " \($0.shortId)" } ?? "")")
    }
}
