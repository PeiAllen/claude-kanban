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
                            allowlist: [PathResolver.canonical(base)])
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"))
        let card = Task(title: "actor-hygiene", repo: repo, branch: "work", cwd: repo,
                        model: AgentModel(id: "m1"), startIn: .impl, column: .impl, order: 0,
                        initialPrompt: "")
        _ = try await service.store.create(card)
        return (service, card.id, repo)
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
                            allowlist: [PathResolver.canonical(base)])
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       registry: AgentRegistry(adapters: [adapter]),
                                       trust: TrustLedger(path: base + "/trust-ledger.json"),
                                       inbox: Inbox(path: base + "/inbox.json"),
                                       watchStore: WatchRegistryStore(path: base + "/watch-registry.json"))
        let card = Task(title: "actor-hygiene", repo: cwd, branch: "work", cwd: cwd,
                        origin: .scratch, agentId: adapter.id, model: AgentModel(id: "m1"),
                        startIn: .impl, column: .impl, order: 0, initialPrompt: "")
        _ = try await service.store.create(card)
        return (service, card.id)
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
}
