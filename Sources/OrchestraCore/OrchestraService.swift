import Foundation

/// The core coordinator. Every mutation funnels through here; it emits `Event`s that the
/// `ControlServer` fans out to subscribed clients. Holds the single source of coordination; ground
/// truth is federated (tasks.json + tmux liveness + git).
public actor OrchestraService {
    public private(set) var config: Config
    let store: TaskStore
    let trust: TrustLedger
    let registry: AgentRegistry
    /// Absolute path of the `orchestra` binary the agents' hooks call. Injected once (defaulted to the
    /// daemon's sibling binary) and threaded into every launch `AdapterContext`.
    let orchestraBin: String
    var worktrees: any WorktreeManaging
    var sessions: any SessionManaging
    let launcher: Launcher
    var resolver: PathResolver
    /// Per-adapter subscription rate state for the authMode soft-warn (E2 / q4 — advisory only, no cap).
    let authRate = AuthRateMonitor()
    /// Daemon-side rollout TRANSPORT for `fileTail` agents (Codex). Tracks a per-card byte offset; the
    /// poll loop hands its lines to `adapter.parse`. Claude (`hooksPush`) never touches it.
    let tailer = RolloutTailer()
    /// Durable per-card message inbox (F3). Sibling to `store`; `send` enqueues, the Stop hook drains.
    let inbox: Inbox
    /// The human-grant resolver (T2). Consulted by `grantTrust`; the production `SurfaceGrantResolver`
    /// only approves interactive surfaces and denies agent/daemon (autonomy-exemption + no self-grant).
    let grantResolver: any TrustGrantResolver
    /// Conclusion-watch for the reactive fan-out (F2). A subscriber to this service's terminal
    /// transitions — the service is the single authority (see `concludeCard` in `+Wake`).
    let mergeWatch = MergeWatch()
    /// Durable inbox routing for the fan-out: watcher card → the children it is watching. A child's
    /// conclusion enqueues into every watching parent's inbox (F3 coalesce) + wakes it (F2).
    var watchRegistry: [UUID: Set<UUID>] = [:]
    /// Consecutive auto-injects per card since the last genuine user prompt — the F3 loop guard.
    /// `stop_hook_active` is informational on both agents, so Orchestra enforces the cap itself.
    var injectCounts: [UUID: Int] = [:]
    /// Break a runaway Stop→inject→Stop loop after this many consecutive auto-injects (reset by a real prompt).
    public let maxConsecutiveInjects = 25

    // Event fan-out.
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    // Per-card monotonic seq guard for snapshot reports.
    var lastSeqStore: [UUID: UInt64] = [:]
    // Pending resume confirmations (resolved by the SessionStart(resume) callback or a timeout).
    var resumeWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Cards currently being revived/restarted — guarded against the liveness reconcile.
    var recovering: Set<UUID> = []
    // Per-card coalescing debounce for the diffstat recompute (code-review-on-board). A one-shot per
    // activity burst off the normalized `report()` funnel — NOT a periodic poll.
    var diffStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]

    public init(config: Config,
                store: TaskStore? = nil,
                registry: AgentRegistry = AgentRegistry(),
                worktrees: (any WorktreeManaging)? = nil,
                sessions: (any SessionManaging)? = nil,
                launcher: Launcher? = nil,
                resolver: PathResolver? = nil,
                trust: TrustLedger? = nil,
                inbox: Inbox? = nil,
                grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                orchestraBin: String = siblingBinary("orchestra")) {
        self.config = config
        self.orchestraBin = orchestraBin
        let r = resolver ?? PathResolver(config: config)
        self.resolver = r
        self.store = store ?? TaskStore()
        self.trust = trust ?? TrustLedger()
        self.inbox = inbox ?? Inbox()
        self.grantResolver = grantResolver
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
            // External-intake guard: a scratch dir Orchestra made empty auto-trusts, but if foreign
            // code has since landed in it (a repo cloned in → a `.git`), it is no longer Orchestra's
            // empty dir — demote to BORROWED semantics (re-enter the grant path) rather than auto-
            // trusting someone else's code.
            if Self.scratchHasForeignCode(cwd) {
                return await trust.isTrusted(cwd) ? .trusted : .needsGrant
            }
            _ = try? await trust.record(cwd, grantedBy: .orchestra)
            return .trusted
        case .worktree:
            if let repo { _ = try? await trust.record(repo, grantedBy: .repoRegistration) }
            return .trusted
        case .borrowed:
            return await trust.isTrusted(cwd) ? .trusted : .needsGrant
        }
    }

    /// A scratch dir that contains a `.git` holds a cloned/foreign repo — treat it as borrowed.
    static func scratchHasForeignCode(_ cwd: String) -> Bool {
        FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git"))
    }

    /// The `trust` Command's service method (T2). Records a HUMAN grant for `path` into the ledger —
    /// but only after the resolver (standing in for a human at a surface) approves. The agent may only
    /// trigger this; a human answers. Fail-closed: a `.denied` outcome records nothing and throws.
    @discardableResult
    public func grantTrust(_ path: String, source: ActivitySource) async throws -> TrustGrantResult {
        let canon = PathResolver.canonical(path)
        if await trust.isTrusted(canon) {
            return TrustGrantResult(path: canon, granted: true, alreadyTrusted: true)
        }
        let outcome = await grantResolver.requestGrant(
            path: canon, reason: "grant agents write access to \(canon)", source: source)
        guard outcome == .approved else {
            throw OrchestraError.trustDenied(
                "no human approved trust for \(canon) (agents cannot self-grant)")
        }
        _ = try await trust.record(canon, grantedBy: .human)
        emitActivity(.warning, nil, source, "Trusted \(canon) (human grant)")
        return TrustGrantResult(path: canon, granted: true, alreadyTrusted: false)
    }

    /// Pure trust query for a prospective borrowed cwd (the SpawnSheet's trust indicator). Unlike
    /// `resolveTrust`, this NEVER records — it only reads the ledger. The grant surface is T2.
    public func isPathTrusted(_ path: String) async -> Bool {
        await trust.isTrusted(path)
    }

    // MARK: - telemetry (fileTail transport)

    /// One tick of the daemon-side rollout tail. For every live `fileTail` card (Codex), read the lines
    /// appended to its rollout file since last tick and merge each through the adapter's own `parse`
    /// (agent-dependent, D3) via `report` (seq-gated). Push agents (Claude `hooksPush`) are skipped —
    /// their telemetry arrives out-of-band via the `_report` endpoint, so this stays Claude-inert.
    /// Driven by the daemon's 2s poll loop, alongside `reconcileLiveness`.
    public func pollTelemetry() async {
        let tasks = await store.all()
        for t in tasks where !t.archived && t.status != .dead {
            guard let adapter = try? registry.get(t.agentId),
                  adapter.capabilities.telemetry == .fileTail else { continue }
            // Resolve the rollout path from the adapter (uses the tracked id, else discovers the newest).
            let ctx = AdapterContext(cwd: t.cwd, model: t.model.id, sessionId: t.agentSessionId,
                                     name: t.title, access: t.access)
            guard let path = adapter.sessionInfo(ctx, current: t.agentSessionId,
                                                 prior: t.priorSessionIds)?.transcriptPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            for line in await tailer.newLines(cardId: t.id, path: path) {
                if let patch = adapter.parse(.fileTail(line: line)) {
                    try? await report(t.id, patch)
                }
            }
        }
    }

    // MARK: - spawn

    public func spawn(_ input: SpawnInput, source: ActivitySource = .daemon) async throws -> Task {
        // Route to the adapter: an explicit `agentId` wins; else the adapter that owns the chosen model
        // (the app's flat picker sends only a model id — this is what makes Codex startable from a
        // model-only selection); else the configured default.
        let resolvedAgentId = input.agentId
            ?? input.model.flatMap { registry.adapter(forModel: $0)?.id }
            ?? config.defaultAgentId
        let adapter = try registry.get(resolvedAgentId)
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
        // Session identity is capability-gated, not inferred from a nil return: a `.seeded` agent
        // (Claude) gets its id minted pre-launch; a `.discovered` agent is left nil and reads its id
        // back from its own output post-launch (design §5, D5).
        let sid: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     sid = adapter.newSessionId()
        case .discovered: sid = nil
        }
        // Resolve the chosen launch id (explicit / config default / adapter's first) to a full model.
        let modelId = input.model ?? config.defaultModel ?? adapter.models().first?.id ?? ""
        let model = adapter.model(for: modelId)
        let startIn = input.startIn ?? .plan
        // Fork / fan-out: an authored seed (parent slice / handoff context) is delivered to a FRESH card
        // by folding it AHEAD of the prompt into the single launch positional (Claude/Codex take one
        // positional). Bounded like the F3 drain so a huge slice can't blow the argv. (F1's `ctx.seed`
        // is the resume-only carrier; a fresh start delivers the seed as the initial prompt.)
        let seedText = input.seed?.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded: String? = {
            let s = (seedText?.isEmpty == false) ? seedText : nil
            let p = promptText.isEmpty ? nil : input.prompt
            switch (s, p) {
            case let (s?, p?): return String((s + "\n\n" + p).prefix(StopDrain.maxPayloadChars))
            case let (s?, nil): return String(s.prefix(StopDrain.maxPayloadChars))
            case let (nil, p?): return p
            case (nil, nil):    return nil
            }
        }()
        // No prompt AND no seed → the card is named off the first prompt the user types (titleProvisional),
        // showing the branch as a placeholder until then. A prompt or seed seeds the title immediately.
        let provisional = folded == nil
        let title = provisional ? (input.branch.isEmpty ? "New agent" : input.branch)
                                 : titleSeed(from: folded ?? input.prompt)
        // A provisional card is idle awaiting the user's first prompt, so it starts `.waiting`; a real
        // prompt/seed means the agent is working immediately, so `.running`. The launch gets no positional
        // when provisional (a whitespace-only prompt must not be submitted to the agent).
        let launchPrompt: String? = folded

        let task = Task(
            id: id,
            title: title, titleProvisional: provisional, desc: "",
            repo: realRepo, branch: input.branch, cwd: cwd,
            origin: origin, access: input.access,
            agentId: adapter.id, model: model, startIn: startIn,
            column: startIn.column, order: 0, status: provisional ? .waiting : .running,
            ctxPct: 0, agentSessionId: sid, initialPrompt: folded ?? input.prompt
        )
        let created = try await store.create(task)

        let trustDecision = await resolveTrust(origin: origin, cwd: cwd, repo: realRepo)
        // Column/mode/self-id orientation is delivered at SessionStart by each agent's hook (Claude's
        // `_report --event session`, Codex's `_report --event orient`) as `additionalContext`, so it is
        // NOT folded into the launch positional — the hook covers both a launched-with-prompt card and an
        // idle provisional one, without submitting an unsolicited turn. See [[SessionBrief]] / [[CodexHooks]].
        let ctx = AdapterContext(cwd: cwd, repo: realRepo, model: model.id, startIn: startIn,
                                 sessionId: sid, prompt: launchPrompt, name: title,
                                 orchestraBin: orchestraBin, access: input.access,
                                 trustCwd: trustDecision == .trusted)
        try? adapter.prepareToLaunch(ctx)
        try sessions.ensure(created, argv: adapter.start(ctx), env: adapter.env)

        emit(.taskUpserted(created))
        emitActivity(.spawned, created, source, "Spawned “\(title)”")

        // T2: an untrusted cwd (needsGrant) spawns sandboxed (trustCwd=false above) but tells the
        // human how to grant it. Autonomy-exempt: this never blocks the spawn — the card just runs
        // read-only-ish until a human runs `orchestra trust`.
        if trustDecision == .needsGrant {
            emitActivity(.warning, created, source,
                "“\(title)” runs untrusted (sandboxed) in \(cwd). To grant write trust, run "
                + "`orchestra trust \(cwd)` in a terminal, or keep it read-only.")
        }

        // authMode soft-warn (E2 / q4 — advisory only, NEVER caps). Count active subscription-auth cards
        // for this adapter (the just-created card is already in the store) and warn past the threshold.
        let active = await store.all().filter { !$0.archived && $0.status != .dead }
        if let warn = authRate.warning(for: adapter.id, active: active, registry: registry) {
            emitActivity(.warning, created, source, warn.message)
        }
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

    /// Enqueue a message to the card's durable inbox (F3), then `wake` the card (F2) so an *idle* agent
    /// drains it now instead of waiting for its next unprompted turn. Content is delivered by the inbox
    /// (Stop-hook drain / resume seed) — `wake` only starts a turn, and is idempotent/non-intrusive: it
    /// no-ops on a card that already has a turn coming (running, mid-relaunch, or blocked on a background
    /// `orchestra wait`). See `wake` for the per-transport delivery (Codex nudge / Claude resume-seed).
    public func send(_ id: UUID, _ message: String) async throws {
        let t = try await require(id)
        try await inbox.enqueue(t.id, message)
        await wake(t.id)
    }

    /// Inbox editor (UI + MCP): list a card's pending messages. Non-destructive.
    public func inboxPeek(_ id: UUID) async throws -> [InboxMessage] {
        let t = try await require(id)
        return await inbox.peek(t.id)
    }

    /// Inbox editor: remove one queued message by its id.
    public func inboxRemove(_ id: UUID, messageId: UUID) async throws {
        _ = try await require(id)
        try await inbox.remove(messageId)
    }

    /// Inbox editor: edit the text of one queued message.
    public func inboxUpdate(_ id: UUID, messageId: UUID, text: String) async throws {
        _ = try await require(id)
        try await inbox.update(messageId, text: text)
    }

    /// Inbox editor: reorder a card's queued messages (ids = full new order).
    public func inboxReorder(_ id: UUID, orderedIds: [UUID]) async throws {
        let t = try await require(id)
        try await inbox.reorder(t.id, orderedIds: orderedIds)
    }

    // MARK: - inbox / F3 (Stop-drain)

    /// Drain the card's inbox into the payload the Stop hook injects (`decision:block` + `reason`), applying
    /// the consecutive-inject loop guard. Returns `nil` when there is nothing to inject OR the guard tripped
    /// (in which case pending messages are left durable for the next genuine turn / wake). Does not require a
    /// task in the store — it is pure inbox + counter, safe to call from the transport.
    public func drainForStop(_ cardId: UUID) async -> String? {
        let pending = await inbox.peek(cardId)
        if pending.isEmpty { injectCounts[cardId] = 0; return nil }   // natural end → reset
        let count = injectCounts[cardId] ?? 0
        if count >= maxConsecutiveInjects { return nil }              // loop guard tripped; keep counter high
        let drained = (try? await inbox.drain(cardId)) ?? []
        injectCounts[cardId] = count + 1
        return StopDrain.compose(drained)
    }

    /// Reset a card's consecutive-inject guard — called on a genuine user prompt (UserPromptSubmit).
    func resetInjectCount(_ cardId: UUID) { injectCounts[cardId] = 0 }

    // MARK: - SessionStart orientation

    /// The agent-agnostic SessionStart orientation for a card — which column it's in, whether it's
    /// read-only, and its own id — so an agent knows where it was opened and starts on that footing
    /// without being told (the open-time counterpart to `drainForStop`). Read **live** so a reopened or
    /// dragged card reflects its CURRENT lane, not the launch-time `startIn`. `nil` if the card is gone.
    public func sessionBrief(_ cardId: UUID) async -> String? {
        guard let task = await store.get(cardId) else { return nil }
        return SessionBrief.sentence(column: task.column, access: task.access, shortId: task.shortId)
    }

    /// The core-owned hook-channel dispatch — the single place both directions of the hook channel meet,
    /// and it is ADAPTER-FREE (dispatch keys on `HookEvent`, never on agent identity). The `_report` edge
    /// has already converted the raw payload into a typed event: it applies any telemetry `report` to the
    /// store (send direction) and composes the existing `sessionBrief`/`drainForStop` content into a
    /// neutral `HookResponse` (receive direction) for the adapter to encode. `nil` on unknown ref or when
    /// there is nothing to send back.
    public func handleHook(_ ref: String, event: HookEvent,
                           report: StatusReport?, source: SessionSource?) async -> HookResponse? {
        guard let task = try? await resolveRef(ref) else { return nil }
        if let report { try? await self.report(task.id, report) }
        switch event {
        case .sessionStart where source != .compact:
            // Skip re-orienting on a mid-turn compact (the agent already has its bearings).
            return await sessionBrief(task.id).map { HookResponse(additionalContext: $0) }
        case .stop:
            return await drainForStop(task.id).map { HookResponse(continuation: $0) }
        default:
            return nil
        }
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
        await concludeCard(id, .done)   // moving to Done is a settled conclusion (F2 / merge-watch)
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
                                 name: t.title, orchestraBin: orchestraBin)
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

    /// The selectable models. With `agentId`, just that adapter's catalog. Without, the UNION across
    /// every enabled adapter — so the app's flat "Model" picker lists Claude + Codex together — with the
    /// DEFAULT agent's models first (the picker's first entry stays a default-agent model).
    public func models(agentId: String? = nil) -> [AgentModel] {
        if let agentId { return (try? registry.get(agentId).models()) ?? [] }
        return orderedAdapters().flatMap { $0.models() }
    }

    /// The selectable AGENTS (adapter id/name/icon + each one's model catalog) for the Spawn sheet's
    /// agent picker, DEFAULT agent first. The union `models()` above stays for the flat/default-model
    /// surfaces (e.g. Settings); this is the per-agent grouping.
    public func agents() -> [AgentInfo] {
        orderedAdapters().map { AgentInfo(id: $0.id, name: $0.name, icon: $0.icon, models: $0.models()) }
    }

    /// Enabled adapters with the configured default agent first (shared ordering for `models()`/`agents()`).
    private func orderedAdapters() -> [any Adapter] {
        let adapters = registry.list()
        return adapters.filter { $0.id == config.defaultAgentId }
             + adapters.filter { $0.id != config.defaultAgentId }
    }

    /// Emit a generic `.command` activity for a public verb arriving over CLI/MCP that doesn't already
    /// emit its own semantic activity (list/status/send/shell/exec/sessions).
    public func logCommand(_ verb: String, ref task: Task?, source: ActivitySource) {
        emitActivity(.command, task, source, "\(verb)\(task.map { " \($0.shortId)" } ?? "")")
    }
}
