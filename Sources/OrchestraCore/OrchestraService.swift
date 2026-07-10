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
    var worktrees: WorktreeRegistry
    var sessions: any SessionManaging
    let launcher: Launcher
    var resolver: PathResolver
    /// Code-review diff/stat renderer (code-review-on-board). Defaults to the real `git`-backed
    /// provider; a test injects a blocking stub (`_setDiffProviderForTest`) to prove `diffText`/
    /// `recomputeDiffStat` run their git work off-actor (PR5 actor-hygiene, Task 5.1.2).
    var diffProvider: any DiffProvider = GitDiffProvider()
    /// Per-repo `git remote` memo (PR5 actor-hygiene, Task 5.1.4) — keyed by `.git/config` mtime, so
    /// `nonisolated` git-probe code (`gitRemotes`) can call it off-actor without an actor-state read.
    let gitRemotesCache = GitRemotesCache()
    /// Test-only probe for `computeTreeStat` (PR5 actor-hygiene, Task 5.1.4): read ON-ACTOR by
    /// `recomputeTreeStat` and passed as a call-scoped argument into the `nonisolated computeTreeStat` —
    /// never itself read from inside the offActor hop. `nil` in production.
    let treeProbeHolder = TreeProbeHolder()
    /// Per-adapter subscription rate state for the authMode soft-warn (E2 / q4 — advisory only, no cap).
    let authRate = AuthRateMonitor()
    /// Daemon-side rollout TRANSPORT for `fileTail` agents (Codex). Tracks a per-card byte offset; the
    /// poll loop hands its lines to `adapter.parse`. Claude (`hooksPush`) never touches it.
    let tailer = RolloutTailer()
    /// Durable per-card message inbox (F3). Sibling to `store`; `send` enqueues, the Stop hook drains.
    let inbox: Inbox
    /// Registered APNs device tokens (N1). The daemon's `PushNotifier` reads this to deliver attention
    /// pushes; the phone populates it over the `registerDevice` RPC.
    let devices: DeviceTokenStore
    /// The human-grant resolver (T2). Consulted by `grantTrust`; the production `SurfaceGrantResolver`
    /// only approves interactive surfaces and denies agent/daemon (autonomy-exemption + no self-grant).
    let grantResolver: any TrustGrantResolver
    /// Conclusion-watch for the reactive fan-out (F2). A subscriber to this service's terminal
    /// transitions — the service is the single authority (see `concludeCard` in `+Wake`).
    let mergeWatch = MergeWatch()
    /// Branch-tree lineage store (git-config parent links). The single writer; `Task.parentBranch`
    /// is a cache derived from it at spawn / set-parent.
    let lineage = BranchLineage()
    /// The isolated remote-parent tier (BT6): hardened `fetch`/`lsRemoteTip` for remote bases + watch.
    let remoteParents = RemoteParents()
    /// Per-card remote watch loops, cancellation-keyed (the `diffStatDebounce` state pattern). A watched
    /// remote-parent card polls its PR/branch tip and runs the merge-detection ladder.
    var remoteWatch: [UUID: _Concurrency.Task<Void, Never>] = [:]
    /// Per-card watch generation — bumped on every start/stop so a cancelled loop's terminal cleanup can't
    /// null out a newer loop installed by a restart (see `startRemoteWatch`).
    var remoteWatchGen: [UUID: Int] = [:]
    /// Injectable poll cadence — short values in tests avoid real 60s/300s sleeps. (active, idle).
    var remoteWatchIntervals: (active: Duration, idle: Duration) = (.seconds(60), .seconds(300))
    /// The `gh` boundary (FakeGh in tests). Default: the real capability-probing client.
    var gh: any GhClient = GhProbe()
    /// S3-1: per-card once-latch for the persistent remote-parent warnings (gone / PR-closed-unmerged),
    /// so a condition that is true every idle tick surfaces ONCE, not every 5 minutes. Cleared when the
    /// tip moves (condition may have changed) or the card is re-parented / leaves the remote tier.
    var remoteWarnLatch: Set<UUID> = []
    /// O2: per-child re-nudge loops for a pending `merge-request` (keyed on the child card). Re-asks the
    /// parent card on a timer until the child leaves the `mergeRequested` state.
    var mergeRequestNudge: [UUID: _Concurrency.Task<Void, Never>] = [:]
    /// Injectable re-nudge cadence — short in tests to avoid a real 5-min sleep.
    var mergeRequestNudgeInterval: Duration = .seconds(300)
    /// Durable inbox routing for the fan-out: watcher card → the children it is watching. A child's
    /// conclusion enqueues into every watching parent's inbox (F3 coalesce) + wakes it (F2). Write-through
    /// mirror of `watchStore` — EVERY mutation persists (via `registerWatch`/`unregisterWatch`) so a
    /// watcher survives a daemon restart (carry #4).
    var watchRegistry: [UUID: Set<UUID>] = [:]
    /// Lazy-load latch for `watchRegistry` (mirrors `WorktreeRegistry.borrowsLoaded`). The server accepts
    /// RPCs before boot's `reloadWatchRegistry` runs, so the FIRST access — a boot-window `registerWatch`/
    /// `unregisterWatch`/`concludeCard` or the reload itself — loads-then-unions rather than clobbering the
    /// on-disk map with an empty in-memory one.
    var watchRegistryLoaded = false
    /// Set when the load found a present-but-torn file (mirrors `borrowsLoadFailed`): the in-memory map is
    /// kept as-is and mutations REFUSE to `watchStore.save` so a partial in-memory map never overwrites the
    /// torn (but possibly recoverable) file. Fail-safe: never persist over an ambiguous registry.
    var watchRegistryLoadFailed = false
    /// Durable backing for `watchRegistry`. Reloaded at boot (`reloadWatchRegistry`), written through on
    /// every mutation. Injected in tests so each temp dir gets its own file.
    let watchStore: WatchRegistryStore
    /// Watchers with a live CLI `orchestra wait` process. A native-reinvoke card only defers wake to
    /// wait-exit when this is present; MCP/tool watches register interest without a CLI process.
    var activeWaitProcesses: [UUID: Int] = [:]
    /// Consecutive auto-injects per card since the last genuine user prompt — the F3 loop guard.
    /// `stop_hook_active` is informational on both agents, so Orchestra enforces the cap itself.
    var injectCounts: [UUID: Int] = [:]
    /// Break a runaway Stop→inject→Stop loop after this many consecutive auto-injects (reset by a real prompt).
    public let maxConsecutiveInjects = 25

    // Event fan-out.
    private var subscribers: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    /// Mirror of the last board rev an event carried; stamped onto ephemeral events (which never bump
    /// rev, so the last task-state rev is the current board rev). Seeded in `init` via
    /// `store.peekPersistedRev()` (before the control server can accept any RPC), and refreshed by
    /// every `emit(_:rev:)` thereafter.
    private var lastRev: Int = 0
    /// A card's tmux session state as of the reconciler's last off-actor `windows()` probe (PR5 actor-
    /// hygiene, Task 5.2). `observedAt` lets `boardSnapshot` tell a fresh capture from one taken before the
    /// card's CURRENT session (`phaseChangedAt`) — a stale entry (or a miss) falls back to a live shell.
    struct ObservedSession: Sendable, Equatable {
        let targets: [TmuxTarget]
        let running: Bool
        let observedAt: Date
    }
    /// Reconcile-tick-maintained cache of each non-archived card's session state, keyed by card id.
    /// Populated every tick (`reconcile()`), evicted on teardown and on any user-driven shell op
    /// (`openShell`/`closeShell`/`inspect`) so a stale entry never masks a real change.
    var observedSessions: [UUID: ObservedSession] = [:]
    // Ephemeral, daemon-authoritative agent-terminal ownership (UI coordination — never persisted).
    var terminalOwnership = TerminalOwnershipStore()
    // Last owner event BROADCAST per card, compared owner-visible-fields-only so a 10s heartbeat that
    // changed nothing but `updatedAt` doesn't re-emit and re-render the whole board hierarchy (#4).
    private var lastEmittedOwnerSig: [UUID: OwnerEmitSig] = [:]
    // Per-card monotonic seq guard for snapshot reports.
    var lastSeqStore: [UUID: UInt64] = [:]
    // Pending inline-readiness waiters (resolved by the readiness signal — SessionStart(resume) for a
    // `.sessionStartHook` agent — or a timeout). Keyed by card id but TOKEN-tagged: two overlapping
    // relaunches for the same id must never silently clobber (and thus LEAK) the earlier continuation —
    // the displaced waiter is resolved `.superseded`, and a stale timeout is ignored unless its token
    // still owns the slot. See `awaitReadiness`/`resolveReadiness`.
    var readinessWaiters: [UUID: (token: UInt64, cont: CheckedContinuation<ReadinessOutcome, Never>)] = [:]
    // Monotonic tag minted per awaitReadiness so a timeout only fires for the waiter it was scheduled for.
    var readinessTokenSeq: UInt64 = 0
    // A readiness signal can arrive BEFORE `awaitReadiness` registers its waiter, because a relaunch's
    // off-actor session bring-up frees this reentrant actor to service `report()` mid-revival. We remember
    // such early confirmations here so the waiter consumes them instead of losing the wakeup and timing
    // out. Cleared at the start of each relaunch attempt so a late callback from a prior, already-failed
    // attempt can't spuriously confirm a future one.
    var pendingReadiness: Set<UUID> = []
    // Universal N=3 readiness fallback (2.6). Per-card count of consecutive liveness ticks a being-born
    // card (`.launching`/`.relaunching`) has had a LIVE session AND a still-pending inline readiness waiter.
    // At `launchReadyTickThreshold` we `resolveReadiness` the waiter — a safety net WITHIN the grace window
    // for a lost/absent readiness signal (Codex `codex resume` writes no rollout; a missed SessionStart
    // hook; any `.relaunchLiveness`-shaped agent). `N × 2s(pollInterval) < grace`, so it fires before the
    // await's timeout would fail the verb. Reset when the card leaves the being-born phase.
    var launchReadyTicks: [UUID: Int] = [:]
    let launchReadyTickThreshold = 3
    // Narrow atomic-claim set (replaces the deleted `recovering` set's role (b)): a wake/idle-resume
    // inserts the card SYNCHRONOUSLY (before any `await`) so a concurrent wake sees the claim and defers,
    // avoiding a double-resume race on an idle card. Role (a) — the stale-SessionEnd grace window — is now
    // covered by session epochs (2.4), so this is NOT read by the liveness reconcile (which uses phase
    // rules). Cleared when the resume settles. See `wake`/`resumeSeedWake`/`clearRelaunchClaimed`.
    var relaunchClaimed: Set<UUID> = []
    // Per-card coalescing debounce for the diffstat recompute (code-review-on-board). A one-shot per
    // activity burst off the normalized `report()` funnel — NOT a periodic poll.
    var diffStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]
    // Per-card coalescing debounce for the TreeStat recompute (branch-tree, BT4). Twin of
    // `diffStatDebounce` — a one-shot per activity burst off the `report()` funnel, not a poll.
    var treeStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]
    // Per-parent coalescing debounce for the child fan-out (branch-tree, BT4). Keeps the `git config
    // --get-regexp` child lookup OFF the hot report path — one lookup per activity burst, not per report.
    var childFanoutDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]

    // MARK: - Stage-4 reconciler driving discipline (PR4b Task 2)
    /// Cards with a phase-step currently dispatched off-actor. At most ONE step in flight per card — set
    /// SYNCHRONOUSLY before dispatching, cleared in the step's completion — so a slow step is never
    /// double-driven by the next tick, by a concurrent verb, or by boot revival.
    var inFlightSteps: Set<UUID> = []
    /// Per-card capped-exponential backoff for a FAILING step: `count` bumps on each throw (reset on
    /// success), `nextEligible` gates the next retry so a persistently-failing stepper never hot-loops.
    var stepAttempts: [UUID: (count: Int, nextEligible: Date)] = [:]
    /// Test seam: pin the step-backoff delay to a fixed value (seconds), overriding the capped-exponential
    /// schedule. The backoff test uses a large value so its "immediate re-ticks stay inside the window"
    /// assertion is load-proof — the real 2s first delay can be outlasted by a heavily-parallel test run.
    var stepBackoffOverrideSeconds: Double? = nil
    /// The reconciler's `Phase.Kind → PhaseStepper` dispatch table. Defaults to the real four; a test may
    /// override an entry (e.g. a throwing stepper for the backoff test) via `setStepper`.
    var steppers: [Phase.Kind: any PhaseStepper] = PhaseSteppers.byKind
    /// Poll cadence the reconciler assumes (main.swift's loop). Also the unit the N=3 launch-readiness
    /// fallback's `threshold × interval < sessionLaunchTimeout` inequality is stated in.
    public nonisolated let reconcilePollInterval: TimeInterval = 2

    public init(config: Config,
                store: TaskStore? = nil,
                registry: AgentRegistry = AgentRegistry(),
                worktrees: WorktreeRegistry? = nil,
                sessions: (any SessionManaging)? = nil,
                launcher: Launcher? = nil,
                resolver: PathResolver? = nil,
                trust: TrustLedger? = nil,
                inbox: Inbox? = nil,
                devices: DeviceTokenStore? = nil,
                grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                watchStore: WatchRegistryStore = WatchRegistryStore(),
                orchestraBin: String = siblingBinary("orchestra")) {
        self.config = config
        self.orchestraBin = orchestraBin
        self.watchStore = watchStore
        let r = resolver ?? PathResolver(config: config)
        self.resolver = r
        self.store = store ?? TaskStore()
        self.trust = trust ?? TrustLedger()
        self.inbox = inbox ?? Inbox()
        self.devices = devices ?? DeviceTokenStore()
        self.grantResolver = grantResolver
        self.registry = registry
        self.worktrees = worktrees ?? WorktreeRegistry(config: config, resolver: r)
        self.sessions = sessions ?? SessionManager()
        self.launcher = launcher ?? Launcher(resolver: r)
        // Seed the lastRev mirror synchronously (nonisolated peek — no await), BEFORE server.start()
        // can accept any RPC or PushNotifier.run() can subscribe, so an early ephemeral emit (e.g. a
        // borrow/trust/set-parent RPC racing daemon boot ahead of `recoverSessions`) never stamps a
        // stale rev 0 on a persisted board. Every subsequent `emit(_:rev:)` refreshes it.
        self.lastRev = self.store.peekPersistedRev()
    }

    // MARK: - Subscriptions / events

    public func subscribe() -> AsyncStream<EventEnvelope> {
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

    /// SYNCHRONOUS: `rev` is passed in explicitly (from the mutation return, or `lastRev` for
    /// ephemerals) — there is no `await` between a mutation and its emit, so actor reentrancy cannot
    /// skew which rev an event carries (see the rev-binding design decision).
    func emit(_ event: Event, rev: Int) {
        lastRev = rev
        let envelope = EventEnvelope(rev: rev, event: event)
        for cont in subscribers.values { cont.yield(envelope) }
    }

    /// Ephemeral: stamps the current board rev via the `lastRev` mirror (ephemeral events never bump
    /// the store's rev, so the last task-state rev IS the current board rev).
    func emitActivity(_ kind: ActivityKind, _ task: Task?, _ source: ActivitySource, _ text: String) {
        let item = ActivityItem(taskId: task?.id, ref: task?.ref(), source: source, kind: kind, text: text)
        emit(.activity(item), rev: lastRev)
    }

    // MARK: - test-support (rev)

    #if DEBUG
    func storeCurrentRevForTest() async -> Int { await store.currentRev }
    func emitActivityForTest() { emitActivity(.command, nil, .daemon, "test") }
    func _setDiffProviderForTest(_ provider: any DiffProvider) { diffProvider = provider }
    func _setTreeProbeForTest(_ probe: (@Sendable () -> Void)?) { treeProbeHolder.set(probe) }
    #endif

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
        for t in tasks where !t.archived && t.phase.kind != .dead {
            guard let adapter = try? registry.get(t.agentId),
                  adapter.capabilities.telemetry == .fileTail else { continue }
            // Resolve the rollout path from the adapter (uses the tracked id, else DISCOVERS it). The
            // discovery is time-scoped ONLY while the card is being born (`.launching`/`.relaunching`): a
            // not-yet-bound launch must adopt only its OWN fresh rollout (mtime > `phaseChangedAt`), never a
            // live sibling's actively-written rollout in the same cwd nor its own stale pre-reboot one. Once
            // the card is live and stably tailing, discovery is unrestricted (newest cwd match) — the risky
            // moment is the launch bind, not steady state.
            let beingBorn = t.phase.kind == .launching || t.phase.kind == .relaunching
            let ctx = AdapterContext(cwd: t.cwd, model: t.model.id, sessionId: t.agentSessionId,
                                     name: t.title, access: t.access,
                                     since: beingBorn ? t.phaseChangedAt : nil)
            let a = adapter
            let sessionId = t.agentSessionId
            let priorSessionIds = t.priorSessionIds
            let resolved: (path: String, exists: Bool)? = try? await offActor {
                guard let info = a.sessionInfo(ctx, current: sessionId, prior: priorSessionIds),
                      let p = info.transcriptPath else { return nil }
                return (p, FileManager.default.fileExists(atPath: p))
            }
            guard let resolved, resolved.exists else { continue }
            for line in await tailer.newLines(cardId: t.id, path: resolved.path) {
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
        var spawnBaseCarrier: String? = nil   // normalized base carried to the reconciler's MaterializeStepper
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
            // Security: reject a non-allowlisted repo BEFORE creating anything (synchronous fail-fast).
            realRepo = try resolver.resolveRepo(input.repo)
            // S2-6: co-located `.worktree` cards sharing one branch/worktree are still permitted (the
            // cwd-keyed archive refcount + worktreeSiblings badge depend on it; full 1:1 enforcement is
            // the separate worktree-coupling design). But every derived parent-card lookup must be
            // DETERMINISTIC (oldest live card wins — see `derivedCard`), not an arbitrary sibling. Warn on
            // multiplicity so the operator sees the ambiguity they just created.
            if let existing = await store.all().first(where: {
                !$0.archived && $0.origin == .worktree && $0.repo == realRepo && $0.branch == input.branch
            }) {
                emitActivity(.warning, existing, source,
                    "spawning a second live card onto branch \(input.branch) (already owned by "
                    + "\(existing.shortId)) — derived parent lookups use the oldest card")
            }
            // S2-3(i): normalize + VALIDATE a user-supplied base SYNCHRONOUSLY (must-fail-fast — the security
            // gate stays before anything is created). Strip a `refs/heads/` prefix; reject any other `refs/…`
            // (remote forms — origin/<b>, pr#<N> — are classified separately and left untouched). The
            // normalized string is CARRIED on the card (`spawnBase`); the reconciler-driven `materialize`
            // re-derives the remote/local classification (`RemoteParentRef.parse`) and cuts the worktree.
            // Non-blocking flip: spawn does NO remote fetch / `worktrees.ensure` / lineage record / checkout.
            var normalizedBase = input.base?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let b = normalizedBase, b.hasPrefix("refs/"),
               RemoteParentRef.parse(b, remotes: gitRemotes(repo: realRepo)) == nil {
                guard b.hasPrefix("refs/heads/") else {
                    throw OrchestraError.invalidParams("base must be a branch name, origin/<b>, or pr#<N> — not \(b)")
                }
                normalizedBase = String(b.dropFirst("refs/heads/".count))
            }
            spawnBaseCarrier = (normalizedBase?.isEmpty == false) ? normalizedBase : nil
            // PURE cwd (no checkout — the MaterializeStepper cuts/adopts the tree from `spawnBase`).
            cwd = worktrees.path(repo: realRepo, branch: input.branch)
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
        // A provisional card is idle awaiting the user's first prompt, so it lands `.waiting`; a real
        // prompt/seed means the agent is working immediately, so `.running`. The launch gets no positional
        // when provisional (a whitespace-only prompt must not be submitted to the agent).
        // NON-BLOCKING FLIP (PR4b Task 3): the card is CREATED at `.creatingWorktree, sessionEpoch: 1`
        // carrying `spawnBase` (creation IS spawn's single generation bump — no `transition(→.creatingWorktree)`),
        // then spawn RETURNS. The reconciler's steppers (MaterializeStepper cuts/adopts the worktree + records
        // lineage → LaunchStepper brings the agent up + confirms readiness) drive it `→.launching →.live` off
        // the poll loop. The launch's landing (.running / .waiting) + the prompt are re-derived from the
        // persisted `titleProvisional`/`initialPrompt` by `deriveLaunchFlavor`, so nothing is lost here.
        let task = Task(
            id: id,
            title: title, titleProvisional: provisional, desc: "",
            repo: realRepo, branch: input.branch, cwd: cwd,
            origin: origin, access: input.access,
            agentId: adapter.id, model: model, startIn: startIn,
            column: startIn.column, order: 0, phase: .creatingWorktree,
            sessionEpoch: 1, phaseChangedAt: Date(),
            pendingSeed: nil, spawnBase: spawnBaseCarrier,
            ctxPct: 0, agentSessionId: sid, initialPrompt: folded ?? input.prompt,
            parentBranch: nil            // materialize re-derives + records the parent link from `spawnBase`
        )
        let (created, createdRev) = try await store.create(task)
        emit(.taskUpserted(created), rev: createdRev)
        emitActivity(.spawned, created, source, "Spawned “\(title)”")

        // authMode soft-warn (E2 / q4 — advisory only, NEVER caps). Count active subscription-auth cards
        // for this adapter (the just-created card is already in the store) and warn past the threshold.
        let active = await store.all().filter { !$0.archived && $0.phase.kind != .dead }
        if let warn = authRate.warning(for: adapter.id, active: active, registry: registry) {
            emitActivity(.warning, created, source, warn.message)
        }

        // T2 (advisory only): an untrusted borrowed cwd will spawn sandboxed — tell the human how to grant
        // it. Resolve trust read-only here for the message; the LaunchStepper's `finishLaunch` resolves it
        // again for the actual launch (idempotent). Never blocks the spawn.
        if await resolveTrust(origin: origin, cwd: cwd, repo: realRepo) == .needsGrant {
            emitActivity(.warning, created, source,
                "“\(title)” runs untrusted (sandboxed) in \(cwd). To grant write trust, run "
                + "`orchestra trust \(cwd)` in a terminal, or keep it read-only.")
        }
        return created
    }

    /// Remove orphaned scratch dirs — `~/.orchestra/scratch/<id>` subdirs with no matching non-archived
    /// `.scratch` card. Covers a scratch card that died without a clean archive (so its `rm -rf` never
    /// ran). Run once at daemon startup. Like the archive arm, this only ever deletes under the scratch
    /// root (the entries are children of `Config.scratchRoot`).
    ///
    /// Deleting a dir is destructive and a live agent's cwd, so a mismatch here breaks a running card
    /// mid-turn (its `posix_spawn '/bin/sh'` starts failing with ENOENT). The store snapshot can diverge
    /// from the set of actually-live cards — a load hiccup returns `[]` (see `TaskStore.load`), and
    /// overlapping/relaunched daemons can sweep a lagging `tasks.json` while the prior daemon still owns
    /// live sessions. So a dir is deleted ONLY on POSITIVE evidence of orphan-hood, gated three ways:
    ///  (c) abort the whole sweep if the store came back empty — never read empty as "all orphaned";
    ///  (a) never touch a dir whose tmux session is live (agent-agnostic — rides `sessions.list()`);
    ///  (b) never touch a dir modified within the mtime grace window — a just-spawned dir whose card /
    ///      session hasn't registered yet must survive the race.
    public func sweepOrphanScratch(root: String = Config.scratchRoot,
                                   graceInterval: TimeInterval = 300) async {
        // (c) An empty store is indistinguishable from a failed load, so treat it as "unknown", not
        // "nothing is live" — bail rather than delete every scratch dir, live ones included. Kept
        // on-actor (a pure store read, no IO) so the off-actor hop below only runs once we know
        // there is something to sweep against.
        let cards = await store.all()
        guard !cards.isEmpty else { return }
        let liveScratchDirs = Set(cards
            .filter { $0.origin == .scratch && !$0.archived }
            .map { $0.cwd })

        let s = sessions
        try? await offActor {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return }

            // (a) Dir names are lowercase UUIDs; `UUID(uuidString:)` is case-insensitive, so `sessionName`
            // matches the live tmux set even though the id's canonical form is uppercase.
            let liveSessions = Set((try? s.list())?.filter(\.running).map(\.name) ?? [])
            let now = Date()

            for name in entries {
                let path = "\(root)/\(name)"
                if liveScratchDirs.contains(path) { continue }
                if let id = UUID(uuidString: name), liveSessions.contains(s.sessionName(id)) { continue }
                // (b) Skip anything modified within the grace window (freshly created / actively touched).
                if let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                   now.timeIntervalSince(mtime) < graceInterval { continue }
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Boot: one-time marker migration for pre-upgrade (marker-less) worktree trees. Non-archived worktree
    /// cards only; being-born phases excluded as defense-in-depth (they can't exist at the first post-upgrade
    /// boot anyway — those phases are new). The registry's sentinel makes this a genuine no-op on every later
    /// boot. MUST be `public` — `orchestrad` is a separate executable target and calls this from `main.swift`.
    public func stampMigratedWorktreeMarkersOnce() async {
        let paths = await store.all()
            .filter { !$0.archived && $0.origin == .worktree
                      && $0.phase.kind != .creatingWorktree && $0.phase.kind != .launching && $0.phase.kind != .relaunching }
            .map(\.cwd)
        await worktrees.stampMarkers(forMigratedPaths: paths)
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
    /// no-ops on a card that already has a turn coming (running, mid-relaunch, or subscribed through a
    /// native background `orchestra wait`). See `wake` for delivery: an idle card resume-seeds; a busy one
    /// drains at its Stop.
    public func send(_ id: UUID, _ message: String) async throws {
        let t = try await require(id)
        // Reject over-cap messages at the boundary rather than silently truncating them at delivery: the
        // inbox is a nudge channel (`StopDrain.maxMessageChars`), not a document transfer. An accepted
        // message is guaranteed to reach the agent whole.
        guard message.count <= StopDrain.maxMessageChars else {
            throw OrchestraError.invalidParams(
                "message is \(message.count) chars; the inbox limit is \(StopDrain.maxMessageChars). "
                + "Put large content in a file in the worktree and reference it instead.")
        }
        try await inbox.enqueue(t.id, message)
        await wake(t.id)
    }

    /// Send a constrained key chord to one of the card's tmux windows (default `agent`). Unlike
    /// `send` (which queues to the durable inbox), this delivers live keystrokes — used by the phone's
    /// captured-prompt semantic buttons and non-live steering fallbacks. Validation of the chord itself
    /// happens at the command boundary; here we just require a live card and forward to the session.
    public func sendChord(_ id: UUID, tokens: [KeyToken], window: String) async throws {
        let t = try await require(id)
        try sessions.sendChord(sessions.sessionName(t.id), tokens: tokens, window: window)
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
        // Whole-messages-to-fit: deliver only the messages that fit this turn's 10k budget and drain
        // exactly those; any overflow stays durable and drains on the next turn-end (never sliced mid-text).
        guard let (payload, consumed) = StopDrain.fit(pending) else { return nil }
        _ = try? await inbox.drainFirst(cardId, consumed)
        injectCounts[cardId] = count + 1
        return payload
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
                           report: StatusReport?, source: SessionSource?,
                           observedEpoch: Int? = nil) async -> HookResponse? {
        guard let task = try? await resolveRef(ref) else { return nil }
        if let report { try? await self.report(task.id, report, observedEpoch: observedEpoch) }
        if event == .sessionStart, let source, source != .startup, source != .compact,
           report?.event?.sessionSource == nil {
            try? await self.report(task.id, StatusReport(sessionSource: source.rawValue), observedEpoch: observedEpoch)
        }
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
        let current = try await require(id)
        guard current.origin == .worktree else {
            throw OrchestraError.invalidParams(
                "freeform cards stay in Freeform; only worktree cards can move between Plan, Implementation, and Review")
        }
        let from = current.column
        let (updated, rev) = try await store.move(id, to: column)
        emit(.taskUpserted(updated), rev: rev)
        emitActivity(.moved, updated, source, "→ \(column.displayName)")
        // A user drag / keyboard-carry on the board (`.app`) notifies the card that it was moved; a card
        // moving ITSELF via CLI/MCP/agent, or a no-op drop back into its own column, does not. Best-effort
        // (`try?`): a notification failure must never fail the move it is reporting on.
        if source == .app, from != column {
            try? await send(id, "You were moved from \(from.displayName) to \(column.displayName) by the user (via the board UI).")
        }
        return updated
    }

    public func status(_ id: UUID) async throws -> TaskStatus {
        let t = try await require(id)
        let name = sessions.sessionName(id), s = sessions
        let running = (try? await offActor { try s.isAlive(name) }) ?? false
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

    /// INTENT-ONLY (PR4b Task 4): record the archive intent + the `archived` Bool mirror (so the card leaves
    /// the board instantly) and RETURN. The reconciler's `TeardownStepper` runs the FULL duty list (kill /
    /// releaseBorrow / release / cancel debounces+watches / nudge-children) and flips `archivedPending →
    /// archivedComplete`; the funnel concludes on the non-terminal → `archivedPending` entry (no manual
    /// `concludeCard` here). No subprocess/teardown runs before the return — the verb is non-blocking.
    public func archive(_ id: UUID, source: ActivitySource = .daemon) async throws {
        let t = try await require(id)
        // Idempotency guard FIRST (spec §P1/§6/§11): an already-archived card is idempotent success. Without
        // this the tightened `isLegalEdge` makes `archivedComplete → archivedPending` illegal → a `.rejected`
        // error, breaking the retried-archive guarantee — the archive HANDLER is the idempotency point (the
        // PR4a decision that keeps `archive.phaseGate = gAll`).
        if t.phase.kind == .archivedPending || t.phase.kind == .archivedComplete { return }
        // The single intent write: phase → archivedPending, companion `archived = true` in the same patch so
        // the card is off the board before the duty list has run. The TeardownStepper owns the rest.
        _ = await transition(id, to: .archived(teardownComplete: false), mutate: { $0.archived = true })
        if let updated = await store.get(id) {
            emitActivity(.archived, updated, source, "Archived “\(updated.title)”")
        }
    }

    // MARK: - shells / exec / sessions

    /// Open a shell window in the card's worktree. With `window == nil` (the desktop path) a fresh
    /// `shell-N` window is created each call. With an explicit `window` (the phone-owned path) the
    /// named window is **reused if it already exists** — the idempotent-reconnect guarantee a phone
    /// client relies on so a re-attach doesn't leak a new window every time.
    public func openShell(_ id: UUID, window: String? = nil) async throws -> ShellTab {
        let t = try await require(id)
        let name = sessions.sessionName(id)
        if try !sessions.isAlive(name) { _ = try sessions.ensure(t, argv: ["/bin/sh"]) }
        let win = try window.map { try sessions.ensureShellWindow(name, window: $0, cwd: t.cwd) }
            ?? sessions.newShellWindow(name, cwd: t.cwd)
        await emitShells(t)
        observedSessions[t.id] = nil   // user-driven change — next snapshot live-shells fresh
        return ShellTab(window: win, label: win, pwd: t.cwd)
    }

    /// Recompute the card's shell-window set from tmux (authoritative) and broadcast it so every
    /// connected client — desktop or phone — renders the same set. Called after any shell open/close.
    /// Distinguishes "session genuinely has no shell windows" from "couldn't list the windows": a
    /// SUCCESSFUL listing that happens to contain only the `agent` window is a real, broadcastable
    /// "no shells" state, but a `windows()` FAILURE (transient tmux hiccup / unreachable server) is
    /// SKIPPED rather than broadcast as empty — emitting `[]` on a hiccup would wholesale-wipe every
    /// client's shell panel/selection until the next reconnect. The caller's own mutation already
    /// succeeded, and the next successful open/close (or reconnect reconcile) re-broadcasts the truth.
    private func emitShells(_ t: Task) async {
        let name = sessions.sessionName(t.id), s = sessions
        guard let targets = try? await offActor({ try s.windows(name) }) else { return }
        let shells = targets.filter { $0.kind == .shell }
            .map { ShellTab(window: $0.window, label: $0.window, pwd: t.cwd) }
        emit(.shellsChanged(ShellWindowsState(cardId: t.id, shells: shells)), rev: lastRev)
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
        await emitShells(t)
        observedSessions[t.id] = nil   // user-driven change — next snapshot live-shells fresh
        return ShellTab(window: win, label: win, pwd: t.cwd)
    }

    public func closeShell(_ id: UUID, window: String) async throws {
        let t = try await require(id)
        try sessions.closeShellWindow(sessions.sessionName(t.id), window: window)
        await emitShells(t)
        observedSessions[t.id] = nil   // user-driven change — next snapshot live-shells fresh
    }

    public func exec(_ id: UUID, _ cmd: String, timeout: Duration? = nil) async throws -> ExecResult {
        let t = try await require(id)
        // Only worktree cards are gated by the repo allowlist; borrowed/scratch cwds are trusted via
        // the OS sandbox (the path may live outside any allowlisted repo).
        if t.origin == .worktree { try resolver.assertAllowed(t.cwd) }
        let r = try await offActor {
            try Proc.run(["sh", "-c", cmd], cwd: t.cwd, timeout: timeout ?? .seconds(120))
        }
        let cap = 256 * 1024
        return ExecResult(stdout: String(r.stdout.prefix(cap)), stderr: String(r.stderr.prefix(cap)), exitCode: r.exitCode)
    }

    /// One-round-trip board snapshot: the full task/config/models/agents state PLUS every active card's
    /// shell sessions + agent-terminal owner. Replaces the client's `list`+`archivedList`+`getConfig`+
    /// `models`+`agents` calls AND the per-card `sessions`/`agentTerminalOwner` fan-out on every
    /// (re)connect. The per-card work stays serial (each `sessions` shells to tmux) but rides one RPC, so
    /// a 25-card board costs one round trip instead of ~50 — live events no longer wait seconds behind it.
    public func boardSnapshot() async -> BoardSnapshot {
        // Read `rev` BEFORE `list(nil)` (deliberate, fail-safe): a mutation landing between the two
        // awaits makes `snap.rev` ≤ the true rev of the task data, so a client's resync at worst
        // re-applies idempotently — it never drops a real event. Reading rev AFTER `list` could
        // over-claim (snapshot data older than its rev) and drop an event instead.
        let rev = await store.currentRev
        lastRev = rev
        let active = await list(nil)
        let archived = await archivedTasks()
        let now = Date()
        var sessionsList: [CardSessions] = []
        var owners: [AgentTerminalOwnerState] = []
        sessionsList.reserveCapacity(active.count)
        owners.reserveCapacity(active.count)
        for card in active {
            // Cache HIT: fresh vs the card's CURRENT session (`observedAt >= phaseChangedAt`) — serve the
            // reconciler's off-actor `windows()` capture instead of shelling out again (Task 5.2). A MISS
            // or a STALE entry (session changed since capture) falls back to one live shell so nothing is
            // mis-shown; the trade is up-to-one-tick staleness on the hit path, self-healed by the next
            // tick / live `shellsChanged` events.
            if let obs = observedSessions[card.id], obs.observedAt >= card.phaseChangedAt {
                // Agent identity is an fs read (non-tmux) — hop it off-actor like 5.1.3 so the hit path
                // stays fully off the tmux path. A nil `sessionInfo` (early-life, before the session id
                // binds) MUST serve the SAME fallback `AgentSessionInfo` `sessions(_:)` builds below, or
                // the hit branch is skipped and an early-life card live-shells every snapshot.
                let ctx = AdapterContext(cwd: card.cwd, model: card.model.id, sessionId: card.agentSessionId,
                                         name: card.title, orchestraBin: orchestraBin)
                let a = try? registry.get(card.agentId)
                let agent = (try? await offActor { a?.sessionInfo(ctx, current: card.agentSessionId, prior: card.priorSessionIds) }) ?? nil
                    ?? AgentSessionInfo(agentId: card.agentId, sessionId: card.agentSessionId, transcriptPath: nil,
                                        priorSessionIds: card.priorSessionIds, priorTranscripts: [], resumeCmd: nil)
                sessionsList.append(CardSessions(ref: card.ref(), id: card.id, worktree: card.cwd,
                    tmuxSocket: Config.tmuxSocket, session: sessions.sessionName(card.id),
                    running: obs.running, targets: obs.targets, agent: agent))
            } else if let s = try? await sessions(card.id) {
                sessionsList.append(s)
            }
            owners.append(terminalOwnership.snapshot(cardId: card.id, ref: card.ref(), now: now))
        }
        return BoardSnapshot(rev: rev, tasks: active, archived: archived, config: config,
                             models: models(agentId: nil), agents: agents(),
                             sessions: sessionsList, owners: owners)
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

    // MARK: - Agent-terminal ownership (ephemeral UI coordination)

    /// The owner-visible identity of a snapshot — everything a client renders EXCEPT `updatedAt`. Two
    /// snapshots with the same signature look identical to every consumer, so re-broadcasting one is pure
    /// churn (a whole-hierarchy re-render on the 10s heartbeat cadence — #4 / Lens-3 LOW).
    private struct OwnerEmitSig: Equatable {
        let kind: AgentTerminalOwnerKind?
        let clientId: String?
        let epoch: Int
        let stale: Bool
        init(_ s: AgentTerminalOwnerState) {
            kind = s.owner?.ownerKind; clientId = s.owner?.clientId; epoch = s.epoch; stale = s.stale
        }
    }

    /// Broadcast an owner event only when it changed something a client would render. takeOver (epoch++)
    /// and release (owner→nil) always differ, so they always emit; a steady heartbeat (same owner, same
    /// epoch, still fresh) is suppressed — which is exactly the "emit on heartbeat, skip if unchanged" of #4.
    private func emitOwnerIfChanged(_ state: AgentTerminalOwnerState) {
        let sig = OwnerEmitSig(state)
        guard lastEmittedOwnerSig[state.cardId] != sig else { return }
        lastEmittedOwnerSig[state.cardId] = sig
        emit(.agentTerminalOwner(state), rev: lastRev)
    }

    /// Current owner of the card's `agent` terminal (owner + epoch + stale/fresh). Read-only.
    public func agentTerminalOwner(_ ref: String) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        return terminalOwnership.snapshot(cardId: t.id, ref: t.ref(), now: Date())
    }

    /// Compare-and-set acquisition of the card's `agent` terminal: bump the epoch, set the owner,
    /// emit an owner event, and return the tmux attach target. Always wins (desktop Retake / takeover).
    ///
    /// Resolve the attach target FIRST, commit the CAS LAST (#1): the target lookup throws for a card
    /// whose `agent` window is dead, and if the CAS/emit ran before it, a *failed* takeover would steal a
    /// lease nobody can hold and strand the desktop on the placeholder (the owner event already unmounted
    /// it). Ordering the throwing work ahead of the mutation makes a failed takeover a no-op.
    public func takeOverAgentTerminal(_ ref: String, clientId: String,
                                      kind: AgentTerminalOwnerKind) async throws -> TakeOverResult {
        let t = try await resolveRef(ref)
        // Throwing work first — if the window is gone, we bail before touching ownership.
        let target = try await agentTarget(t.id)
        // Commit the lease only now that the attach is guaranteed to have a target. (The old
        // `detachAgentViewClients` belt-and-suspenders is gone — it could kick the desktop's own
        // just-connected client on first select (#8); the D5 desktop unmount + the phone's exclusive
        // `detach-client` recipe already handle the single-client invariant.)
        let state = terminalOwnership.takeOver(cardId: t.id, ref: t.ref(), clientId: clientId,
                                               kind: kind, now: Date())
        emitOwnerIfChanged(state)
        return TakeOverResult(state: state, target: target)
    }

    /// Release the card's `agent` terminal — clears the owner ONLY if the caller still holds the
    /// current epoch + clientId; otherwise throws `ownershipDenied`. Emits on success.
    public func releaseAgentTerminal(_ ref: String, clientId: String,
                                     epoch: Int) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        let state = try terminalOwnership.release(cardId: t.id, ref: t.ref(),
                                                  clientId: clientId, epoch: epoch, now: Date())
        emitOwnerIfChanged(state)
        return state
    }

    /// Refresh a takeover across reconnects — succeeds ONLY for the current epoch + clientId.
    ///
    /// A denied beat (a desktop retook, bumping the epoch) is NOT surfaced as an error (#3): the store
    /// throws on the CAS miss, but the phone that lost the lease needs the *current* owner back so its
    /// mirror can correct (drop "You have control") instead of `try?`-swallowing the throw and sitting on
    /// a stale `.holding`. So on denial we return the live snapshot — matching what callers already assume.
    ///
    /// On success we EMIT the refreshed owner state (#4) so the desktop mirror stays fresh and its
    /// placeholder stops falsely claiming "phone unreachable" ~30s into a healthy takeover. `emitOwnerIfChanged`
    /// suppresses the event when nothing owner-visible changed, so a steady 10s heartbeat doesn't re-render
    /// the whole board hierarchy every beat.
    public func heartbeatAgentTerminal(_ ref: String, clientId: String,
                                       epoch: Int) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        let now = Date()
        do {
            let state = try terminalOwnership.heartbeat(cardId: t.id, ref: t.ref(),
                                                        clientId: clientId, epoch: epoch, now: now)
            emitOwnerIfChanged(state)
            return state
        } catch let error as OrchestraError {
            if case .ownershipDenied = error {
                return terminalOwnership.snapshot(cardId: t.id, ref: t.ref(), now: now)
            }
            throw error
        }
    }

    /// Test hook: shrink/enlarge the ownership heartbeat window (default 30s) so staleness tests
    /// don't have to sleep the real timeout. Not called in production.
    func setOwnershipHeartbeatTimeout(_ t: TimeInterval) { terminalOwnership.heartbeatTimeout = t }

    /// The card's `agent` window as a ready-to-attach `TmuxTarget` (reuses the shipped `sessions`
    /// discovery). Throws if the card has no live `agent` window.
    private func agentTarget(_ id: UUID) async throws -> TmuxTarget {
        let cs = try await sessions(id)
        guard let agent = cs.targets.first(where: { $0.kind == .agent }) else {
            throw OrchestraError.io("no agent window for card \(id)")
        }
        return agent
    }

    /// Read-only snapshot of a card's `agent` (default) or a `shell-N` window — the phone Agent
    /// tab's v1 read source. No attach, no resize. Not allowlist-gated: it runs no user code, it
    /// only reads an existing pane (cf. `exec`, which does gate). Throws if the session isn't running.
    public func capture(_ id: UUID, window: String = "agent") async throws -> CaptureResult {
        _ = try await require(id)                     // validates the card exists
        let name = sessions.sessionName(id)
        guard try sessions.isAlive(name) else { throw OrchestraError.io("session not running") }
        return try sessions.capture(name, window: window, maxChars: 256 * 1024)
    }

    public func openInZed(_ id: UUID) async throws {
        let t = try await require(id)
        try launcher.openInZed(t.cwd, parentRef: resolvedParentRef(t))
    }

    /// Open the card's worktree as an Obsidian vault, jumped to the notes its branch changed.
    /// Returns `(opened:` tabs opened `, total:` changed `.md` count `)`.
    @discardableResult
    public func openNotes(_ id: UUID) async throws -> (opened: Int, total: Int) {
        let t = try await require(id)
        return try launcher.openNotes(t.cwd, parentRef: resolvedParentRef(t))
    }

    // MARK: - config

    public func getConfig() -> Config { config }

    @discardableResult
    public func setConfig(_ patch: (inout Config) -> Void) -> Config {
        patch(&config)
        resolver = PathResolver(config: config)
        worktrees = WorktreeRegistry(config: config, resolver: resolver)
        return config
    }

    // MARK: - spawn targets (Spawn sheet enumeration; app-only, NOT an agent command)

    /// Git repos under `config.reposRoot` + freeform dir candidates, for the phone's Spawn sheet — a
    /// remote client that can't browse the daemon's disk. Ports the desktop sheet's local
    /// `repoCandidates`. Absolute paths (the allowlist rejects bare names).
    public func spawnRepos() async -> [String] {
        let root = (config.reposRoot as NSString).expandingTildeInPath
        return (try? await offActor {
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            // Absolute paths to the git repos under reposRoot. These double as the freeform dir candidates
            // (running a read-only/freeform agent inside a repo is the common case) — the client unions
            // them with dirs derived from existing borrowed cards, so no separate `dirs` list is needed.
            return entries
                .filter { !$0.hasPrefix(".") }
                .map { "\(root)/\($0)" }
                .filter { fm.fileExists(atPath: "\($0)/.git") }
                .sorted {
                    ($0 as NSString).lastPathComponent
                        .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
                }
        }) ?? []
    }

    /// Local branch names for `repo`, most-recent-commit first (ports the desktop sheet's `gitBranches`).
    /// Empty on any failure (bad repo, git missing, not a worktree) so the picker degrades to free-text
    /// branch creation. Defense-in-depth: only runs git on an allowlisted repo path.
    public func spawnBranches(repo: String) async -> [String] {
        guard !repo.isEmpty, let real = try? resolver.resolveRepo(repo) else { return [] }
        return (try? await offActor {
            guard let res = try? Proc.run(
                ["git", "-C", real, "for-each-ref", "--format=%(refname:short)",
                 "--sort=-committerdate", "refs/heads"],
                timeout: .seconds(5)), res.ok else { return [] }
            return res.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }) ?? []
    }

    /// Convenient starting points for the phone's remote directory browser (`listDir`): the daemon's
    /// `$HOME` plus the spawn allowlist roots, canonicalized and de-duplicated. These are UX affordances
    /// (the synthetic root listing the browser opens on), NOT a confinement boundary — `listDir` can
    /// enumerate any directory the daemon user can read (the same socket already exposes `exec`, so
    /// confining *enumeration* would defend nothing while blocking the owner from real paths).
    var browseRoots: [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for p in ([Config.home] + config.allowedRoots).map({ PathResolver.canonical($0) }) where !p.isEmpty {
            if seen.insert(p).inserted { roots.append(p) }
        }
        return roots
    }

    /// Display label for a browse root in the synthetic root listing: "Home" for `$HOME`, else basename.
    private func browseRootName(_ path: String) -> String {
        if path == PathResolver.canonical(Config.home) { return "Home" }
        return (path as NSString).lastPathComponent
    }

    /// List a directory's children for the phone's remote browser. The phone can't browse the daemon's
    /// disk, so the daemon enumerates for it. `browseRoots` are the starting points; from there the owner
    /// can browse anywhere the daemon user can read (no confinement — the same socket exposes `exec`).
    /// Dotfiles are hidden as declutter; directories sort before files. `path` nil/empty → the synthetic
    /// *root listing* (the browse roots themselves). App-only (NOT a registry Command): agents spawn via
    /// `spawn`, they never browse the daemon disk.
    public func listDir(_ path: String?) throws -> DirListing {
        let roots = browseRoots
        guard let raw = path, !raw.isEmpty else {
            let entries = roots.map { DirEntry(path: $0, name: browseRootName($0), isDir: true) }
            return DirListing(path: "", parent: nil, entries: entries)
        }
        let real = PathResolver.canonical(raw)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else {
            throw OrchestraError.invalidParams("listDir: not a directory: \(raw)")
        }
        var dirs: [DirEntry] = []
        var files: [DirEntry] = []
        for name in (try? fm.contentsOfDirectory(atPath: real)) ?? [] where !name.hasPrefix(".") {
            let child = "\(real)/\(name)"
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: child, isDirectory: &childIsDir) else { continue }
            let entry = DirEntry(path: child, name: name, isDir: childIsDir.boolValue)
            if childIsDir.boolValue { dirs.append(entry) } else { files.append(entry) }
        }
        let byName: (DirEntry, DirEntry) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        dirs.sort(by: byName); files.sort(by: byName)

        // "Up" affordance: the filesystem parent, nil only at the filesystem root.
        let parentPath = (real as NSString).deletingLastPathComponent
        let parent: String? = parentPath != real ? PathResolver.canonical(parentPath) : nil

        return DirListing(path: real, parent: parent, entries: dirs + files)
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

    /// Bundle the live dependencies a `PhaseStepper` needs. PR4b's reconciler builds one per tick; the
    /// `transition` closure re-enters this actor so the funnel stays the sole `phase` writer.
    func convergeContext() -> ConvergeContext {
        ConvergeContext(
            store: store, worktrees: worktrees, sessions: sessions, adapters: registry, inbox: inbox,
            transition: { [self] id, to, epoch, mutate in
                await transition(id, to: to, observedEpoch: epoch, mutate: mutate)
            },
            materialize: { [self] id in await materialize(id) },
            finishLaunch: { [self] id, flavor in await finishLaunch(id, flavor: flavor) },
            teardownActorDuties: { [self] id in await teardownActorDuties(id) },
            emitActivity: { [self] id, kind, text in
                let task = await store.get(id)
                await emitActivity(kind, task, .daemon, text)
            })
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
        orderedAdapters().map {
            AgentInfo(id: $0.id, name: $0.name, icon: $0.icon,
                      models: $0.models(), capabilities: $0.capabilities)
        }
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
