# Test-Suite Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the test suite around three injected seams (clock, paths, process-runner) so no test waits on wall-clock time or shares ambient state, prune dead tests, and reorganize the tree into `UnitTests` / `ContractTests` / `E2ETests` mirroring `Sources/`.

**Architecture:** Stage 1 introduces the seams (`TestClock`, `Config.scratchRoot` instance property, `ProcRunning` + gateable `FakeProc`) and converts every sleep/race-window to deterministic control, deleting the global `scratchTestLock`. Stage 2 splits the 30 hidden-integration suites into FakeProc unit tests + distilled contract tests, then `git mv`s everything into the mirror layout with new SwiftPM targets. Stage 3 updates docs, lints, and reports the accounting.

**Tech Stack:** Swift 6 / swift-testing + XCTest (mixed), SwiftPM test targets, existing `GitHermeticBootstrap` C constructor.

**Spec:** `notes/designs/2026-07-13-test-suite-redesign.md` (approved 2026-07-13).

## Global Constraints

- **Always run tests via `./scripts/test.sh`** — a bare `swift build --build-tests` relinks the bundle with a broken `@rpath/libTesting.dylib`. The script takes the machine-wide build mutex for the compile.
- `swift test` needs `dangerouslyDisableSandbox: true` in this harness (its `sandbox-exec` can't nest). For long runs log via `script -q .scratch/run.log ./scripts/test.sh …` (stdout is block-buffered off-TTY).
- **The suite must be green after every task.** Baseline: 1,157 tests (953 swift-testing + 204 XCTest), all green, 99.8s full run (post-nudge-fix, contended machine).
- **Selection mechanism is `--filter`/`--skip` regex over `<target>.<suite>/<test>`.** Tag-based filtering does not exist on Swift 6.3.3 (swiftlang/swift-testing#591, milestone 6.4.0). `--list-tests` ignores `--filter`; verify selection with a real run.
- **Production behavior must not change.** Every new init parameter defaults to today's behavior (`ContinuousClock()`, `RealProc()`, current path values). Both agent backends (claude-code + codex) keep parity; the slow-repo E2E stays parameterized over both.
- **No new external package dependencies.** `TestClock`, `Gate`, `FakeProc` are hand-rolled in-repo.
- Commit after every task (its final step). Deletions are recorded one line each in the commit message body.
- Plan-tier: **L** (cross-cutting, concurrency-bearing).

## File Structure (end state)

```
Sources/OrchestraCore/ProcRunning.swift        NEW — ProcRunning protocol + RealProc
Sources/OrchestraKit/Config.swift              MODIFIED — scratchRoot becomes an instance property
Sources/OrchestraCore/{OrchestraService,TaskStore,BranchLineage,RemoteParents}.swift
                                               MODIFIED — clock + proc injection
Sources/OrchestraCore/OrchestraService+{MergeRequest,Diff,Tree,Remote,Recovery,ParentRef,Converge}.swift
                                               MODIFIED — clock.sleep / proc.run
Tests/TestSupport/                             NEW target: TestClock.swift, Gate.swift, FakeProc.swift,
                                               GitConfigEmulator.swift, Wait.swift (pollUntil)
Tests/UnitTests/                               NEW target (mirror of Sources/)
  OrchestraCore/  — flat files 1:1 with flat Sources files; Agents/ Control/ Diff/ Keyboard/ mirror dirs;
                    Service/<Flow>Tests.swift for cross-area service flows
  OrchestraKit/   OrchestraUI/
  Support/        — Stubs.swift (TestEnv, stubs), split into StubWorktrees.swift, StubSessions.swift,
                    StubAdapter.swift, TestEnv.swift
Tests/ContractTests/                           NEW target: Git/ Tmux/ Proc/ + Support/ (TestEnv.makeReal)
Tests/E2ETests/                                NEW target: Cli/ Mcp/ Daemon/ SlowRepo/ + Fixtures/
Tests/GitHermeticBootstrap/                    UNCHANGED (all four test-ish targets depend on it)
scripts/test.sh                                MODIFIED — --contract/--e2e/--all flags + lint hook
scripts/lint-tests.sh                          NEW — the re-clumping guards
notes/designs/2026-07-13-test-deletion-decisions.md   NEW — category-4 list for Allen
```

---

# Stage 1 — Seams and semantics

### Task 1: `TestSupport` target + `TestClock`

**Files:**
- Modify: `Package.swift` (add target)
- Create: `Tests/TestSupport/TestClock.swift`
- Create: `Tests/UnitTests/` does not exist yet — TestClock's own tests go in `Tests/OrchestraCoreTests/TestClockTests.swift` for now (they move in Task 11)

**Interfaces:**
- Produces: `TestClock: Clock` with `advance(by: Duration)`, `parked(_ count: Int = 1) async`, `now: TestClock.Instant`. Conforms to stdlib `Clock`, so anything typed `any Clock<Duration>` accepts it and `clock.sleep(for:)` (SE-0374) works.

- [ ] **Step 1: Add the target to `Package.swift`**

In the `targets:` array, after the `GitHermeticBootstrap` target:

```swift
        // Pure test-support code shared by every test target: the fake clock, the gateable
        // fake process runner, and the yield-based wait helper. Depends on OrchestraCore only
        // for ProcResult/ProcRunning. NEVER a dependency of a product target.
        .target(name: "TestSupport",
                dependencies: ["OrchestraCore"],
                path: "Tests/TestSupport"),
```

and add `"TestSupport"` to `OrchestraCoreTests`' dependencies.

- [ ] **Step 2: Write the failing tests** — `Tests/OrchestraCoreTests/TestClockTests.swift`:

```swift
import Testing
import TestSupport

@Suite("TestClock — deterministic time")
struct TestClockTests {
    @Test("advance resumes a parked sleeper; wall-clock does not")
    func advanceResumes() async throws {
        let clock = TestClock()
        let done = Signal()                    // tiny helper below
        let t = _Concurrency.Task {
            try await clock.sleep(for: .seconds(300))
            done.set()
        }
        await clock.parked(1)                  // synchronize on readiness, never on timing
        #expect(!done.isSet)
        clock.advance(by: .seconds(299))
        #expect(!done.isSet)
        clock.advance(by: .seconds(1))
        _ = try await t.value
        #expect(done.isSet)
    }

    @Test("advance past several deadlines resumes all due sleepers in one jump")
    func multiSleeper() async throws {
        let clock = TestClock()
        async let a: Void = clock.sleep(for: .seconds(5))
        async let b: Void = clock.sleep(for: .seconds(10))
        await clock.parked(2)
        clock.advance(by: .seconds(10))
        _ = try await (a, b)                   // both resume; nothing hangs
    }

    @Test("a cancelled sleeper throws CancellationError instead of hanging teardown")
    func cancellation() async {
        let clock = TestClock()
        let t = _Concurrency.Task { try await clock.sleep(for: .seconds(60)) }
        await clock.parked(1)
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
    }

    @Test("sleep with an already-past deadline returns immediately")
    func pastDeadline() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))
        try await clock.sleep(until: TestClock.Instant(offset: .seconds(5)), tolerance: nil)
    }
}

/// Lock-guarded flag for asserting "has not happened yet".
final class Signal: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/test.sh --filter "TestClockTests" 2>&1 | tail -3`
Expected: compile FAILURE — `no such module 'TestSupport'` resolves after Step 1; then `cannot find 'TestClock'`.

- [ ] **Step 4: Implement `Tests/TestSupport/TestClock.swift`**

```swift
import Foundation

/// A manually-advanced Clock for tests. Design notes:
/// - Conforms to stdlib `Clock`, so production seams typed `any Clock<Duration>` accept it and
///   `clock.sleep(for:)` (SE-0374) works unchanged.
/// - `parked(_:)` is the anti-race primitive: a naive fake clock lets the test `advance` BEFORE
///   the code under test reaches its `sleep`, and the sleeper then never wakes. Tests synchronize
///   on "N sleepers are parked", never on timing.
/// - Cancellation resumes the parked sleeper with `CancellationError` — production loops are
///   `while !Task.isCancelled { try? await clock.sleep(…) }`, and a cancelled loop must exit
///   rather than hang suite teardown.
public final class TestClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol, Hashable, Sendable {
        public var offset: Duration
        public init(offset: Duration = .zero) { self.offset = offset }
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (l: Instant, r: Instant) -> Bool { l.offset < r.offset }
    }

    private struct Sleeper { let id: UUID; let deadline: Instant; let continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var _now = Instant()
    private var sleepers: [Sleeper] = []
    private var parkWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}
    public var now: Instant { lock.withLock { _now } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try _Concurrency.Task.checkCancellation()
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if deadline <= _now { return true }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    wakeParkWaitersLocked()
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                defer { sleepers.remove(at: i) }
                return sleepers[i].continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Jump time forward; every sleeper whose deadline has passed resumes (outside the lock).
    public func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            _now = _now.advanced(by: duration)
            let d = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return d
        }
        for s in due { s.continuation.resume() }
    }

    /// Suspend until at least `count` sleepers are parked. The ONLY correct way to order an
    /// `advance` after the code under test has started sleeping.
    public func parked(_ count: Int = 1) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if sleepers.count >= count { return true }
                parkWaiters.append((count, c))
                return false
            }
            if done { c.resume() }
        }
    }

    private func wakeParkWaitersLocked() {
        let n = sleepers.count
        let met = parkWaiters.filter { $0.count <= n }
        parkWaiters.removeAll { $0.count <= n }
        for w in met { w.continuation.resume() }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `./scripts/test.sh --filter "TestClockTests" 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 6: Commit** — `git add Package.swift Tests/TestSupport Tests/OrchestraCoreTests/TestClockTests.swift && git commit -m "test: TestSupport target + TestClock (advance/parked/cancellation)"`

---

### Task 2: `ProcRunning` seam + gateable `FakeProc`

**Files:**
- Create: `Sources/OrchestraCore/ProcRunning.swift`
- Create: `Tests/TestSupport/Gate.swift`, `Tests/TestSupport/FakeProc.swift`
- Test: `Tests/OrchestraCoreTests/FakeProcTests.swift`

**Interfaces:**
- Produces: `public protocol ProcRunning: Sendable { @discardableResult func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) throws -> ProcResult }`; `public struct RealProc: ProcRunning`; `FakeProc` (`on(_:respond:)`, `onDefault(_:)`, `calls`, `gate(on:)`); `Gate` (`reached() async`, `release(_:)`).
- Consumed by: Task 5 (BranchLineage/RemoteParents/service extensions), Task 6 (stub gates), Task 10 (suite conversion).

- [ ] **Step 1: Write the failing tests** — `Tests/OrchestraCoreTests/FakeProcTests.swift`:

```swift
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("FakeProc — scripting, recording, gates")
struct FakeProcTests {
    @Test("scripted rule matches by argv prefix; default answers the rest; calls are recorded")
    func scripting() throws {
        let proc = FakeProc()
        proc.on(["git", "config", "--get"]) { _ in ProcResult(stdout: "main\n", stderr: "", exitCode: 0) }
        proc.onDefault(ProcResult(stdout: "", stderr: "", exitCode: 0))
        let r = try proc.run(["git", "config", "--get", "orchestra.b.parent"], cwd: "/r", env: [:], timeout: nil)
        #expect(r.stdout == "main\n")
        _ = try proc.run(["git", "fetch"], cwd: "/r", env: [:], timeout: nil)
        #expect(proc.calls.map(\.argv.first) == ["git", "git"])
        #expect(proc.calls[1].argv == ["git", "fetch"])
    }

    @Test("a gated call parks until release; the test observes the park deterministically")
    func gates() async throws {
        let proc = FakeProc()
        proc.onDefault(ProcResult(stdout: "", stderr: "", exitCode: 0))
        let gate = proc.gate(on: ["git", "worktree", "add"])
        let t = _Concurrency.Task.detached {          // detached: FakeProc.run blocks its thread, like real Proc.run
            try proc.run(["git", "worktree", "add", "/w", "-b", "b"], cwd: "/r", env: [:], timeout: nil)
        }
        await gate.reached()                          // provably parked inside "git worktree add"
        gate.release(ProcResult(stdout: "", stderr: "", exitCode: 0))
        let r = try await t.value
        #expect(r.ok)
    }

    @Test("release with a failure result makes the parked call return that failure")
    func gateFailure() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "fetch"])
        let t = _Concurrency.Task.detached { try proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil) }
        await gate.reached()
        gate.release(ProcResult(stdout: "", stderr: "fatal: no remote", exitCode: 128))
        let r = try await t.value
        #expect(r.exitCode == 128)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh --filter "FakeProcTests" 2>&1 | tail -3` → compile error, `ProcRunning`/`FakeProc` unknown.

- [ ] **Step 3: Implement `Sources/OrchestraCore/ProcRunning.swift`**

```swift
import Foundation

/// The seam production code forks subprocesses through. `Proc` remains the mechanism; this is
/// the injectable boundary — components that shell out (BranchLineage, RemoteParents, the tree/
/// parent-ref git probes) take a `ProcRunning` so unit tests substitute a scripted, gateable fake.
/// Launch-time forks (Launcher, adapters, SessionManager, daemon lifecycle) stay on `Proc`
/// directly: unit tests never reach them — they are stubbed at their own protocol seams
/// (SessionManaging, the adapter registry), and their real behavior is contract/e2e territory.
public protocol ProcRunning: Sendable {
    @discardableResult
    func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) throws -> ProcResult
}

/// Production implementation — a pass-through to `Proc.run` with its default timeout policy.
public struct RealProc: ProcRunning {
    public init() {}
    @discardableResult
    public func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) throws -> ProcResult {
        try Proc.run(argv, cwd: cwd, env: env, timeout: timeout ?? .seconds(120))
    }
}
```

- [ ] **Step 4: Implement `Tests/TestSupport/Gate.swift`**

```swift
import Foundation
import OrchestraCore

/// A rendezvous for deterministic race tests: the code under test PARKS inside a faked call
/// until the test releases it. Replaces every usleep-to-widen-the-race-window.
///
///     let gate = proc.gate(on: ["git", "worktree", "add"])
///     async let spawn = service.spawn(card)
///     await gate.reached()          // provably parked inside git
///     await service.reconcile()     // fire the racing op, deterministically
///     gate.release(.ok)
///
/// `parkAndAwaitRelease` BLOCKS the calling thread (matching real `Proc.run`'s blocking
/// semantics). Production only forks off-actor (the actor-hygiene invariant), so the parked
/// thread is never a cooperative-pool thread the test itself needs.
public final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hits = 0
    private var result = ProcResult(stdout: "", stderr: "", exitCode: 0)

    /// Suspend until the gated call has parked (at least once).
    public func reached() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if hits > 0 { return true }
                reachedWaiters.append(c)
                return false
            }
            if done { c.resume() }
        }
    }

    /// Let the parked call return `result`.
    public func release(_ result: ProcResult = ProcResult(stdout: "", stderr: "", exitCode: 0)) {
        lock.withLock { self.result = result }
        sem.signal()
    }

    /// Called by FakeProc from the gated invocation's thread.
    func parkAndAwaitRelease() -> ProcResult {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            hits += 1
            defer { reachedWaiters.removeAll() }
            return reachedWaiters
        }
        for w in waiters { w.resume() }
        sem.wait()
        return lock.withLock { result }
    }
}
```

- [ ] **Step 5: Implement `Tests/TestSupport/FakeProc.swift`**

```swift
import Foundation
import OrchestraCore

/// Scripted, recording, gateable ProcRunning. Rules match by argv PREFIX (first rule wins);
/// unmatched calls get `defaultResult` (exit 0, empty output) so incidental probes never fail
/// a test that doesn't care about them. Every call is recorded for intent assertions.
public final class FakeProc: ProcRunning, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public let argv: [String]
        public let cwd: String?
    }
    private struct Rule { let prefix: [String]; let respond: ([String]) -> ProcResult }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var gates: [(prefix: [String], gate: Gate)] = []
    private var defaultResult = ProcResult(stdout: "", stderr: "", exitCode: 0)
    private var _calls: [Call] = []

    public init() {}
    public var calls: [Call] { lock.withLock { _calls } }

    public func on(_ prefix: [String], _ respond: @escaping ([String]) -> ProcResult) {
        lock.withLock { rules.append(Rule(prefix: prefix, respond: respond)) }
    }
    public func onDefault(_ result: ProcResult) { lock.withLock { defaultResult = result } }

    /// Install a one-shot park on the next call whose argv starts with `prefix`.
    /// The gate's release value REPLACES the scripted response for that call.
    public func gate(on prefix: [String]) -> Gate {
        let g = Gate()
        lock.withLock { gates.append((prefix, g)) }
        return g
    }

    @discardableResult
    public func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) throws -> ProcResult {
        let gate: Gate? = lock.withLock {
            _calls.append(Call(argv: argv, cwd: cwd))
            guard let i = gates.firstIndex(where: { argv.starts(with: $0.prefix) }) else { return nil }
            return gates.remove(at: i).gate
        }
        if let gate { return gate.parkAndAwaitRelease() }
        return lock.withLock { rules.first { argv.starts(with: $0.prefix) }?.respond(argv) ?? defaultResult }
    }
}
```

- [ ] **Step 6: Run to verify pass** — `./scripts/test.sh --filter "FakeProcTests" 2>&1 | tail -3` → 3 tests pass.

- [ ] **Step 7: Commit** — `git commit -m "feat: ProcRunning seam (RealProc) + gateable FakeProc for deterministic race tests"`

---

### Task 3: `scratchRoot` becomes injected state; delete `scratchTestLock`

**Files:**
- Modify: `Sources/OrchestraKit/Config.swift` (instance property), `Sources/OrchestraCore/OrchestraService.swift:440,580`, `Sources/OrchestraCore/PhaseStepper.swift:310,315`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (TestEnv wires per-test scratchRoot; delete `AsyncLock`/`scratchTestLock`/`withScratchLock`, lines 428–455)
- Modify: the 12 `withScratchLock` call sites — `ArchiveIntentTests.swift` (3), `TrustLedgerTests.swift`, `TeardownFenceTests.swift`, `StepperConvergeTests.swift`, `SpawnBaseTests.swift`, `ScratchSpawnTests.swift`, `ScratchArchiveTests.swift`, `OrchestraServiceTests.swift` (1 each), `Stubs.swift` (2 internal)
- Modify: `Tests/OrchestraCoreTests/ScratchPathTests.swift`, `ScratchSweepTests.swift`, `ScratchSpawnTests.swift`, `StepperConvergeTests.swift:394`, `HomeIsolationTests.swift:81` (static → instance references)

**Interfaces:**
- Produces: `Config.scratchRoot` (instance, Codable-with-default), `config.scratchDir(_ id: UUID)`. The static `Config.scratchRoot` REMAINS as the production default value used by the instance's fallback; call sites in service/stepper code switch to the instance.

- [ ] **Step 1: Write the failing test** — append to `Tests/OrchestraCoreTests/ScratchPathTests.swift`:

```swift
@Test("scratchRoot is per-Config state: two services sweep only their own roots")
func scratchRootIsInjected() async throws {
    let a = TestEnv.make(), b = TestEnv.make()
    let cardA = try await TestEnv.spawnAndAwaitLive(a.svc, SpawnInput(prompt: "p", scratch: true, agentId: a.adapter.id))
    // b's sweep must not see (or delete) a's scratch dir:
    _ = try await b.svc.sweepOrphanScratch()
    #expect(FileManager.default.fileExists(atPath: cardA.cwd))
    #expect(cardA.cwd.hasPrefix(a.base))          // the scratch dir lives under a's private base
}
```

(Adjust the `SpawnInput` scratch spelling to the existing scratch-spawn test idiom in `ScratchSpawnTests.swift` — copy its input literally.)

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh --filter "ScratchPathTests" 2>&1 | tail -3`
Expected: FAIL — `cardA.cwd` is under the process-global `~/.orchestra/scratch` (the bootstrap HOME), not under `a.base`.

- [ ] **Step 3: Make `scratchRoot` an instance property.** In `Sources/OrchestraKit/Config.swift`:

```swift
    /// Root for ephemeral scratch-card dirs. INSTANCE state (not a process-global): every
    /// OrchestraService sweeps and creates under ITS config's root, so tests give each service a
    /// private root and concurrent daemons/tests can never delete each other's scratch dirs.
    /// Not persisted in config.json unless explicitly set (defaults to the historical location).
    public var scratchRoot: String
    /// The scratch dir for a given card id — `scratchRoot/<lowercased-uuid>`.
    public func scratchDir(_ id: UUID) -> String { "\(scratchRoot)/\(id.uuidString.lowercased())" }

    /// Historical default, kept for the instance default + any remaining display-only uses.
    public static var defaultScratchRoot: String { "\(home)/.orchestra/scratch" }
```

Mechanics: add `scratchRoot` to the memberwise/`init` with default `Config.defaultScratchRoot`; in `init(from:)` decode with `decodeIfPresent … ?? Config.defaultScratchRoot`; add to `CodingKeys` and `encode` (encode unconditionally — harmless). Delete the old `static var scratchRoot` and `static func scratchDir` **after** step 4 fixes their callers (compiler finds every one).

- [ ] **Step 4: Switch the callers to the instance.**
  - `OrchestraService.swift:440`: `cwd = Config.scratchDir(id)` → `cwd = config.scratchDir(id)`
  - `OrchestraService.swift:580`: `public func sweepOrphanScratch(root: String = Config.scratchRoot,` → make the parameter non-defaulted internally: `public func sweepOrphanScratch(root: String? = nil, …)` with first line `let root = root ?? config.scratchRoot`.
  - `PhaseStepper.swift:310,315`: `Config.scratchRoot` → the stepper's config access (`config.scratchRoot` — the stepper already holds/receives the service's config; follow whichever accessor line 310's enclosing scope uses for other config reads).
  - Tests `ScratchPathTests.swift:10-11`, `ScratchSpawnTests.swift:13`, `StepperConvergeTests.swift:394`, `HomeIsolationTests.swift:81`, `ScratchSweepTests` — change `Config.scratchDir(id)`/`Config.scratchRoot` to the env's config instance (in TestEnv-based tests: `a.svc` config paths assert `hasPrefix(a.base + "/scratch")`); `HomeIsolationTests:81` uses `Config.defaultScratchRoot` (it asserts the *default* landing spot is under the bootstrap HOME — that is exactly the static default's job).

- [ ] **Step 5: Wire TestEnv.** In `Stubs.swift` `TestEnv.make` (and `remake`), the `Config(...)` literal gains: `scratchRoot: PathResolver.canonical(base) + "/scratch",` (make) / `scratchRoot: base + "/scratch",` (remake).

- [ ] **Step 6: Delete the mutex.** Remove `AsyncLock`, `scratchTestLock`, `withScratchLock` (Stubs.swift:428–455) and unwrap the 12 call-site bodies (delete the `try await withScratchLock {` / matching `}` — keep the body). Files listed in **Files** above.

- [ ] **Step 7: Full suite green ×3.** Run: `for i in 1 2 3; do script -q .scratch/t3-$i.log ./scripts/test.sh >/dev/null; grep -aE "Test run with" .scratch/t3-$i.log | tail -1; done`
Expected: `… passed` all three times (three runs because this task de-serializes previously-serialized tests — one green run does not prove the races are gone).

- [ ] **Step 8: Commit** — `git commit -m "feat: scratchRoot is injected Config state; delete the global scratchTestLock"`

---

### Task 4: Clock injection through production sleeps

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (init + stored `clock`), and the sleep sites:
  `OrchestraService+MergeRequest.swift:90`, `OrchestraService+Diff.swift:73`, `OrchestraService+Tree.swift:474,489`, `OrchestraService+Remote.swift:208`, `OrchestraService+Recovery.swift:640`
- Modify: `Sources/OrchestraCore/TaskStore.swift:35,186,194` (clock) and its `Date()` stamping (injected `now`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (TestEnv `clock:` parameter)
- Test: `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift` gains one TestClock-driven case; `Tests/OrchestraCoreTests/TaskStoreTests.swift:86` converts to injected `now`

**Interfaces:**
- Produces: `OrchestraService.init(…, clock: any Clock<Duration> = ContinuousClock(), proc: any ProcRunning = RealProc())` — **add both parameters in this task** (proc is threaded to consumers in Task 5). Stored as `nonisolated let clock: any Clock<Duration>` / `nonisolated let proc: any ProcRunning`. `TaskStore.init(path:…, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() })`.
- Consumes: `TestClock` (Task 1), `ProcRunning` (Task 2).

- [ ] **Step 1: Write the failing test** — append to `MergeRequestBackoffTests.swift` (this suite is real-git today; the new case uses `TestEnv.make` + the clock only — it exercises the loop's schedule, not git):

```swift
@Test("nudge backoff follows the schedule under a fake clock — no real waiting")
func backoffScheduleOnTestClock() async throws {
    let clock = TestClock()
    let env = TestEnv.make(clock: clock)
    // Arrange a child in .mergeRequested exactly as the existing loop tests do (copy the
    // arrangement from the suite's first test), then:
    await env.svc.startMergeRequestNudge(childId: child.id)
    await clock.parked(1)                          // loop reached its first sleep (base 300s)
    clock.advance(by: .seconds(300))
    await clock.parked(1)                          // second sleep = 600s — the backoff doubled
    // Assert exactly one re-nudge was sent (whatever the suite's existing sent-count probe is).
}
```

- [ ] **Step 2: Verify failure** — `TestEnv.make` has no `clock:`; `startMergeRequestNudge` sleeps real time.

- [ ] **Step 3: Thread the clock.**
  - `OrchestraService`: add `nonisolated let clock: any Clock<Duration>` + `nonisolated let proc: any ProcRunning`; init params `clock: any Clock<Duration> = ContinuousClock(), proc: any ProcRunning = RealProc()`; assign both.
  - Each sleep site: `try? await _Concurrency.Task.sleep(for: X)` → `try? await clock.sleep(for: X)` (keep the exact `try?`/`try` spelling each site has). Sites: `+MergeRequest:90`, `+Diff:73`, `+Tree:474`, `+Tree:489`, `+Remote:208`, `+Recovery:640`.
  - `TaskStore`: init gains `clock`/`now` (stored `let`); `:35` `ContinuousClock.Instant?` → `(any Clock<Duration>)`-agnostic — store `firstDeferredAt` as the store-clock's instant is generic-hostile with an existential, so instead keep the debounce arithmetic in `Duration` via `clock.now`… **Simplification that avoids existential-Instant algebra:** keep two fields, `private var debounceStart: Date?` stamped from `now()` and use `clock.sleep(for: debounceInterval)` at `:194` unchanged in shape. The only *behavioral* need is that the sleep is fake-advanceable and the ISO stamp is injectable.
  - Every place TaskStore stamps a persisted timestamp with `Date()` uses `now()` instead (grep `Date()` within TaskStore.swift; ~2–4 sites).
- [ ] **Step 4: TestEnv gains the parameter.** `TestEnv.make(…, clock: any Clock<Duration> = ContinuousClock(), proc: (any ProcRunning)? = nil)` → passes through to `OrchestraService(…, clock: clock, proc: proc ?? RealProc())`. (Default stays real for now; suites convert file-by-file in Task 7.)
- [ ] **Step 5: Convert `TaskStoreTests.swift:86`** — replace the `sleep(for: .milliseconds(1100))  // ensure a distinct ISO8601 second` with an injected `now`: construct that test's TaskStore with `var t = Date(); let store = TaskStore(path: p, now: { t })`, and between the two writes do `t += 1` — the "distinct second" is now a variable assignment.
- [ ] **Step 6: Run** — `./scripts/test.sh --filter "MergeRequestBackoff|TaskStoreTests" 2>&1 | tail -3` → pass, and the TaskStore suite loses ~1.1s.
- [ ] **Step 7: Full suite green** — `script -q .scratch/t4.log ./scripts/test.sh >/dev/null; grep -aE "Test run with" .scratch/t4.log`
- [ ] **Step 8: Commit** — `git commit -m "feat: inject the clock through every production sleep + TaskStore timestamps"`

---

### Task 5: `proc` threading — BranchLineage, RemoteParents, tree/parent-ref probes

**Files:**
- Modify: `Sources/OrchestraCore/BranchLineage.swift` (init + 4 `Proc.run` sites: :33,:40,:46,:123)
- Modify: `Sources/OrchestraCore/RemoteParents.swift` (init + its `Proc.run` sites)
- Modify: `Sources/OrchestraCore/OrchestraService.swift:47` (`let lineage = BranchLineage()` → built in init from `proc`), same for `remoteParents`
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift`, `+ParentRef.swift`, `+Converge.swift` — their direct `Proc.run` git probes go through `proc`
- Create: `Tests/TestSupport/GitConfigEmulator.swift`
- Test: `Tests/OrchestraCoreTests/LineageTests.swift` — ONE test converted to FakeProc as the proof (the suite converts wholesale in Task 10)

**Interfaces:**
- Produces: `BranchLineage(proc: any ProcRunning = RealProc())`, `RemoteParents(proc: any ProcRunning = RealProc())`; `GitConfigEmulator` — an in-memory `git config` get/set/unset/get-regexp emulator exposing `func install(on: FakeProc)` so lineage tests script a repo's config space with a dictionary.
- Consumes: `ProcRunning`/`FakeProc` (Task 2).

- [ ] **Step 1: Write the failing test** — in `LineageTests.swift` add:

```swift
@Test("lineage set/get round-trips through the proc seam — no real git")
func lineageOverFakeProc() async throws {
    let fake = FakeProc()
    let emu = GitConfigEmulator()
    emu.install(on: fake)
    let lineage = BranchLineage(proc: fake)
    try await lineage.set(repo: "/nonexistent/repo", branch: "child", parent: "main")
    let rec = await lineage.get(repo: "/nonexistent/repo", branch: "child")
    #expect(rec?.parent == "main")
    #expect(fake.calls.contains { $0.argv.starts(with: ["git", "-C", "/nonexistent/repo", "config"]) })
}
```

(`/nonexistent/repo` is the point: no filesystem, no git — pure seam.)

- [ ] **Step 2: Implement `GitConfigEmulator`** in TestSupport:

```swift
import Foundation
import OrchestraCore

/// In-memory `git config` semantics for FakeProc: --get (exit 1 when missing), set, --unset,
/// --get-regexp (KEY SP VALUE lines, exit 1 when nothing matches). Enough for BranchLineage,
/// whose every op is `git -C <repo> config …`. Fidelity is pinned by
/// ContractTests/Git/GitConfigContractTests (Task 10), which runs the SAME operation matrix
/// against real git and asserts identical exit codes/output shapes.
public final class GitConfigEmulator: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: [String: String]] = [:]   // repo → key → value

    public init() {}
    public func install(on fake: FakeProc) {
        fake.on(["git"]) { [self] argv in
            // Expected shapes: git -C <repo> config [--get|--unset|--get-regexp] key [value]
            guard argv.count >= 4, argv[1] == "-C", argv[3] == "config" else {
                return ProcResult(stdout: "", stderr: "emulator: unhandled: \(argv)", exitCode: 1)
            }
            let repo = argv[2]; let rest = Array(argv.dropFirst(4))
            return lock.withLock { handle(repo: repo, rest: rest) }
        }
    }

    private func handle(repo: String, rest: [String]) -> ProcResult {
        func ok(_ s: String = "") -> ProcResult { ProcResult(stdout: s, stderr: "", exitCode: 0) }
        func miss() -> ProcResult { ProcResult(stdout: "", stderr: "", exitCode: 1) }
        switch rest.first {
        case "--get":
            guard rest.count == 2, let v = store[repo]?[rest[1]] else { return miss() }
            return ok(v + "\n")
        case "--unset":
            guard rest.count == 2, store[repo]?[rest[1]] != nil else { return miss() }
            store[repo]?[rest[1]] = nil
            return ok()
        case "--get-regexp":
            guard rest.count == 2, let re = try? NSRegularExpression(pattern: rest[1]) else { return miss() }
            let hits = (store[repo] ?? [:])
                .filter { re.firstMatch(in: $0.key, range: NSRange($0.key.startIndex..., in: $0.key)) != nil }
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
            return hits.isEmpty ? miss() : ok(hits.joined(separator: "\n") + "\n")
        default:
            guard rest.count == 2 else { return miss() }
            store[repo, default: [:]][rest[0]] = rest[1]
            return ok()
        }
    }
}
```

- [ ] **Step 3: Thread `proc`.**
  - `BranchLineage`: `public init(proc: any ProcRunning = RealProc()) { self.proc = proc }`; each `Proc.run(argv)` → `proc.run(argv, cwd: nil, env: [:], timeout: nil)` (keep `try?`/`try` spellings).
  - `RemoteParents`: same pattern for its sites.
  - `OrchestraService.swift:47`: `let lineage: BranchLineage` and in init `self.lineage = BranchLineage(proc: proc)`; same for `remoteParents = RemoteParents(proc: proc)`.
  - `+Tree.swift` / `+ParentRef.swift` / `+Converge.swift`: their direct `Proc.run`/`Proc.checked` git probes (16 sites total across Remote/Tree per the audit grep) become `proc.run(…)`. These are `nonisolated`/off-actor closures — `proc` is a `nonisolated let`, so capture is legal.
- [ ] **Step 4: Run** — `./scripts/test.sh --filter "LineageTests" 2>&1 | tail -3` → the new test passes AND the suite's existing real-git tests still pass (default `RealProc` preserved behavior).
- [ ] **Step 5: Full suite green** — as Task 4 Step 7.
- [ ] **Step 6: Commit** — `git commit -m "feat: thread ProcRunning through lineage/remote/tree git probes + GitConfigEmulator"`

---

### Task 6: Stub race-knobs become Gates

**Files:**
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` — the deliberate-latency knobs at :49, :192, :202 (`isAliveSleepMs`), :246, :273, :290 (`sleepMs` report-capture window)
- Modify: their consumer tests (grep `ensureSleepMs|isAliveSleepMs|sleepMs` in `Tests/` — the spawn/liveness race suites: `SpawnRaceTests.swift`, `StepperTests.swift` ensure-failure cases, `ReconcilerTests.swift` liveness cases, plus any other hits)

**Interfaces:**
- Produces: `StubSessions.ensureGate: Gate?`, `StubSessions.isAliveGate: Gate?`, `StubAdapter.reportGate: Gate?` (names matching each existing `*SleepMs` knob 1:1). Semantics: when set, the stub method calls `gate.parkAndAwaitRelease()` at exactly the point it used to `usleep`.

- [ ] **Step 1: Convert ONE consumer first as the failing-test step** — take the suite comment-tagged "widen the capture window so a concurrent report can race" (`Stubs.swift:290`'s consumer): rewrite that test to (a) set `stub.reportGate = Gate()`, (b) fire the operation `async let`, (c) `await gate.reached()`, (d) fire the racing report, (e) `gate.release()`, (f) assert the same outcome the test asserted before. Run it: it fails to compile (`reportGate` doesn't exist).
- [ ] **Step 2: Add the gate fields to the stubs** — each `if xSleepMs > 0 { usleep(…) }` becomes `if let g = xGate { _ = g.parkAndAwaitRelease() }`. Delete the `*SleepMs` fields once no consumer references them.
- [ ] **Step 3: Convert the remaining consumers** (the grep list from **Files**), one test at a time, same recipe. Each conversion REMOVES a timing assumption; the assertion should not change.
- [ ] **Step 4: Full suite green ×3** (this task rewires race tests — three runs, as in Task 3).
- [ ] **Step 5: Commit** — `git commit -m "test: race windows are gates, not sleeps — deterministic interleavings"`

---

### Task 7: The test-sleep sweep

**Files:** every remaining sleep site in `Tests/` — inventory at task start with:
`grep -rnE 'Task\.sleep|Thread\.sleep|usleep\(' Tests/ --include='*.swift'`
Known majors: `CodexWakeTests.swift:143` (1300ms), `ControlClientTests.swift:152` (1s), `TransportReconnectTests.swift:139` (500ms), `StepperTests.swift:584` (250ms), `TerminalOwnershipRoundTripTests.swift:97` (300ms), `UDSShutdownTests.swift:45,76`, `UDSSigPipeTests.swift:34`, plus `pollUntil` itself (`MergeWatchTests.swift:120`).

**Interfaces:**
- Produces: `Tests/TestSupport/Wait.swift` — `pollUntil` moved from MergeWatchTests, rewritten yield-based; it is the ONLY file the sleep-lint (Task 12) allowlists.

- [ ] **Step 1: Move + rewrite `pollUntil` into `Tests/TestSupport/Wait.swift`.** Keep its signature and `PollTimeout` shape identical (all of Stubs' helpers call it); replace its inter-poll `Task.sleep` with `await _Concurrency.Task.yield()` and keep a coarse `ContinuousClock` deadline purely as the failure backstop. Re-point the `import`/callers (it was file-internal to the OrchestraCoreTests target; now `import TestSupport`).
- [ ] **Step 2: Classify every remaining sleep site** into the four remedies, then convert file-by-file:
  1. **Waiting for service work driven by a clock** → `TestClock` + `parked`/`advance` (the CodexWake 1300ms wake-delay wait is this).
  2. **Waiting for a condition with no clock involved** → `pollUntil { condition }`.
  3. **Widening a race window** → a `Gate` (should be gone after Task 6; any stragglers).
  4. **Real-transport settling (UDS close/propagate: `UDSShutdownTests`, `UDSSigPipeTests`, `ControlClientTests`, `TransportReconnectTests`)** → these exercise REAL sockets in-process; where a condition-wait can express readiness (poll the socket state / retry the connect) use `pollUntil`; where the OS genuinely provides no observable signal, the sleep stays, the file gets `// SLEEP-EXEMPT: <reason>` and moves to `ContractTests/Proc` in Task 11 (the lint only guards UnitTests).
- [ ] **Step 3: Convert `CodexWakeTests.swift:143` first** (the flagship 1.3s): the test arms the wake path, `await clock.parked(1)`, `clock.advance(by: .milliseconds(1300))`, asserts. If the wake delay is currently a raw `Task.sleep` in production code found during conversion, thread it through `clock` (same recipe as Task 4 — that's in-scope for this task).
- [ ] **Step 4: Sweep the rest of the inventory.** After each file: `./scripts/test.sh --filter "<Suite>" | tail -3` green.
- [ ] **Step 5: Flip `TestEnv.make`'s default `clock` to `TestClock()`?** — NO. Keep the default `ContinuousClock()`: reconcile-driven helpers (`spawnAndAwaitLive` etc.) poll with yields and work under either; flipping the default would make any un-audited time dependency HANG rather than fail. The lint keeps new sleeps out; suites that need time control pass `clock:` explicitly. (Recorded as a deliberate decision — revisit only if a future flake proves a hidden dependency.)
- [ ] **Step 6: Full suite ×3 green, note the wall-clock** — expect the `OrchestraCoreTests` portion to drop well under the 52.4s pre-redesign floor. Record the number for Task 13.
- [ ] **Step 7: Commit** — `git commit -m "test: the sleep sweep — every unit wait is a clock advance, a gate, or a yield-poll"`

---

### Task 8: Prune

**Files:**
- Create: `notes/designs/2026-07-13-test-deletion-decisions.md`
- Delete/modify: per findings

- [ ] **Step 1: Sweep all 148 test files** with the three safe criteria. For each file list every `@Test`/`test…` case and classify:
  - **(1) dead code path** — the production symbol/flow it exercises no longer exists (verify: the symbol is absent from `Sources/`, not merely renamed — check `git log -S`).
  - **(2) provable duplicate** — another named test makes the identical assertion on the identical path (name it).
  - **(3) tests the stub** — every assertion is about `Stub*`/fake behavior with no production code in the loop.
  Delete categories 1–3 directly; each deletion is one line in the commit body: `- <Suite>/<test>: <category> — <one-line reason>`.
- [ ] **Step 2: Build the category-4 decision list** (regression guards whose bug may be unrepresentable now) in `notes/designs/2026-07-13-test-deletion-decisions.md` with the format:

```markdown
## <Suite>/<test> — KEEP-or-DELETE?
- Guards: <the original bug, with the commit/PR that fixed it if findable via git log -S>
- Today: <why the state may be impossible now / what still makes it representable>
- Recommendation: <keep | delete | rewrite-as-gate> — <one sentence>
```

- [ ] **Step 3: Full suite green; record the new total** (must reconcile: 1,157 − deletions = new count).
- [ ] **Step 4: Commit** — deletions + the decision list. **Do not act on category 4 until Allen answers.**

---

# Stage 2 — The moves

### Task 9: New targets + `scripts/test.sh` flags + lint

**Files:**
- Modify: `Package.swift` — rename/create test targets
- Modify: `scripts/test.sh`
- Create: `scripts/lint-tests.sh`

**Interfaces:**
- Produces: targets `UnitTests`, `ContractTests`, `E2ETests` (all depending on GitHermeticBootstrap + TestSupport); `./scripts/test.sh [--contract] [--e2e] [--all]`.

- [ ] **Step 1: Create the target skeletons.** In `Package.swift` replace the three `.testTarget` blocks:

```swift
        .testTarget(name: "UnitTests",
                    dependencies: ["OrchestraCore", "OrchestraKit", "OrchestraUI",
                                   "TestSupport", "GitHermeticBootstrap"],
                    path: "Tests/UnitTests"),
        .testTarget(name: "ContractTests",
                    dependencies: ["OrchestraCore", "OrchestraKit",
                                   "TestSupport", "GitHermeticBootstrap"],
                    path: "Tests/ContractTests"),
        .testTarget(name: "E2ETests",
                    dependencies: ["OrchestraCore", "OrchestraKit",
                                   "TestSupport", "GitHermeticBootstrap"],
                    path: "Tests/E2ETests",
                    resources: [.copy("Fixtures")]),
```

Do this as the FIRST move step by renaming the directories wholesale (`git mv Tests/OrchestraCoreTests Tests/UnitTests` etc. happens in Task 11; for THIS task, create the new dirs with placeholder `Placeholder.swift` files containing one trivial `@Test` each so the targets build) — **alternative that avoids placeholders:** do Task 9 and Task 11 in one commit series; Step 1 here just WRITES the Package.swift change without committing, and Task 11's moves make it build. Choose the placeholder route only if you want the flags testable before the big move; either is acceptable, say which you did.

- [ ] **Step 2: Rewrite `scripts/test.sh` selection.** After the existing BUILD_ARGS filtering block, map tier flags to selectors (tier flags are consumed, never passed to swift):

```bash
# Tier selection (additive): default = unit only; --contract/--e2e add tiers; --all = everything.
TIER_ARGS=(); PASS=()
want_contract=0; want_e2e=0; want_all=0
for a in "$@"; do
  case "$a" in
    --contract) want_contract=1 ;;
    --e2e)      want_e2e=1 ;;
    --all)      want_all=1 ;;
    *)          PASS+=("$a") ;;
  esac
done
if [[ $want_all == 0 ]]; then
  [[ $want_contract == 0 ]] && TIER_ARGS+=(--skip '^ContractTests\.')
  [[ $want_e2e == 0 ]]      && TIER_ARGS+=(--skip '^E2ETests\.')
fi
```

and the exec line becomes `exec swift test --skip-build "${SWIFT_TESTING_FLAGS[@]}" ${TIER_ARGS[@]+"${TIER_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"}`. (`BUILD_ARGS` filtering loops over `PASS`, not `$@`, so tier flags never reach `swift build`.)

- [ ] **Step 3: Write `scripts/lint-tests.sh`:**

```bash
#!/bin/bash
# Guards against the test suite re-clumping. Run standalone or via scripts/test.sh --all.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "lint-tests: $1" >&2; fail=1; }

# 1. No wall-clock waits in the unit tier (Wait.swift's coarse backstop is the one exemption).
if grep -rnE 'Task\.sleep|Thread\.sleep|usleep\(' Tests/UnitTests Tests/TestSupport \
     --include='*.swift' | grep -v 'Tests/TestSupport/Wait.swift' | grep -v 'SLEEP-EXEMPT'; then
  say "wall-clock sleep in the unit tier — use TestClock.advance, a Gate, or pollUntil"
fi
# 2. No ambient path statics in unit tests.
if grep -rnE 'NSHomeDirectory\(\)|Config\.defaultScratchRoot' Tests/UnitTests --include='*.swift'; then
  say "ambient path in a unit test — use the TestEnv per-test base"
fi
# 3. No real forks in the unit tier. (Valid as a FORWARD guard now that the hidden-integration
#    suites are converted; it was NOT valid as an audit tool — see the design doc.)
if grep -rnE '\bProc\.(run|checked|runShell)\(' Tests/UnitTests --include='*.swift'; then
  say "direct Proc call in a unit test — inject FakeProc"
fi
# 4. makeReal is contract-tier-only.
if grep -rn 'makeReal' Tests/UnitTests --include='*.swift'; then
  say "TestEnv.makeReal in the unit tier — that wires real git; move the test to ContractTests"
fi
exit $fail
```

`chmod +x scripts/lint-tests.sh`; add to `scripts/test.sh` immediately before the build when `want_all == 1`: `scripts/lint-tests.sh`.

- [ ] **Step 4: Verify flags** with real runs (after Task 11 lands the moves): default run excludes both tiers; `--all` includes everything; totals reconcile.
- [ ] **Step 5: Commit** (or fold into Task 11's first commit if you chose the no-placeholder route).

---

### Task 10: Split the 30 hidden-integration suites

**Files:** the 30 suites (below), `Tests/ContractTests/Git/*`, plus `TestEnv.makeReal` relocation.

**The 30 (audited; destinations):**

| suites | area | unit rewrite over | contract distillate |
|---|---|---|---|
| LineageTests, LineageSpawnTests, TreeStatTests, TreeCommandTests, TreeErrorWordingTests, LadderTests, SetParentMoveTests, StaleNudgeTests, RebuildMergeRequestNudgesTests | branch-tree | FakeProc + GitConfigEmulator | GitConfigContractTests (the emulator-fidelity matrix) + one TreeStat-over-real-repo case |
| MergeRequestTests, MergeRequestBackoffTests, ShipChoreoTests, BorrowLifecycleTests, RedirectMechanicsTests | merge-collab | FakeProc + emulator + scripted `git merge-base`/`rev-parse` rules | ShipChoreography real-repo happy path (1 test) |
| RemoteParentTests, RemoteParentRefTests, RemoteRecomputeTests, RemoteSpawnTests, RemoteWatchLoopTests, SetParentRemoteTests | remote-git | FakeProc scripted `fetch`/`ls-remote` | RemoteFetchContractTests (fetch/ls-remote against a local `--bare` origin) |
| SpawnBaseTests, SpawnBaseValidationTests, NonBlockingSpawnTests, StepperConvergeTests, ServiceTeardownTests | card-lifecycle | FakeProc (worktree/branch rules) | WorktreeAddContractTests (real `git worktree add/remove` matrix — subsumes today's WorktreeRegistryIntegrationTests) |
| DiffProviderTests, DiffServiceTests | diff-review | already behind `DiffProvider` — stub it; FakeProc for baseline probes | GitDiffContractTests (real `git diff --numstat` shape) |
| NotesServiceTests, ControlRoundTripTests | notes / control | FakeProc / in-process UDS (no git) | — (ControlRoundTrip's UDS is in-process; it moves to UnitTests if it forks nothing, else ContractTests/Proc) |
| GitHermeticityTests | infra | — (it IS a contract suite) | moves to ContractTests/Git verbatim |
| ProcShellTests, GhProbeTests | proc | — | ContractTests/Proc verbatim |

**Recipe per suite** (worked example = LineageTests, from Task 5's proof-test):
1. Read the suite; list which helpers it reaches git through (`TestEnv.makeReal`, `TreeStatTests.git/repoWithParent/advanceParent`, `RemoteParentTests.git/makeOriginWithPR`, `ShipChoreoTests.repoWithChild`, own `Proc.run`).
2. Re-express the repo arrangement as emulator state + FakeProc rules. The cross-file repo helpers get FakeProc-equivalents in `Tests/UnitTests/Support/RepoScripts.swift` (e.g. `RepoScripts.withParent(fake:emu:)` scripts the same config keys + rev-parse answers the git helper used to create for real).
3. Convert the suite's tests; assertions unchanged. Anything asserting on REAL git effects (a branch actually exists, a merge actually fast-forwards) is the contract distillate: move THAT assertion into the area's contract suite (right column), one test per real behavior, not per original test.
4. Green: suite filter run. Then delete the old real-git helper if orphaned.

- [ ] **Step 1: Do branch-tree** (worked example area). Includes writing `ContractTests/Git/GitConfigContractTests.swift`: run the emulator's operation matrix (`set/get/unset/get-regexp` × present/missing) against BOTH `GitConfigEmulator+FakeProc` and real git in a temp repo; assert identical `(exitCode, stdout-shape)` — this is what licenses every emulator-backed unit test.
- [ ] **Step 2: merge-collab.** — [ ] **Step 3: remote-git.** — [ ] **Step 4: card-lifecycle.** — [ ] **Step 5: diff-review + notes/control.** — [ ] **Step 6: move the verbatim three** (GitHermeticity, ProcShell, GhProbe).
- [ ] **Step 7: Relocate `TestEnv.makeReal`** to `Tests/ContractTests/Support/RealEnv.swift` (the unit tier loses access — the lint's rule 4 and the type system now agree).
- [ ] **Step 8: Full suite ×3 green; commit per area** (6 commits: `test(branch-tree): unit-convert lineage/tree suites over FakeProc + git-config contract`, etc.)

---

### Task 11: The mirror move

**Files:** everything under `Tests/`; `Package.swift` (Task 9's block goes live here if not already).

**Mapping (complete; source-of-truth for the moves):**

- `Tests/OrchestraCoreTests/Stubs.swift` → split into `Tests/UnitTests/Support/{TestEnv,StubWorktrees,StubSessions,StubAdapter}.swift` (mechanical split at the type boundaries; TestEnv keeps everything service-wiring).
- OrchestraKit-owned tests → `Tests/UnitTests/OrchestraKit/`: ConfigDataDirTests, ConfigTimeoutTests, ConnectionMacTests, ConnectionSocketResolverTests, ConnectionStoreTests, ModelCodableTests, ModelTableTests, TaskRefTests, TaskMigrationTests, KeyNameTests, KeybindingsTests, PushCoreTests, NotificationPrefsTests, ClientIdentityTests (verify each `import`s OrchestraKit primarily; any that are Core-owned stay in Core's dir).
- Mirror dirs: DiffModelTests, DiffTextParserTests (+ the unit-converted DiffProvider/DiffService) → `Tests/UnitTests/OrchestraCore/Diff/`; AdapterEncodeTests, AdapterTests, CodexAdapterTests, CodexRolloutTests, CodexWakeTests, CapabilitiesTests, ReadOnlyAdapterTests, ModelReseatTests(adapter-half), ParseTests, HandleHookTests, HookChannelTests → `Tests/UnitTests/OrchestraCore/Agents/`; ControlClientTests, ControlLineBufferTests, ControlServerTests, DaemonLifecycleTests, TransportReconnectTests, UDSShutdownTests, UDSSigPipeTests, ShellSyncRoundTripTests → `Tests/UnitTests/OrchestraCore/Control/` (minus any SLEEP-EXEMPT movers to ContractTests/Proc per Task 7).
- Service flows → `Tests/UnitTests/OrchestraCore/Service/`: OrchestraServiceTests, ReconcilerTests, RecoveryTests, StepperTests, StepperConvergeTests, SpawnPhaseTests, SpawnRaceTests, SpawnSeedTrustTests, SpawnBaseTests, SpawnBaseValidationTests, NonBlockingSpawnTests, StartupAbortTests, ReadinessSignalTests, PhaseTransitionTests, ArchiveIntentTests, ArchiveOriginTests, TeardownFenceTests, ServiceTeardownTests, ReopenTests, HandoffResumeTests, ModelReseatTests, IdempotencyTests, MoveNotifyTests, ResourceExhaustionTests, ScratchSpawnTests, ScratchArchiveTests, ScratchPathTests, ScratchSweepTests, BorrowedSpawnTests, BorrowLifecycleTests, MergeRequestTests, MergeRequestBackoffTests, ShipChoreoTests, RedirectMechanicsTests, WakeMergeWatchTests, MergeWatchTests, SendWakeTests, LineageTests, LineageSpawnTests, LineageModelTests, TreeStatTests, TreeCommandTests, TreeErrorWordingTests, TreeDocsTests, LadderTests, SetParentMoveTests, SetParentRemoteTests, StaleNudgeTests, RebuildMergeRequestNudgesTests, RemoteParentTests, RemoteParentRefTests, RemoteRecomputeTests, RemoteSpawnTests, RemoteWatchLoopTests, RemoteCommandsTests — *within* Service/ use one file per flow as today; a second-level split (Service/Tree/, Service/Remote/…) is allowed if a dir exceeds ~25 files, mirroring the `OrchestraService+<Area>.swift` extension names.
- Flat 1:1s stay flat in `Tests/UnitTests/OrchestraCore/`: TaskStoreTests, PathResolverTests, WorktreeTests, WorktreeRegistryTests, TmuxAttachTests, RepoScannerTests, InboxTests, TrustGrantTests, TrustLedgerTests, DeviceTokenStoreTests, PushNotifierTests, AuthRateMonitorTests, AuthWarnSpawnTests, CommandsTests, CommandRegistryCatalogTests, VerbContractTests, DelegationDocsTests, SessionBriefTests, ListDirTests, BoardNavigatorTests, BoardSnapshotTests, BoardTreeTests, SendKeysArgvTests, SendKeysCommandTests, TerminalKeyBytesTests, TerminalOwnership*Tests, ShellPanelStateTests, ReportTests, NotesServiceTests, HomeIsolationTests, GhProbeTests→(moved T10), SettingsComposerTests, ControlRoundTripTests(per T10 outcome).
- `Tests/OrchestraUITests/*` → `Tests/UnitTests/OrchestraUI/` (all 16 audited unit).
- `Tests/IntegrationTests/`: SessionManagerTests → `ContractTests/Tmux/`; ActorHygieneTests, WorktreeRegistryIntegrationTests, LauncherDiffTests → `ContractTests/Git/`; E2EBinaryTests → `E2ETests/Daemon/`; ReportHelperPipeTests → `E2ETests/Cli/`; SlowRepoE2ETests → `E2ETests/SlowRepo/`; `Fixtures/` → `Tests/E2ETests/Fixtures/`; IntegrationSupport.swift → split between `ContractTests/Support/` and `E2ETests/Support/`.

- [ ] **Step 1: Execute the moves** as pure `git mv` per the table (no content edits in this commit beyond `import TestSupport` additions and the Stubs split).
- [ ] **Step 2: Build + full suite `--all` green.** Compare test COUNT to pre-move (identical — moves change nothing).
- [ ] **Step 3: Verify selection**: `./scripts/test.sh` (unit only — record count+time), `--contract`, `--e2e`, `--all` — counts sum to the total.
- [ ] **Step 4: Run `scripts/lint-tests.sh`** — clean.
- [ ] **Step 5: Commit** — `git commit -m "test: the mirror move — Tests/ now parallels Sources/ (UnitTests/ContractTests/E2ETests)"`

---

### Task 12: E2E fat-cutting

**Files:** `Tests/E2ETests/SlowRepo/SlowRepoE2ETests.swift`, `Tests/E2ETests/Daemon/E2EBinaryTests.swift`, `Tests/E2ETests/Fixtures/gen-slow-repo.sh`, `Tests/ContractTests/Tmux/SessionManagerTests.swift`

- [ ] **Step 1: One slow repo, generated once.** Give `SlowRepoFixture` a suite-scoped async-lazy singleton (a `static let task = Task { generate(…) }`; each test `await`s it) so both agent parameterizations share ONE 12k-file generation. Fold `SlowRepoFixtureTests`' sanity assertions into an assertion on the shared fixture (delete the separate 2k generation — reason recorded per prune policy).
- [ ] **Step 2: Hoist `E2EBinaryTests` per-test `init()` setup** into the same suite-scoped-fixture pattern (build/locate binaries once), and convert its `Thread.sleep(1.5)` at :219 + 200ms `usleep`s to `pollUntil` on the observable condition (the server's response file/socket readiness).
- [ ] **Step 3: One tmux server for `SessionManagerTests`** — a suite-scoped socket (`orch-test-<uuid>` once per suite, `kill-server` in a suite-teardown), not per-test; tests already target distinct session names.
- [ ] **Step 4: Measure**: `./scripts/test.sh --e2e --contract 2>&1 | tail -3` before/after numbers for Task 13.
- [ ] **Step 5: Commit.**

---

# Stage 3 — Docs, guardrails, accounting

### Task 13: Docs + final report

**Files:**
- Modify: `CLAUDE.md` (the "Keep the test suite tiered" section), `docs/08-building-operations.md`
- Create: final numbers in the PR description / merge-request body

- [ ] **Step 1: Rewrite the CLAUDE.md tiering section** to the new contract: *default `./scripts/test.sh` = unit tier per task; `--all` once at the merge gate; `--contract`/`--e2e` when touching git/tmux command generation or binaries; new tests go in the mirror position; `scripts/lint-tests.sh` is the law on sleeps/ambient paths/forks.* Update `docs/08-building-operations.md` equivalently (it regenerates from docs tooling on main — edit the source the update-docs hook consumes, check `scripts/update-docs.sh` for which).
- [ ] **Step 2: Plan-guidance sweep** — the "run full `swift test` after every task" mandate lives in `notes/plans/*` templates/history (~126 references): do NOT rewrite history; add the new contract prominently to CLAUDE.md (done in Step 1) which supersedes; grep `notes/plans/` for any LIVING template and update only those.
- [ ] **Step 3: Final measurement on an idle machine**: 3× each of default / `--contract` / `--e2e` / `--all`, medians, stated as post-nudge-fix. Full accounting: start 1,157 → deletions (per-category counts) → merges → additions → end count per tier.
- [ ] **Step 4: Update the design doc's baseline table** with the final numbers; commit.
- [ ] **Step 5: Verify** via `superpowers:verification-before-completion`, then request the diff review pair (Claude + Codex per the house rule), then `merge-request`.

---

## Self-review notes (already applied)

- Task 4 adds BOTH `clock` and `proc` params to `OrchestraService.init` so the init signature changes once, not twice.
- Task 9/11 interlock (targets need files; files need targets) is called out with two sanctioned sequencings.
- The lint's `Proc.` grep is valid FORWARD-only (post-Task-10); the design doc's "grep lints are wrong" claim refers to auditing the OLD tree — noted in the lint comments.
- `ControlClientTests`' 1s sleep may be irreducible (real socket retry backoff) — Task 7's remedy 4 covers it without pretending.
- Category-4 deletions are GATED on Allen; nothing in Stage 2 depends on his answer.
