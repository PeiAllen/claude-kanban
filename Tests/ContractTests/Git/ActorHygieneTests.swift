import XCTest
@testable import OrchestraCore
import OrchestraKit

/// PR5 (Stage 5.1) — the actor-hygiene gate suite. Each `test_actorNotBlockedBy*` proves a specific
/// blocking subprocess/file-IO site was moved off the single `OrchestraService` actor: it starts the
/// slow op, waits for a **deterministic entered-gate signal** (the slow op has demonstrably started —
/// never a race against a fixed sleep), then asserts a concurrent `list()` RPC still returns fast. On
/// unfixed (on-actor) code the concurrent RPC queues behind the slow op and the `< 2.0s` assertion fails
/// — it can never false-pass.
final class ActorHygieneTests: XCTestCase {
    func test_actorNotBlockedByExec() async throws {
        let (service, cardId, cwd) = try await ActorHygieneSupport.liveCardWorktree()
        let marker = "\(cwd)/.exec-entered"
        let slow = _Concurrency.Task { try await service.exec(cardId, "touch '\(marker)'; sleep 5") }
        // Wait until the subprocess has ENTERED (marker exists) — up to 3s, polling.
        try await ActorHygieneSupport.waitForFile(marker, timeout: 3.0)
        let start = Date()
        _ = await service.list()                         // must return while `sleep 5` is still running
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor exec")
        _ = try await slow.value                          // drain
    }

    func test_actorNotBlockedByDiff() async throws {
        let (service, cardId, _) = try await ActorHygieneSupport.liveCardWorktree()
        let gate = ActorHygieneSupport.Gate()
        await service._setDiffProviderForTest(ActorHygieneSupport.BlockingDiffProvider(gate: gate))
        let slow = _Concurrency.Task { _ = await service.recomputeDiffStat(cardId) }
        gate.waitUntilEntered()                              // provider is now parked inside the hop
        let start = Date()
        _ = await service.list()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor diff")
        gate.open(); _ = await slow.value
    }

    func test_actorNotBlockedByPollTelemetry() async throws {
        let gate = ActorHygieneSupport.Gate()
        let (service, _) = try await ActorHygieneSupport.liveCard(adapter: ActorHygieneSupport.BlockingTelemetryAdapter(gate: gate))
        let slow = _Concurrency.Task { await service.pollTelemetry() }
        gate.waitUntilEntered()                              // adapter.sessionInfo is now parked inside the hop
        let start = Date()
        _ = await service.list()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor pollTelemetry")
        gate.open(); await slow.value
    }

    func test_actorNotBlockedByTreeStatRecompute() async throws {
        let gate = ActorHygieneSupport.Gate()
        let (service, cardId) = try await ActorHygieneSupport.liveCardWorktreeWithParent()
        await service._setTreeProbeForTest { gate.markEntered(); gate.blockUntilOpen() }
        let slow = _Concurrency.Task { await service.recomputeTreeStat(cardId) }
        gate.waitUntilEntered()                              // compute is now parked inside the offActor hop
        let start = Date()
        _ = await service.list()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor treeStat recompute")
        gate.open(); await slow.value
    }

    func test_actorNotBlockedByLivenessList() async throws {
        let (service, stub) = try await ActorHygieneSupport.liveCardWithSlowListSessions()
        stub.listSleepMs = 4000
        // `reconcile()`'s `sessions.list()` is ALREADY off-actor (PR4b) — this locks that invariant.
        let slow = _Concurrency.Task { await service.reconcile() }
        stub.enteredGate.waitUntilEntered()               // list() has genuinely started (now sleeping)
        let start = Date()
        _ = await service.list()                         // must return while the stub `list()` is still sleeping
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() RPC blocked behind on-actor reconcile liveness list")
        await slow.value
    }

    func test_reconcileLivenessNotBlockedByList() async throws {
        let (service, stub) = try await ActorHygieneSupport.liveCardWithSlowListSessions()
        stub.listSleepMs = 4000
        // The legacy test-retained `reconcileLiveness()` — still driven by SpawnPhase/Recovery/
        // WakeMergeWatch tests — must hop its `sessions.list()` off-actor too.
        let slow = _Concurrency.Task { await service.reconcileLiveness() }
        stub.enteredGate.waitUntilEntered()               // list() has genuinely started (now sleeping)
        let start = Date()
        _ = await service.list()                         // must return while the stub `list()` is still sleeping
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() RPC blocked behind on-actor reconcileLiveness list")
        await slow.value
    }

    func test_gitRemotesInvalidatesOnConfigChange() async throws {
        let (service, _, repo) = try await ActorHygieneSupport.liveCardWorktree()
        XCTAssertEqual(service.gitRemotes(repo: repo), [])
        try Proc.checked(["git", "-C", repo, "remote", "add", "origin", "https://example.com/x.git"])
        XCTAssertEqual(service.gitRemotes(repo: repo), ["origin"])
    }

    func test_gitRemotesInvalidatesInLinkedWorktree() async throws {
        let (service, _, repo) = try await ActorHygieneSupport.liveCardWorktree()
        let linked = repo + "-linked"
        try Proc.checked(["git", "-C", repo, "worktree", "add", "-q", linked, "-b", "linked-branch"])
        XCTAssertEqual(service.gitRemotes(repo: linked), [])
        // Remotes are configured in the COMMON dir's config — mutate via the main repo path, but the
        // memo is keyed off the LINKED worktree's `.git` file → common-dir resolution (defense-in-depth).
        try Proc.checked(["git", "-C", repo, "remote", "add", "origin", "https://example.com/x.git"])
        XCTAssertEqual(service.gitRemotes(repo: linked), ["origin"])
    }
}

// MARK: - Shared Stage-5.1 test harness (reused by the 5.1.2–5.1.5 gate tests)

/// Helpers for building a real `OrchestraService` + a `.live` card without going through the full
/// spawn/reconcile funnel (these tests exercise a single already-live RPC path, not lifecycle
/// convergence) — mirrors `Tests/OrchestraCoreTests/Stubs.swift`'s `TestEnv.make`, adapted for a
/// separate test target that can't import that target's test doubles.
enum ActorHygieneSupport {

    /// Build a real `OrchestraService` (real `Config`/`PathResolver`/`TaskStore`, a real git repo as the
    /// card's `cwd`, default in-process `AgentRegistry`) and a `.live` worktree card seeded directly into
    /// the store (`Task`'s default `phase` is already `.live(.running)` — no reconciler drive needed).
    /// Returns the service, the card's id, and its (real, git-initialized) cwd.
    static func liveCardWorktree() async throws -> (service: OrchestraService, cardId: UUID, cwd: String) {
        let base = IntegrationSupport.tempDir("actor-hygiene")
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "hi".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "-b", "work"])

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                          proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        let card = Task(title: "actor-hygiene", repo: repo, branch: "work", cwd: repo,
                        model: AgentModel(id: "m1"), startIn: .impl, column: .impl, order: 0,
                        initialPrompt: "")
        _ = try await service.store.create(card)
        return (service, card.id, repo)
    }

    /// Like `liveCardWorktree`, but the card carries a real branch-lineage parent link (`work` → `main`)
    /// so `recomputeTreeStat` actually reaches `computeTreeStat` (a nil-parent card short-circuits
    /// before the offActor hop). Used by the 5.1.4 treeStat gate test.
    static func liveCardWorktreeWithParent() async throws -> (service: OrchestraService, cardId: UUID) {
        let base = IntegrationSupport.tempDir("actor-hygiene-treestat")
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "hi".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])
        let mainTip = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "-b", "work"])

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                          proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        let card = Task(title: "actor-hygiene-treestat", repo: repo, branch: "work", cwd: repo,
                        model: AgentModel(id: "m1"), startIn: .impl, column: .impl, order: 0,
                        initialPrompt: "", parentBranch: "main")
        _ = try await service.store.create(card)
        try await service.lineage.set(repo: repo, branch: "work", link: ParentLink(parent: "main", base: mainTip))
        return (service, card.id)
    }

    /// Build a real `OrchestraService` with a caller-supplied adapter registered for the card's
    /// `agentId`, and a `.live` card seeded directly into the store. No real git repo (unused by the
    /// telemetry-poll gate test); `cwd` is a plain temp dir. Returns the service and the card's id.
    static func liveCard(adapter: any Adapter) async throws -> (service: OrchestraService, cardId: UUID) {
        let base = IntegrationSupport.tempDir("actor-hygiene-adapter")
        let cwd = base + "/cwd"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       registry: AgentRegistry(adapters: [adapter]),
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                          proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        let card = Task(title: "actor-hygiene", repo: cwd, branch: "work", cwd: cwd,
                        origin: .scratch, agentId: adapter.id, model: AgentModel(id: "m1"),
                        startIn: .impl, column: .impl, order: 0, initialPrompt: "")
        _ = try await service.store.create(card)
        return (service, card.id)
    }

    /// Build a real `OrchestraService` wired to a `SlowListSessionStub` (instead of the real tmux-backed
    /// `SessionManager`), and a `.live` card seeded directly into the store. No real git repo needed —
    /// the liveness-list gate tests (5.1.5) never touch git. Returns the service and the injected stub so
    /// the test can arm `listSleepMs` before driving `reconcile()`/`reconcileLiveness()`.
    static func liveCardWithSlowListSessions() async throws -> (service: OrchestraService, sessions: SlowListSessionStub) {
        let base = IntegrationSupport.tempDir("actor-hygiene-list")
        let cwd = base + "/cwd"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let stub = SlowListSessionStub()
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       sessions: stub,
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                          proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        let card = Task(title: "actor-hygiene-list", repo: cwd, branch: "work", cwd: cwd,
                        model: AgentModel(id: "m1"), startIn: .impl, column: .impl, order: 0,
                        initialPrompt: "")
        _ = try await service.store.create(card)
        return (service, stub)
    }

    /// Poll `FileManager.fileExists` on a short loop until `path` appears, or throw once `timeout`
    /// elapses. Used as the "entered" signal for tests whose slow op is a real subprocess (rather than
    /// one wired to a `Gate`, e.g. `exec`'s `touch` marker).
    static func waitForFile(_ path: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            if Date() >= deadline {
                throw OrchestraError.io("timed out waiting for file: \(path)")
            }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)   // 20ms poll
        }
    }

    /// A deterministic "has the blocking stub genuinely entered its blocking section" rendezvous for the
    /// gate tests (5.1.2–5.1.5) that inject a blocking stub (`DiffProvider`/adapter/tree probe) instead of
    /// shelling a real `sleep`. `NSCondition`-backed, `@unchecked Sendable` (all mutable state is guarded
    /// by the condition's own lock).
    ///
    /// - `markEntered()`: the blocking stub calls this the moment it is inside its blocking section.
    /// - `waitUntilEntered()`: the test blocks (synchronously — called from a plain closure, not `async`)
    ///   until `entered` is true.
    /// - `blockUntilOpen(timeout:)`: the blocking stub parks here until `open()` — or `timeout` elapses.
    ///   The timeout is REQUIRED: on unfixed (on-actor) code, the concurrent `list()` RPC in the test is
    ///   queued behind the actor and never reaches the `gate.open()` call, so without a bound the stub
    ///   would park forever and the test would hang to the XCTest timeout instead of failing cleanly via
    ///   the `< 2.0s` assertion.
    /// - `open()`: releases any `blockUntilOpen` waiter.
    final class Gate: @unchecked Sendable {
        private let cond = NSCondition()
        private var _entered = false
        private var _open = false

        var entered: Bool {
            cond.lock(); defer { cond.unlock() }
            return _entered
        }

        func markEntered() {
            cond.lock()
            _entered = true
            cond.signal()
            cond.broadcast()
            cond.unlock()
        }

        func waitUntilEntered() {
            cond.lock()
            while !_entered { cond.wait() }
            cond.unlock()
        }

        func blockUntilOpen(timeout: TimeInterval = 10) {
            cond.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while !_open {
                if !cond.wait(until: deadline) { break }   // deadline reached without a signal — self-release
            }
            cond.unlock()
        }

        func open() {
            cond.lock()
            _open = true
            cond.broadcast()
            cond.unlock()
        }
    }

    /// A `DiffProvider` stub for `test_actorNotBlockedByDiff` (5.1.2): `stat`/`render` mark the gate
    /// entered (proving the call genuinely reached the hop) then park until the test opens it — a
    /// deterministic stand-in for a slow real `git diff`.
    final class BlockingDiffProvider: DiffProvider, @unchecked Sendable {
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }

        func stat(worktree: String, base: DiffBase, parentBranch: String?) throws -> DiffStat? {
            gate.markEntered()
            gate.blockUntilOpen()
            return nil
        }

        func render(worktree: String, base: DiffBase, parentBranch: String?) throws -> String {
            gate.markEntered()
            gate.blockUntilOpen()
            return ""
        }
    }

    /// An `Adapter` stub for `test_actorNotBlockedByPollTelemetry` (5.1.3): `sessionInfo` marks the gate
    /// entered (proving `pollTelemetry`'s per-card rollout resolution genuinely reached the hop) then
    /// parks until the test opens it — a deterministic stand-in for Codex's rollout-file enumeration.
    /// `capabilities == .codex` (`telemetry == .fileTail`) so `pollTelemetry`'s capability gate lets the
    /// card through to the blocking call.
    final class BlockingTelemetryAdapter: Adapter, @unchecked Sendable {
        let id = "codex"
        let name = "Blocking Telemetry Stub"
        let icon = "sparkle"
        let bin = "fake-agent"
        let enabled = true
        let capabilities = AgentCapabilities.codex
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }

        func models() -> [AgentModel] { [AgentModel(id: "m1")] }
        func newSessionId() -> String? { nil }
        func start(_ ctx: AdapterContext) -> [String] { [bin] }
        func resume(_ ctx: AdapterContext) -> [String]? { nil }
        func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
            gate.markEntered()
            gate.blockUntilOpen()
            return nil
        }
    }

    /// A minimal `SessionManaging` stub for the 5.1.5 liveness-list gate tests: `list()` honors an
    /// injectable sleep (mirrors `Tests/OrchestraCoreTests/Stubs.swift`'s `StubSessions.listSleepMs`,
    /// duplicated here because `IntegrationTests` doesn't depend on the `OrchestraCoreTests` target).
    /// Every other member is a lock-guarded no-op/empty-return — `reconcile()`/`reconcileLiveness()` only
    /// call `sessionName` and `list()`.
    final class SlowListSessionStub: SessionManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var alive: Set<String> = []
        /// Set by the test BEFORE driving `reconcile()`/`reconcileLiveness()` to simulate a slow
        /// `tmux list-sessions`.
        var listSleepMs: UInt32 = 0
        /// Signaled the moment `list()` is about to sleep — the deterministic "entered" rendezvous (see
        /// `Gate`'s doc comment). Required here (unlike `reconcile()`'s own gate tests) because
        /// `reconcileLiveness()`'s UNFIXED call is synchronous with no intervening `await` before it: a
        /// plain "spawn the Task then immediately race a concurrent RPC" is a genuine ordering race (the
        /// concurrent RPC can win the actor's queue before the slow call ever starts), which would let the
        /// on-actor bug slip through as a false-pass. Waiting for this gate makes the RPC start only once
        /// the slow call has demonstrably begun, mirroring every other test in this file.
        let enteredGate = Gate()

        func sessionName(_ id: UUID) -> String { "orchestra-\(id.uuidString.lowercased())" }
        func ensure(_ task: Task, argv: [String], env: [String: String]) throws -> (name: String, created: Bool) {
            let name = sessionName(task.id)
            lock.lock(); alive.insert(name); lock.unlock()
            return (name, true)
        }
        func isAlive(_ name: String) throws -> Bool { lock.lock(); defer { lock.unlock() }; return alive.contains(name) }
        func newShellWindow(_ name: String, cwd: String) throws -> String { "shell-1" }
        func windows(_ name: String) throws -> [TmuxTarget] { [] }
        func list() throws -> [SessionInfo] {
            let ms = listSleepMs
            enteredGate.markEntered()
            if ms > 0 { usleep(ms * 1000) }
            lock.lock(); let names = alive; lock.unlock()
            return names.map { SessionInfo(name: $0, running: true) }
        }
        func sendKeys(_ name: String, text: String, window: String) throws {}
        func sendChord(_ name: String, tokens: [KeyToken], window: String) throws {}
        func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult {
            CaptureResult(window: window, text: "", truncated: false)
        }
        func kill(_ name: String) throws { lock.lock(); alive.remove(name); lock.unlock() }
    }
}
