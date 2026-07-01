import Foundation

/// The core coordinator. Every mutation funnels through here; it emits `Event`s that the
/// `ControlServer` fans out to subscribed clients. Holds the single source of coordination; ground
/// truth is federated (tasks.json + tmux liveness + git).
public actor OrchestraService {
    public private(set) var config: Config
    let store: TaskStore
    let trust: TrustLedger
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
                resolver: PathResolver? = nil,
                trust: TrustLedger? = nil) {
        self.config = config
        let r = resolver ?? PathResolver(config: config)
        self.resolver = r
        self.store = store ?? TaskStore()
        self.trust = trust ?? TrustLedger()
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

    // MARK: - trust

    /// Resolve trust for a launch from the card's origin (provider-agnostic). The result rides on
    /// `AdapterContext.trustCwd`; the adapter *applies* it and never reads the ledger.
    /// - `scratch`  → auto-trust (Orchestra made it empty) + record.
    /// - `worktree` → inherit the source repo's trust; registering a repo to run agents IS the trust
    ///   act, so record the repo (idempotent) and trust the worktree.
    /// - `borrowed` → trusted iff the cwd is already in the ledger; else `needsGrant` (human grant is T2).
    public func resolveTrust(origin: CardOrigin, cwd: String, repo: String?) async -> TrustDecision {
        switch origin {
        case .scratch:
            _ = try? await trust.record(cwd, grantedBy: .orchestra)
            return .trusted
        case .worktree:
            if let repo { _ = try? await trust.record(repo, grantedBy: .repoRegistration) }
            return .trusted
        case .borrowed:
            return await trust.isTrusted(cwd) ? .trusted : .needsGrant
        }
    }

    // MARK: - spawn

    public func spawn(_ input: SpawnInput, source: ActivitySource = .daemon) async throws -> Task {
        let adapter = try registry.get(input.agentId ?? config.defaultAgentId)
        // The card id is generated up front so a scratch spawn can name its dir after the card.
        let id = UUID()
        // Scratch vs freeform (borrowed) vs worktree. A scratch spawn mkdir's a fresh throwaway
        // `~/.orchestra/scratch/<id>` and owns it (rm -rf on archive). A borrowed spawn runs in a
        // user-chosen dir: no worktree is cut and the allowlist gate is skipped — the OS sandbox is the
        // trust boundary (the path may even be outside any repo). A normal spawn resolves+allowlists the
        // repo and cuts the worktree. Scratch takes precedence over `cwd`/worktree.
        let realRepo: String
        let cwd: String
        let origin: CardOrigin
        if input.scratch {
            cwd = Config.scratchDir(id)
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            origin = .scratch
            realRepo = input.repo            // optional context only; never resolved/allowlisted
        } else if let borrowed = input.cwd {
            cwd = borrowed
            origin = .borrowed
            realRepo = input.repo            // optional context only; never resolved/allowlisted
        } else {
            // Security: reject a non-allowlisted repo BEFORE creating anything.
            realRepo = try resolver.resolveRepo(input.repo)
            (cwd, _) = try worktrees.ensure(repo: realRepo, branch: input.branch)
            origin = .worktree
        }
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
        // A provisional card is idle awaiting the user's first prompt, so it starts `.waiting`; a real
        // prompt means the agent is working immediately, so `.running`. The launch gets no positional
        // prompt when provisional (a whitespace-only prompt must not be submitted to the agent).
        let launchPrompt: String? = provisional ? nil : input.prompt

        let task = Task(
            id: id,
            title: title, titleProvisional: provisional, desc: "",
            repo: realRepo, branch: input.branch, cwd: cwd,
            origin: origin, access: input.access,
            agentId: adapter.id, model: model, startIn: startIn,
            column: startIn.column, order: 0, status: provisional ? .waiting : .running,
            ctxPct: 0, agentSessionId: sid, initialPrompt: input.prompt
        )
        let created = try await store.create(task)

        let ctx = AdapterContext(cwd: cwd, repo: realRepo, model: model.id, startIn: startIn,
                                 sessionId: sid, prompt: launchPrompt, name: title,
                                 hooksPath: Config.hooksPath, access: input.access,
                                 trustCwd: origin == .scratch)
        try? adapter.prepareToLaunch(ctx)
        try sessions.ensure(created, argv: adapter.start(ctx))

        emit(.taskUpserted(created))
        emitActivity(.spawned, created, source, "Spawned “\(title)”")
        return created
    }

    /// Remove orphaned scratch dirs — `~/.orchestra/scratch/<id>` subdirs with no matching non-archived
    /// `.scratch` card. Covers a scratch card that died without a clean archive (so its `rm -rf` never
    /// ran). Run once at daemon startup. Like the archive arm, this only ever deletes under the scratch
    /// root (the entries are children of `Config.scratchRoot`).
    public func sweepOrphanScratch() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Config.scratchRoot) else { return }
        let liveScratchDirs = Set(await store.all()
            .filter { $0.origin == .scratch && !$0.archived }
            .map { $0.cwd })
        for name in entries {
            let path = "\(Config.scratchRoot)/\(name)"
            if !liveScratchDirs.contains(path) { try? fm.removeItem(atPath: path) }
        }
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
        if removeWorktree {                              // gates ALL run-dir reclaim
            switch t.origin {
            case .worktree:
                // Multiple cards can intentionally share one worktree — only remove it when no other
                // non-archived .worktree card still lives there, or we'd pull the dir out from under a
                // live sibling. `cwd` == worktree root for .worktree cards.
                let siblings = await store.all().filter {
                    $0.id != id && !$0.archived && $0.origin == .worktree && $0.cwd == t.cwd
                }
                if siblings.isEmpty {
                    // Keep the branch; never silently delete a dirty tree — keep the dir if dirty.
                    do { try worktrees.remove(worktree: t.cwd, force: false) }
                    catch OrchestraError.worktreeDirty { /* keep the worktree on archive */ }
                }
            case .scratch:
                // Scratch dirs are truly ephemeral: rm -rf unconditionally (no dirty-guard; the user
                // moves out anything useful first). The destructive op is double-gated — this `.scratch`
                // arm, plus a runtime check that the path is under the scratch root. The `assert` is a
                // debug catch only; the `if` is the release-safe guard a destructive op must never skip.
                assert(t.cwd.hasPrefix(Config.scratchRoot + "/"))   // never rm -rf outside the scratch root
                if t.cwd.hasPrefix(Config.scratchRoot + "/") {
                    try? FileManager.default.removeItem(atPath: t.cwd)
                }
            case .borrowed:
                // Orchestra never deletes a borrowed dir. No-op (also none exist yet).
                break
            }
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
        let win = try sessions.newShellWindow(name, cwd: t.cwd)
        return ShellTab(window: win, label: win, pwd: t.cwd)
    }

    /// Open a shell tab in the card's worktree and launch a READ-ONLY claude in it (default mode,
    /// edit tools denied, sandbox denyWrite on the tree + its git dir, NO orchestra hooks → untracked).
    /// For "look at this worktree without touching it" without spawning a sibling card.
    public func inspect(_ id: UUID) async throws -> ShellTab {
        let t = try await require(id)
        let bin = (try? registry.get(t.agentId).bin) ?? "claude"
        // cwd == worktree root for .worktree cards (the only origin spawn produces); its last path
        // component is the worktree name used to locate the external git dir.
        let name = (t.cwd as NSString).lastPathComponent
        let settings = ReadOnlyLaunch.settingsJSON(
            cwd: t.cwd,
            gitDir: ReadOnlyLaunch.gitDir(repo: t.repo, worktreeName: name))
        let settingsPath = "\(Config.dataDir)/readonly-\(t.shortId).json"
        try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        let session = sessions.sessionName(t.id)
        if try !sessions.isAlive(session) { _ = try sessions.ensure(t, argv: ["/bin/sh"]) }
        let win = try sessions.newShellWindow(session, cwd: t.cwd)
        let argv = ReadOnlyLaunch.argv(binary: bin, settingsPath: settingsPath)
        // Shell-quote each arg (single-quote, escaping embedded quotes) so the joined command is a
        // literal argv; sendKeys sends the line + Enter itself.
        let cmd = argv.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        try sessions.sendKeys(session, text: cmd, window: win)
        return ShellTab(window: win, label: win, pwd: t.cwd)
    }

    public func closeShell(_ id: UUID, window: String) async throws {
        let t = try await require(id)
        try sessions.closeShellWindow(sessions.sessionName(t.id), window: window)
    }

    public func exec(_ id: UUID, _ cmd: String, timeout: Duration? = nil) async throws -> ExecResult {
        let t = try await require(id)
        // Only worktree cards are gated by the repo allowlist; borrowed/scratch cwds are trusted via
        // the OS sandbox (the path may live outside any allowlisted repo).
        if t.origin == .worktree { try resolver.assertAllowed(t.cwd) }
        let r = try Proc.run(["sh", "-c", cmd], cwd: t.cwd, timeout: timeout ?? .seconds(120))
        let cap = 256 * 1024
        return ExecResult(stdout: String(r.stdout.prefix(cap)), stderr: String(r.stderr.prefix(cap)), exitCode: r.exitCode)
    }

    public func sessions(_ id: UUID) async throws -> CardSessions {
        let t = try await require(id)
        let adapter = try registry.get(t.agentId)
        let name = sessions.sessionName(id)
        let targets = (try? sessions.windows(name)) ?? []
        let running = !targets.isEmpty
        let ctx = AdapterContext(cwd: t.cwd, model: t.model.id, sessionId: t.agentSessionId,
                                 name: t.title, hooksPath: Config.hooksPath)
        let info = adapter.sessionInfo(ctx, current: t.agentSessionId, prior: t.priorSessionIds)
            ?? AgentSessionInfo(agentId: t.agentId, sessionId: t.agentSessionId, transcriptPath: nil,
                                priorSessionIds: t.priorSessionIds, priorTranscripts: [], resumeCmd: nil)
        return CardSessions(ref: t.ref(), id: t.id, worktree: t.cwd, tmuxSocket: Config.tmuxSocket,
                            session: name, running: running, targets: targets, agent: info)
    }

    public func openInZed(_ id: UUID) async throws {
        let t = try await require(id)
        try launcher.openInZed(t.cwd)
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
