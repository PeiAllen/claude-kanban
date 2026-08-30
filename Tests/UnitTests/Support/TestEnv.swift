import Foundation
import TestSupport
@testable import OrchestraCore

/// Collect events from a service subscription for assertions.
actor EventCollector {
    private(set) var events: [Event] = []
    func start(_ stream: AsyncStream<EventEnvelope>) {
        _Concurrency.Task { for await e in stream { self.append(e.event) } }
    }
    private func append(_ e: Event) { events.append(e) }
    var activities: [ActivityItem] {
        events.compactMap { if case .activity(let a) = $0 { return a } else { return nil } }
    }
    var upserts: [Task] {
        events.compactMap { if case .taskUpserted(let t) = $0 { return t } else { return nil } }
    }
    var ownerStates: [AgentTerminalOwnerState] {
        events.compactMap { if case .agentTerminalOwner(let s) = $0 { return s } else { return nil } }
    }
}

/// Stub human-grant resolver: returns a fixed outcome and records what it was asked (drives the
/// approve / deny grant tests without a live MCP client or tty — O7).
final class StubGrantResolver: TrustGrantResolver, @unchecked Sendable {
    let outcome: TrustGrantOutcome
    private let lock = NSLock()
    private(set) var asked: [(path: String, source: ActivitySource)] = []
    init(_ outcome: TrustGrantOutcome) { self.outcome = outcome }
    func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome {
        lock.withLock { asked.append((path, source)) }
        return outcome
    }
}

enum TestEnv {
    /// A service wired with stubs + a controllable adapter, all under a temp dir allowlist.
    /// `extraAgents` registers ADDITIONAL stub adapters beside the default `claude-code` one, each with its
    /// own model catalog — so a test can prove a model id that is valid for ANOTHER agent is still rejected
    /// on this card (a card's `agentId` never changes, so its catalog is the only one that may authorize a
    /// re-seat). They share the default adapter's transcript dir, so `writeTranscript` works for all of them.
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .stub,
                     grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                     registry: AgentRegistry? = nil,
                     extraAgents: [(id: String, models: [String])] = [],
                     clock: any Clock<Duration> = ContinuousClock(),
                     now: (@Sendable () -> Date)? = nil,
                     proc: (any ProcRunning)? = nil,
                     traceHTTPBaseURL: String? = nil)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let base = NSTemporaryDirectory() + "orch-svc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)],
                            maxConcurrentRevivals: maxRevivals, revivalGraceSeconds: grace,
                            // A launch timeout the test cannot outlive. The product default is 30s, which is
                            // right for a real daemon — but a test's bring-up is driven by ITS OWN
                            // `reconcile()` polling, and under `--parallel` load a single reconcile can cost
                            // ~20s. The card then blows the 30s launch deadline and the reconciler correctly
                            // concludes `dead(spawnFailed)` — so the test's premise ("the card reaches
                            // `.live`") evaporates and it fails asserting a behavior that never got to run.
                            // Same trap as the startup grace (see `spawnStartupPending`): a wall-clock
                            // deadline the machine, not the product, decides.
                            //
                            // Tests that genuinely EXERCISE the timeout are unaffected: they back-date
                            // `phaseChangedAt` by `-(config.sessionLaunchTimeout + n)`, reading the value
                            // from config, so the arm still fires deterministically at any setting.
                            sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtRegistry = WorktreeRegistry(config: config, manager: worktrees,
                                          borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json", clock: clock)
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        // Share one time source across the Inbox and the service so persistence assertions use a
        // deterministic timeline.
        let nowProvider: @Sendable () -> Date = now ?? { Date() }
        let inbox = Inbox(path: base + "/inbox.json", now: nowProvider)
        let extras = extraAgents.map {
            StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities,
                        id: $0.id, name: $0.id, modelIds: $0.models)
        }
        let svc = OrchestraService(config: config, store: store,
                                   registry: registry ?? AgentRegistry(adapters: [adapter] + extras),
                                   worktrees: wtRegistry, sessions: sessions, trust: trust, inbox: inbox,
                                   grantResolver: grantResolver,
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                   traceHTTPBaseURL: traceHTTPBaseURL,
                                   clock: clock, now: nowProvider, proc: proc ?? Self.defaultFakeProc(),
                                   gitRemotesProbe: { _ in [] })
        return (svc, sessions, worktrees, adapter, trust, PathResolver.canonical(base))
    }

    /// Rebuild a fresh service over the SAME on-disk stores as an earlier `make()` — simulates a daemon
    /// restart (in-memory timers/loops are gone; the file-backed store/inbox/trust reload from disk).
    /// Pass the canonical `base` that `make()` returned: `make` writes those files under the non-canonical
    /// `NSTemporaryDirectory()` prefix, which is the same inode via the macOS `/var → /private/var` symlink,
    /// so this reads exactly the files `make` wrote. Non-path knobs (revival tuning) reset to defaults —
    /// itself a realistic "fresh daemon" trait.
    static func remake(base: String, capabilities: AgentCapabilities = .stub,
                       registry: AgentRegistry? = nil,
                       clock: any Clock<Duration> = ContinuousClock(),
                       now: (@Sendable () -> Date)? = nil,
                       proc: (any ProcRunning)? = nil)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let config = Config(reposRoot: base + "/repos",
                            worktreesRoot: base + "/worktrees",
                            allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtRegistry = WorktreeRegistry(config: config, manager: worktrees,
                                          borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json", clock: clock)
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let nowProvider: @Sendable () -> Date = now ?? { Date() }
        let inbox = Inbox(path: base + "/inbox.json", now: nowProvider)
        let svc = OrchestraService(config: config, store: store,
                                   registry: registry ?? AgentRegistry(adapters: [adapter]),
                                   worktrees: wtRegistry, sessions: sessions, trust: trust, inbox: inbox,
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                   clock: clock, now: nowProvider, proc: proc ?? Self.defaultFakeProc(),
                                   gitRemotesProbe: { _ in [] })
        return (svc, sessions, worktrees, adapter, trust, base)
    }

    /// Tier honesty (Task 10 flip): the DEFAULT git seam for a stub-wired service is a fresh FakeProc
    /// with the GitConfigEmulator pre-installed — never a real fork. A test that genuinely needs real
    /// git threads its own `proc:` (or runs in the contract tier over the real-worktree environment,
    /// which keeps the OrchestraService RealProc default). One fresh instance per call: no cross-test sharing.
    static func defaultFakeProc() -> any ProcRunning {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        return fake
    }

    /// **Intent-only-archive migration helper (PR4b Task 4).** `archive` now records the intent
    /// (`→ archivedPending` + the `archived` Bool) and RETURNS; the reconciler's `TeardownStepper` runs the
    /// full duty list (kill / releaseBorrow / release / cancel debounces+watches / nudge-children) and flips
    /// `→ archivedComplete`. This archives THEN drives `reconcile()` until teardown completes — a behavior-
    /// preserving drop-in for the pre-flip synchronous `archive` that most tests used as SETUP.
    static func archiveAndTeardown(_ svc: OrchestraService, _ id: UUID, source: ActivitySource = .daemon) async throws {
        try await svc.archive(id, source: source)
        try await pollUntil {
            await svc.reconcile()
            return await svc.list(includeArchived: true).first { $0.id == id }?.phase.kind == .archivedComplete
        }
    }

    /// **Intent-only relaunch/reopen migration helper (PR4b Task 4).** `resume`/`restart`/`reopen`/`handoff`
    /// now record the intent (`→ .relaunching` or `→ .creatingWorktree`) and RETURN; the reconciler's steppers
    /// drive the walk to `.live`. This drives `reconcile()` until `id` is `.live`, hand-delivering the agent's
    /// readiness signal each transitional tick when `inject` is set (needed for AWAITING caps —
    /// `.sessionStartHook`/`.rolloutMeta`; harmless for the immediate `.relaunchLiveness` stub). Returns the
    /// live card.
    @discardableResult
    /// A `ControlClient` pointed at an IN-PROCESS test daemon, with deadlines sized for the test machine.
    ///
    /// `ControlClient`'s 15s call/probe defaults are a PRODUCT default: the right bound for a real daemon in
    /// its own process, answering a client on an idle box. A test daemon shares a machine oversubscribed by
    /// the whole `--parallel` suite (900 tests, thousands of git/tmux forks), where even a trivial `version`
    /// reply — which never touches the service actor — waits tens of seconds for a thread. Inheriting the
    /// product default therefore makes every round-trip test a wall-clock assertion about the HOST, and it
    /// fails as `daemon did not answer version probe (connection closed)`: the daemon is healthy, merely
    /// descheduled. Deadlines are client POLICY (see `CLIRunner.rpcTimeout`, which exposes the same knob to
    /// the real CLI for a loaded host) — so give the in-process tests room and let them assert behavior.
    static func controlClient(_ socketPath: String, source: ActivitySource) -> ControlClient {
        ControlClient(socketPath: socketPath, source: source,
                      callTimeout: .seconds(120), probeTimeout: .seconds(120))
    }

    /// Spawn, drive to `.live`, and leave the card STILL STARTUP-PENDING — with a grace the spawn cannot
    /// outlive.
    ///
    /// `spawnPending[id]` bakes its deadline at ARM time (`Date() + spawnGraceSeconds`, inside the spawn), so
    /// raising the grace afterwards CANNOT re-arm an existing deadline — the widespread
    /// `spawnAndAwaitLive(…)` then `setStartupConfirmation(graceSeconds: …)` order was arming the default 4s
    /// and only *then* asking for a longer one. And `spawnAndAwaitLive` itself polls `reconcile()`, which
    /// folds in the liveness pass: under `--parallel` load the spawn routinely outlives its own 4s deadline,
    /// so `confirmSpawnStartup` sees `.alive` past-deadline and GRADUATES the card (`clearSpawnPending`).
    /// A later `setPaneDead` is then classified `.sessionVanished` rather than `.spawnExitedImmediately`,
    /// and the test fails asserting a product behavior that never had a chance to run.
    ///
    /// Arming a grace the spawn cannot outlive makes these tests about the BEHAVIOR (how an abort is
    /// classified) instead of about whether the machine was fast enough. Tests that need the retry's or the
    /// graduation's deadline to be in the PAST set `graceSeconds: 0` AFTER this call — that re-arms on the
    /// retry, which is exactly the deadline they mean.
    static func spawnStartupPending(_ svc: OrchestraService, _ input: SpawnInput,
                                    maxRetries: Int = 1) async throws -> Task {
        await svc.setStartupConfirmation(graceSeconds: 3600, maxRetries: maxRetries)
        return try await spawnAndAwaitLive(svc, input)
    }

    /// Drive the reconciler until `id` is `.live`. On timeout, re-read the card and say what phase it was
    /// ACTUALLY stuck in — "never reached .live" is useless on its own; "stuck in .dead(.agentExited)" names
    /// the bug. A card that lands `.dead` will never reach `.live`, so the wait was doomed, not merely slow.
    static func reconcileToLive(_ svc: OrchestraService, _ id: UUID, inject: Bool = false) async throws -> Task {
        do {
            try await pollUntilInner(svc, id, inject: inject)
        } catch let e as PollTimeout {
            let card = await svc.list(includeArchived: true).first { $0.id == id }
            let phase = card.map { "\($0.phase.kind)\($0.deadReason.map { r in "(\(r))" } ?? "")" } ?? "<no such card>"
            throw PollTimeout(what: "\(e.what) — card was stuck in phase: \(phase)", waited: e.waited, polls: e.polls)
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == id }) else {
            throw OrchestraError.unknownTask(id.uuidString)
        }
        return live
    }

    private static func pollUntilInner(_ svc: OrchestraService, _ id: UUID, inject: Bool) async throws {
        try await pollUntil("card \(id) to reconcile to .live (inject: \(inject))") {
            await svc.reconcile()
            let card = await svc.list(includeArchived: true).first { $0.id == id }
            // Deliver the readiness signal only once the stepper's finishLaunch has REGISTERED its waiter
            // (not merely on phase kind): a signal delivered before the waiter exists is dropped by
            // finishLaunch's "start clean" pendingReadiness.remove, and under parallel-suite load the
            // off-actor step can lag the phase write — the race behind the reopen/relaunch flakes.
            if inject, await svc.hasReadinessWaiter(id), let k = card?.phase.kind {
                // Stamp the CURRENT generation like a real SessionStart hook (ORCH_EPOCH) so B3's readiness
                // epoch-fence resolves it as `.signal` (a proven current-gen boot), not the unattributable
                // `.ticks` degrade a nil-epoch signal would take.
                let e = card?.sessionEpoch
                if k == .relaunching { try? await svc.report(id, StatusReport(sessionSource: "resume"), observedEpoch: e) }
                else if k == .launching { try? await svc.report(id, StatusReport(sessionSource: "startup"), observedEpoch: e) }
            }
            return card?.phase.kind == .live
        }
    }

    /// Make a repo dir under reposRoot and return its path.
    static func repo(_ base: String, _ name: String = "app") -> String {
        let p = base + "/repos/" + name
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// **Non-blocking-spawn migration helper (PR4b Task 3).** `spawn` now returns a `.creatingWorktree`
    /// card; the reconciler's steppers (Materialize → Launch) drive it to `.live`. This spawns then drives
    /// `reconcile()` in a poll loop (~2s cap) until the card is `.live`, returning it — a behavior-preserving
    /// drop-in for the pre-flip synchronous `spawn` that most tests used purely as SETUP.
    ///
    /// Readiness-cap contract: the DEFAULT stub adapter is `.relaunchLiveness` (readiness = a successful
    /// `ensure`, immediate — the reconcile ticks alone suffice). For an AWAITING cap
    /// (`.sessionStartHook`/`.rolloutMeta`) the N=3 `launchReadyTicks` fallback (now `inFlightSteps`-
    /// independent, per Task 2 finding 2) resolves the launch waiter within three ticks, so this STILL
    /// converges with no hand-delivered signal. Use `spawnAwaited` when a test must exercise the agent's
    /// OWN readiness signal deterministically (it injects `report(sessionSource:)`).
    @discardableResult
    static func spawnAndAwaitLive(_ svc: OrchestraService, _ input: SpawnInput,
                                 source: ActivitySource = .daemon) async throws -> Task {
        let created = try await svc.spawn(input, source: source)
        do {
            try await pollUntil("spawned card \(created.id) to reach .live") {
                await svc.reconcile()
                return await svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .live
            }
        } catch let e as PollTimeout {
            // Say what phase it got STUCK in — "never reached .live" alone names no bug.
            let card = await svc.list(includeArchived: true).first { $0.id == created.id }
            let phase = card.map { "\($0.phase.kind)\($0.deadReason.map { r in "(\(r))" } ?? "")" } ?? "<no such card>"
            throw PollTimeout(what: "\(e.what) — card was stuck in phase: \(phase)", waited: e.waited, polls: e.polls)
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == created.id }) else {
            throw OrchestraError.unknownTask(created.id.uuidString)
        }
        return live
    }

    /// Spawn through the AWAITING launch path and reach `.live` by hand-delivering the agent's readiness
    /// signal. `spawn` persists the card at `.creatingWorktree`; this drives `reconcile()` (Materialize →
    /// Launch), and each tick the card is `.launching` with a pending waiter it delivers
    /// SessionStart(startup) so an awaiting cap (`.sessionStartHook`/`.rolloutMeta`) confirms on its OWN
    /// signal (not the N=3 fallback). Returns the live card. Use for resume/relaunch-mechanics tests that
    /// need `.claudeCode`/`.codex` but still want a deterministically-live card first.
    @discardableResult
    static func spawnAwaited(_ svc: OrchestraService, _ input: SpawnInput,
                            source: ActivitySource = .daemon) async throws -> Task {
        let created = try await svc.spawn(input, source: source)
        try await pollUntil {
            await svc.reconcile()
            let card = await svc.list(includeArchived: true).first { $0.id == created.id }
            // Deliver on WAITER-REGISTERED, not phase kind (see reconcileToLive): avoids the
            // pendingReadiness-clear race that flakes under parallel-suite contention.
            if await svc.hasReadinessWaiter(created.id) {
                try? await svc.report(created.id, StatusReport(sessionSource: "startup"),
                                      observedEpoch: card?.sessionEpoch)   // epoch-stamped → .signal (B3 fence)
            }
            return card?.phase.kind == .live
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == created.id }) else {
            throw OrchestraError.unknownTask(created.id.uuidString)
        }
        return live
    }

    /// Drive being-born cards to `.live` via the reconciler: repeatedly run `reconcile()` (steps
    /// Materialize → Launch, N=3 liveness fallback) until at least `count` cards are live. Used by Codex
    /// (`.rolloutMeta`) spawn setups whose fixture rollout cannot bind during launch. A fallback card keeps
    /// its durable launch cutoff until discovery binds one unambiguous, post-cutoff rollout for telemetry.
    static func reconcileUntilLive(_ svc: OrchestraService, count: Int) async throws {
        try await pollUntil {
            await svc.reconcile()
            return await svc.list().filter { $0.phase.kind == .live }.count >= count
        }
    }

    /// Wrap a stub worktree manager in a registry with test-local (base-relative) borrows/markers paths.
    /// For the handful of direct `OrchestraService(config:…, worktrees:)` constructions that don't go
    /// through the `make`/`remake` helpers (Codex/Readiness fixtures) — a bare `StubWorktrees` no longer
    /// satisfies the `worktrees:` parameter now that it's typed `WorktreeRegistry?`.
    static func registry(_ stub: StubWorktrees, base: String, config: Config) -> WorktreeRegistry {
        WorktreeRegistry(config: config, manager: stub,
                         borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    }
}
