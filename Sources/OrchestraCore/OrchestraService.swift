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
    /// O3: child card → the throwaway `orch-borrow-*` worktree it borrowed to squash-merge into a bare
    /// parent. Released explicitly (`release`) or swept on the child's archive / at startup.
    var borrowedWorktrees: [UUID: String] = [:]
    /// Durable inbox routing for the fan-out: watcher card → the children it is watching. A child's
    /// conclusion enqueues into every watching parent's inbox (F3 coalesce) + wakes it (F2).
    var watchRegistry: [UUID: Set<UUID>] = [:]
    /// Watchers with a live CLI `orchestra wait` process. A native-reinvoke card only defers wake to
    /// wait-exit when this is present; MCP/tool watches register interest without a CLI process.
    var activeWaitProcesses: [UUID: Int] = [:]
    /// Consecutive auto-injects per card since the last genuine user prompt — the F3 loop guard.
    /// `stop_hook_active` is informational on both agents, so Orchestra enforces the cap itself.
    var injectCounts: [UUID: Int] = [:]
    /// Break a runaway Stop→inject→Stop loop after this many consecutive auto-injects (reset by a real prompt).
    public let maxConsecutiveInjects = 25

    // Event fan-out.
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    // Ephemeral, daemon-authoritative agent-terminal ownership (UI coordination — never persisted).
    var terminalOwnership = TerminalOwnershipStore()
    // Last owner event BROADCAST per card, compared owner-visible-fields-only so a 10s heartbeat that
    // changed nothing but `updatedAt` doesn't re-emit and re-render the whole board hierarchy (#4).
    private var lastEmittedOwnerSig: [UUID: OwnerEmitSig] = [:]
    // Per-card monotonic seq guard for snapshot reports.
    var lastSeqStore: [UUID: UInt64] = [:]
    // Pending resume confirmations (resolved by the SessionStart(resume) callback or a timeout). Keyed by
    // card id but TOKEN-tagged: two overlapping resume() for the same id must never silently clobber (and
    // thus LEAK) the earlier continuation — the displaced waiter is resolved `.superseded`, and a stale
    // timeout is ignored unless its token still owns the slot. See `awaitResume`/`resolveResume`.
    var resumeWaiters: [UUID: (token: UInt64, cont: CheckedContinuation<ResumeOutcome, Never>)] = [:]
    // Monotonic tag minted per awaitResume so a timeout only fires for the waiter it was scheduled for.
    var resumeTokenSeq: UInt64 = 0
    // A SessionStart(resume) callback can arrive BEFORE `awaitResume` registers its waiter, because
    // resume()'s off-actor relaunch frees this reentrant actor to service `report()` mid-revival. We
    // remember such early confirmations here so the waiter consumes them instead of losing the wakeup
    // and timing out. Cleared at the start of each resume attempt so a late callback from a prior,
    // already-failed attempt can't spuriously confirm a future one.
    var pendingResumeConfirmations: Set<UUID> = []
    // Cards currently being revived/restarted — guarded against the liveness reconcile.
    var recovering: Set<UUID> = []
    // Per-card coalescing debounce for the diffstat recompute (code-review-on-board). A one-shot per
    // activity burst off the normalized `report()` funnel — NOT a periodic poll.
    var diffStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]
    // Per-card coalescing debounce for the TreeStat recompute (branch-tree, BT4). Twin of
    // `diffStatDebounce` — a one-shot per activity burst off the `report()` funnel, not a poll.
    var treeStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]
    // Per-parent coalescing debounce for the child fan-out (branch-tree, BT4). Keeps the `git config
    // --get-regexp` child lookup OFF the hot report path — one lookup per activity burst, not per report.
    var childFanoutDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]

    public init(config: Config,
                store: TaskStore? = nil,
                registry: AgentRegistry = AgentRegistry(),
                worktrees: (any WorktreeManaging)? = nil,
                sessions: (any SessionManaging)? = nil,
                launcher: Launcher? = nil,
                resolver: PathResolver? = nil,
                trust: TrustLedger? = nil,
                inbox: Inbox? = nil,
                devices: DeviceTokenStore? = nil,
                grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                orchestraBin: String = siblingBinary("orchestra")) {
        self.config = config
        self.orchestraBin = orchestraBin
        let r = resolver ?? PathResolver(config: config)
        self.resolver = r
        self.store = store ?? TaskStore()
        self.trust = trust ?? TrustLedger()
        self.inbox = inbox ?? Inbox()
        self.devices = devices ?? DeviceTokenStore()
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
        var derivedParentBranch: String? = nil
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
            // S2-3(i): normalize a user-supplied LOCAL base to a bare branch name BEFORE `ensure`. `ensure`
            // accepts a refs/-prefixed base verbatim (for the internal remote private-ref path), but
            // `recordSpawnBase` then resolves refs/heads/<base> → refs/heads/refs/heads/foo and throws AFTER
            // the worktree is cut. Strip a refs/heads/ prefix; reject any other refs/… (remote forms —
            // origin/<b>, pr#<N> — are classified separately and left untouched).
            var normalizedBase = input.base?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let b = normalizedBase, b.hasPrefix("refs/"),
               RemoteParentRef.parse(b, remotes: gitRemotes(repo: realRepo)) == nil {
                guard b.hasPrefix("refs/heads/") else {
                    throw OrchestraError.invalidParams("base must be a branch name, origin/<b>, or pr#<N> — not \(b)")
                }
                normalizedBase = String(b.dropFirst("refs/heads/".count))
            }
            // Classify the base: a remote form (origin/<b>, pr#<N>, BT6) is fetched into a private ref
            // FIRST, and that ref becomes the new branch's start-point. A local base flows through unchanged.
            let remoteRef = normalizedBase.flatMap { RemoteParentRef.parse($0, remotes: gitRemotes(repo: realRepo)) }
            var remoteFetchedOID: String? = nil
            var ensureBase = normalizedBase
            if let remoteRef {
                let b = normalizedBase ?? remoteRef.canonical
                remoteFetchedOID = try await remoteParents.fetch(repo: realRepo, remoteRef,
                    context: "spawn base \(b): could not fetch remote parent \(b)")
                ensureBase = remoteRef.privateRef
            }
            let ensured = try worktrees.ensure(repo: realRepo, branch: input.branch, base: ensureBase)
            cwd = ensured.worktree
            origin = .worktree
            // S2-3(ii): a brand-new branch cannot have had children before it existed, so any pre-existing
            // `orchestra-parent == <this branch>` is a dangling value left by a deleted same-named branch
            // (name reuse). Prune those stale links before recording, so the cycle guard doesn't walk the
            // dangling chain and reject a legitimate reuse (fixture-proven false "would create a cycle").
            if !ensured.branchExisted {
                for stale in await lineage.children(repo: realRepo, of: input.branch) {
                    try? await lineage.clear(repo: realRepo, branch: stale)
                }
            }
            // S2-3(iii): a lineage-record failure fires AFTER the worktree + branch were created. Roll them
            // back so the failed spawn leaves no orphan worktree/branch that a retry's fileExists fast-path
            // would silently adopt with no base.
            do {
                // Churn derivation: only a PRE-EXISTING branch can carry durable lineage config (the parent
                // link survives card archival), so re-derive the parentBranch cache only then — gated on
                // `ensure`'s branch-existence signal so a brand-new branch's spawn never pays for a wasted
                // `git config` read on the hot path.
                if ensured.branchExisted {
                    // Existing branch: `base` is deliberately ignored (L2 contract); derive parent from config.
                    derivedParentBranch = await lineage.read(repo: realRepo, branch: input.branch)?.parent
                } else if let remoteRef, let oid = remoteFetchedOID {
                    // Remote spawn-with-base (BT6): branch created on the fetched private ref — record the
                    // canonical remote lineage (+prNumber, watch on by default) with the fetched tip as base.
                    derivedParentBranch = try await recordSpawnRemoteBase(
                        repo: realRepo, branch: input.branch, ref: remoteRef, oid: oid)
                } else if let base = normalizedBase, !base.isEmpty {
                    // Spawn-with-base (BT2): the branch was just CREATED on `base` — record the parent link
                    // (parent = base, recorded base OID = base tip) so the card is parent-aware from spawn.
                    derivedParentBranch = try await recordSpawnBase(repo: realRepo, branch: input.branch, base: base)
                }
            } catch {
                try? worktrees.remove(worktree: ensured.worktree, force: true)
                if !ensured.branchExisted {
                    _ = try? Proc.run(["git", "-C", realRepo, "branch", "-D", input.branch])
                }
                throw OrchestraError.io("spawn rolled back (worktree/branch removed): \(error)")
            }
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
            ctxPct: 0, agentSessionId: sid, initialPrompt: folded ?? input.prompt,
            parentBranch: derivedParentBranch
        )
        let created = try await store.create(task)

        // INVARIANT (mirrors resume/restart): guard the create → ensure window. The card is now
        // persisted as `.running`/`.waiting`, but its tmux session isn't created until `sessions.ensure`
        // below — and `resolveTrust` awaits the TrustLedger actor in between, suspending this actor. Without
        // this, the background liveness poll (`reconcileLiveness`) can interleave at that suspension, see a
        // session-less non-dead card, and falsely mark it `.dead(sessionVanished)`. `recovering` makes the
        // poll skip it until the session exists.
        recovering.insert(id)
        defer { recovering.remove(id) }

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

        // BT6: a card whose recorded lineage is a WATCHED remote parent starts its merge-watch. Gate on the
        // link's `watch` flag (a fresh remote-base spawn sets it true; a churn re-spawn onto an existing
        // branch with watch=false must not start one) rather than relying on the loop to bail on tick 1.
        if RemoteParentRef.parse(derivedParentBranch ?? "", remotes: gitRemotes(repo: realRepo)) != nil,
           await lineage.read(repo: realRepo, branch: input.branch)?.watch == true {
            startRemoteWatch(cardId: id)
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
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return }

        // (c) An empty store is indistinguishable from a failed load, so treat it as "unknown", not
        // "nothing is live" — bail rather than delete every scratch dir, live ones included.
        let cards = await store.all()
        guard !cards.isEmpty else { return }
        let liveScratchDirs = Set(cards
            .filter { $0.origin == .scratch && !$0.archived }
            .map { $0.cwd })

        // (a) Dir names are lowercase UUIDs; `UUID(uuidString:)` is case-insensitive, so `sessionName`
        // matches the live tmux set even though the id's canonical form is uppercase.
        let liveSessions = Set((try? sessions.list())?.filter(\.running).map(\.name) ?? [])
        let now = Date()

        for name in entries {
            let path = "\(root)/\(name)"
            if liveScratchDirs.contains(path) { continue }
            if let id = UUID(uuidString: name), liveSessions.contains(sessions.sessionName(id)) { continue }
            // (b) Skip anything modified within the grace window (freshly created / actively touched).
            if let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
               now.timeIntervalSince(mtime) < graceInterval { continue }
            try? fm.removeItem(atPath: path)
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
                           report: StatusReport?, source: SessionSource?) async -> HookResponse? {
        guard let task = try? await resolveRef(ref) else { return nil }
        if let report { try? await self.report(task.id, report) }
        if event == .sessionStart, let source, source != .startup, source != .compact,
           report?.event?.sessionSource == nil {
            try? await self.report(task.id, StatusReport(sessionSource: source.rawValue))
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
        let updated = try await store.move(id, to: column)
        emit(.taskUpserted(updated))
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
        stopRemoteWatch(id)   // BT6: tear down any remote merge-watch before the card goes away
        remoteWatchGen[id] = nil   // S4: the card is terminal — drop its generation entry (bounds the map)
        stopMergeRequestNudge(id)   // O2: tear down any pending merge-request re-nudge loop
        if let borrow = borrowedWorktrees[id] {   // O3: sweep a borrow the card left open
            try? worktrees.remove(worktree: borrow, force: true)
            borrowedWorktrees[id] = nil
        }
        // S3-5: cancel this card's tree debounce slots so a pending recompute/fan-out can't fire against
        // an archived card (the recompute itself now also guards on !archived — this is the clean-up half).
        treeStatDebounce[id]?.cancel(); treeStatDebounce[id] = nil
        childFanoutDebounce[id]?.cancel(); childFanoutDebounce[id] = nil
        // S2-5: a worktree card's branch goes bare on archive — nudge its live children so a stopped child
        // re-evaluates its ship path instead of waiting on the archived card's (now dead) inbox.
        if t.origin == .worktree {
            let childBranches = await lineage.children(repo: t.repo, of: t.branch)
            if !childBranches.isEmpty {
                let active = await store.all().filter { $0.id != id }
                for cb in childBranches {
                    // S2-6: deterministic (oldest) live child, not an arbitrary co-located sibling.
                    if let card = derivedCard(repo: t.repo, branch: cb, among: active) {
                        try? await inbox.enqueue(card.id,
                            "parent card \(t.branch) archived — the parent branch is now bare; re-run your ship")
                        await wake(card.id)
                    }
                }
            }
        }
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
        emitShells(t)
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
    private func emitShells(_ t: Task) {
        let name = sessions.sessionName(t.id)
        guard let targets = try? sessions.windows(name) else { return }
        let shells = targets.filter { $0.kind == .shell }
            .map { ShellTab(window: $0.window, label: $0.window, pwd: t.cwd) }
        emit(.shellsChanged(ShellWindowsState(cardId: t.id, shells: shells)))
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
        emitShells(t)
        return ShellTab(window: win, label: win, pwd: t.cwd)
    }

    public func closeShell(_ id: UUID, window: String) async throws {
        let t = try await require(id)
        try sessions.closeShellWindow(sessions.sessionName(t.id), window: window)
        emitShells(t)
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

    /// One-round-trip board snapshot: the full task/config/models/agents state PLUS every active card's
    /// shell sessions + agent-terminal owner. Replaces the client's `list`+`archivedList`+`getConfig`+
    /// `models`+`agents` calls AND the per-card `sessions`/`agentTerminalOwner` fan-out on every
    /// (re)connect. The per-card work stays serial (each `sessions` shells to tmux) but rides one RPC, so
    /// a 25-card board costs one round trip instead of ~50 — live events no longer wait seconds behind it.
    public func boardSnapshot() async -> BoardSnapshot {
        let active = await list(nil)
        let archived = await archivedTasks()
        let now = Date()
        var sessionsList: [CardSessions] = []
        var owners: [AgentTerminalOwnerState] = []
        sessionsList.reserveCapacity(active.count)
        owners.reserveCapacity(active.count)
        for card in active {
            if let s = try? await sessions(card.id) { sessionsList.append(s) }
            owners.append(terminalOwnership.snapshot(cardId: card.id, ref: card.ref(), now: now))
        }
        return BoardSnapshot(tasks: active, archived: archived, config: config,
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
        emit(.agentTerminalOwner(state))
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
        worktrees = WorktreeManager(config: config, resolver: resolver)
        return config
    }

    // MARK: - spawn targets (Spawn sheet enumeration; app-only, NOT an agent command)

    /// Git repos under `config.reposRoot` + freeform dir candidates, for the phone's Spawn sheet — a
    /// remote client that can't browse the daemon's disk. Ports the desktop sheet's local
    /// `repoCandidates`. Absolute paths (the allowlist rejects bare names).
    public func spawnRepos() -> [String] {
        let root = (config.reposRoot as NSString).expandingTildeInPath
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        // Absolute paths to the git repos under reposRoot. These double as the freeform dir candidates
        // (running a read-only/freeform agent inside a repo is the common case) — the client unions them
        // with dirs derived from existing borrowed cards, so no separate `dirs` list is needed.
        return entries
            .filter { !$0.hasPrefix(".") }
            .map { "\(root)/\($0)" }
            .filter { fm.fileExists(atPath: "\($0)/.git") }
            .sorted {
                ($0 as NSString).lastPathComponent
                    .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
            }
    }

    /// Local branch names for `repo`, most-recent-commit first (ports the desktop sheet's `gitBranches`).
    /// Empty on any failure (bad repo, git missing, not a worktree) so the picker degrades to free-text
    /// branch creation. Defense-in-depth: only runs git on an allowlisted repo path.
    public func spawnBranches(repo: String) -> [String] {
        guard !repo.isEmpty, let real = try? resolver.resolveRepo(repo) else { return [] }
        guard let res = try? Proc.run(
            ["git", "-C", real, "for-each-ref", "--format=%(refname:short)",
             "--sort=-committerdate", "refs/heads"],
            timeout: .seconds(5)), res.ok else { return [] }
        return res.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
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
