import Foundation
import XCTest
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// PR5 (Stage 5.1) — the actor-hygiene gate suite. Each `test_actorNotBlockedBy*` proves a specific
/// blocking subprocess/file-IO site was moved off the single `OrchestraService` actor: it starts the
/// slow op, waits for a **deterministic entered-gate signal** (the slow op has demonstrably started —
/// never a race against a fixed sleep), then asserts a concurrent `list()` RPC returns *before the test
/// releases that operation*. This is an ordering assertion, not a latency budget: under a loaded parallel
/// suite, a correct continuation may be scheduled much later than two seconds. On unfixed on-actor code,
/// the `list()` call cannot reach its completion latch because the test deliberately withholds the release.
final class ActorHygieneTests: XCTestCase {
    func test_actorNotBlockedByExec() async throws {
        let (service, cardId, cwd) = try await ActorHygieneSupport.liveCardWorktree()
        let marker = "\(cwd)/.exec-entered"
        let release = "\(cwd)/.exec-release"
        let slow = _Concurrency.Task {
            try await service.exec(cardId, "touch '\(marker)'; while [ ! -e '\(release)' ]; do sleep 1; done")
        }
        try await pollUntil("the exec subprocess starts") {
            FileManager.default.fileExists(atPath: marker)
        }
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the exec subprocess",
            release: { try Data().write(to: URL(fileURLWithPath: release)) },
            waitForSlow: { _ = try await slow.value }
        )
    }

    func test_actorNotBlockedByDiff() async throws {
        let (service, cardId, _) = try await ActorHygieneSupport.liveCardWorktree()
        let gate = SyncGate()
        await service._setDiffProviderForTest(ActorHygieneSupport.BlockingDiffProvider(gate: gate))
        let slow = _Concurrency.Task { _ = await service.recomputeDiffStat(cardId) }
        await gate.reached()                                  // provider is now parked inside the hop
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the diff provider",
            release: { gate.release() },
            waitForSlow: { await slow.value }
        )
    }

    func test_actorNotBlockedByPollTelemetry() async throws {
        let gate = SyncGate()
        let (service, _) = try await ActorHygieneSupport.liveCard(adapter: ActorHygieneSupport.BlockingTelemetryAdapter(gate: gate))
        let slow = _Concurrency.Task { await service.pollTelemetry() }
        await gate.reached()                                  // adapter.sessionInfo is now parked inside the hop
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the telemetry adapter",
            release: { gate.release() },
            waitForSlow: { await slow.value }
        )
    }

    func test_actorNotBlockedByTreeStatRecompute() async throws {
        let gate = SyncGate()
        let (service, cardId) = try await ActorHygieneSupport.liveCardWorktreeWithParent()
        await service._setTreeProbeForTest { gate.parkBlocking(timeout: .seconds(120)) }
        let slow = _Concurrency.Task { await service.recomputeTreeStat(cardId) }
        await gate.reached()                                  // compute is now parked inside the offActor hop
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the tree-stat probe",
            release: { gate.release() },
            waitForSlow: { await slow.value }
        )
    }

    func test_actorNotBlockedByLivenessList() async throws {
        let (service, stub) = try await ActorHygieneSupport.liveCardWithSlowListSessions()
        stub.blockList = true
        // `reconcile()`'s `sessions.list()` is ALREADY off-actor (PR4b) — this locks that invariant.
        let slow = _Concurrency.Task { await service.reconcile() }
        await stub.listGate.reached()                     // list() has genuinely started and is held
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the reconcile liveness snapshot",
            release: { stub.listGate.release() },
            waitForSlow: { await slow.value }
        )
    }

    func test_reconcileLivenessNotBlockedByList() async throws {
        let (service, stub) = try await ActorHygieneSupport.liveCardWithSlowListSessions()
        stub.blockList = true
        // The legacy test-retained `reconcileLiveness()` — still driven by SpawnPhase/Recovery/
        // WakeMergeWatch tests — must hop its `sessions.list()` off-actor too.
        let slow = _Concurrency.Task { await service.reconcileLiveness() }
        await stub.listGate.reached()                     // list() has genuinely started and is held
        try await ActorHygieneSupport.assertListReturnsBeforeRelease(
            service,
            whileBlockedBy: "the reconcileLiveness snapshot",
            release: { stub.listGate.release() },
            waitForSlow: { await slow.value }
        )
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
    /// the test can arm its deterministic list gate before driving `reconcile()`/`reconcileLiveness()`.
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

    /// Signal that an async `list()` call really returned. The lock makes this safe to read from
    /// `pollUntil`'s cooperative task without turning the test's ordering assertion into another race.
    private final class CompletionLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false

        func signal() { lock.withLock { signaled = true } }
        var isSignaled: Bool { lock.withLock { signaled } }
    }

    /// Proves the actor can serve `list()` while `what` remains deliberately blocked. The timeout is only
    /// a diagnostic backstop for a genuinely wedged implementation, never a claim about how quickly a
    /// loaded machine schedules a correct continuation. On either path we release and drain the slow task
    /// so a failed assertion cannot strand a blocking test double or subprocess in the test process.
    static func assertListReturnsBeforeRelease(
        _ service: OrchestraService,
        whileBlockedBy what: String,
        release: () throws -> Void,
        waitForSlow: () async throws -> Void
    ) async throws {
        let listReturned = CompletionLatch()
        let fast = _Concurrency.Task {
            _ = await service.list()
            listReturned.signal()
        }
        var released = false
        func releaseSlow() throws {
            guard !released else { return }
            try release()
            released = true
        }

        do {
            try await pollUntil("list() returns while \(what) remains blocked", timeout: .seconds(60)) {
                listReturned.isSignaled
            }
            try releaseSlow()
            _ = await fast.value
            try await waitForSlow()
        } catch {
            if !released { try? releaseSlow() }
            if released {
                _ = await fast.value
                try? await waitForSlow()
            }
            throw error
        }
    }

    /// A `DiffProvider` stub for `test_actorNotBlockedByDiff` (5.1.2): `stat`/`render` mark the gate
    /// entered (proving the call genuinely reached the hop) then park until the test opens it — a
    /// deterministic stand-in for a slow real `git diff`.
    final class BlockingDiffProvider: DiffProvider, @unchecked Sendable {
        private let gate: SyncGate
        init(gate: SyncGate) { self.gate = gate }

        func stat(worktree: String, base: DiffBase, parentBranch: String?) throws -> DiffStat? {
            gate.parkBlocking(timeout: .seconds(120))
            return nil
        }

        func render(worktree: String, base: DiffBase, parentBranch: String?) throws -> String {
            gate.parkBlocking(timeout: .seconds(120))
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
        private let gate: SyncGate
        init(gate: SyncGate) { self.gate = gate }

        func models() -> [AgentModel] { [AgentModel(id: "m1")] }
        func newSessionId() -> String? { nil }
        func start(_ ctx: AdapterContext) -> [String] { [bin] }
        func resume(_ ctx: AdapterContext) -> [String]? { nil }
        func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
            gate.parkBlocking(timeout: .seconds(120))
            return nil
        }
    }

    /// A minimal `SessionManaging` stub for the 5.1.5 liveness-list gate tests. Its `list()` call can be
    /// held at a `SyncGate`, which proves ordering without guessing how long a slow `tmux list-sessions`
    /// should take. This remains local because `ContractTests` doesn't depend on `OrchestraCoreTests`.
    /// Every other member is a lock-guarded no-op/empty-return — `reconcile()`/`reconcileLiveness()` only
    /// call `sessionName` and `list()`.
    final class SlowListSessionStub: SessionManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var alive: Set<String> = []
        private var shouldBlockList = false
        /// Set by the test BEFORE driving `reconcile()`/`reconcileLiveness()` to hold the real liveness
        /// snapshot at a deterministic point.
        var blockList: Bool {
            get { lock.withLock { shouldBlockList } }
            set { lock.withLock { shouldBlockList = newValue } }
        }
        /// Signaled only once `list()` is held — the deterministic "entered" rendezvous. Required here
        /// because
        /// `reconcileLiveness()`'s UNFIXED call is synchronous with no intervening `await` before it: a
        /// plain "spawn the Task then immediately race a concurrent RPC" is a genuine ordering race (the
        /// concurrent RPC can win the actor's queue before the slow call ever starts), which would let the
        /// on-actor bug slip through as a false-pass. Waiting for this gate makes the RPC start only once
        /// the slow call has demonstrably begun, mirroring every other test in this file.
        let listGate = SyncGate()

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
            if blockList { listGate.parkBlocking(timeout: .seconds(120)) }
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
