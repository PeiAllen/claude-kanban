# Test-Suite Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the test suite around three injected seams (clock, paths, async process-runner) so no test waits on wall-clock time or shares ambient state, prune dead tests, and reorganize the tree into `UnitTests` / `ContractTests` / `E2ETests` mirroring `Sources/`.

**Architecture:** Stage 1 introduces the seams (`TestClock`, injected `scratchRoot`/`runtimeStateDir`, an **async** `ProcRunning` + suspension-gated `FakeProc`) and converts every sleep/race-window to deterministic control, deleting the global `scratchTestLock`. Stage 2 splits the 30 hidden-integration suites into FakeProc unit tests + fidelity-pinned contract tests, then flips targets + `git mv`s everything into the mirror layout in one interlocked commit. Stage 3 updates docs, lints, and reports the accounting.

**Tech Stack:** Swift 6 / swift-testing + XCTest (mixed), SwiftPM test targets, existing `GitHermeticBootstrap` C constructor.

**Spec:** `notes/designs/2026-07-13-test-suite-redesign.md` (approved 2026-07-13; amended per plan-review — see §"Spec amendments" at bottom).
**Plan review:** one bounded Claude (Opus 4.8) + Codex (GPT-5.6 Terra) pass, 2026-07-14. All findings verified against the code; every confirmed finding is folded in below. Rebutted (with evidence): Codex's "async-let initializer missing `try` doesn't compile" — `swiftc -typecheck` accepts the SE-0317 form (try marks the read).

## Global Constraints

- **Always run tests via `./scripts/test.sh`** — a bare `swift build --build-tests` relinks the bundle with a broken `@rpath/libTesting.dylib`. The script takes the machine-wide build mutex for the compile.
- `swift test` needs `dangerouslyDisableSandbox: true` in this harness. Log long runs via `script -q .scratch/run.log ./scripts/test.sh …` (stdout block-buffers off-TTY).
- **Green after every task.** Baseline: 1,157 tests (953 swift-testing + 204 XCTest), all green, 99.8s (post-nudge-fix, contended machine).
- **Selection = `--filter`/`--skip` regex over `<target>.<suite>/<test>`** (no tag filtering on Swift 6.3.3; `--list-tests` ignores `--filter` — verify with real runs).
- **Production behavior must not change.** Every new init parameter defaults to today's behavior. `RealProc` preserves `Proc.run`'s exact thread-blocking semantics AND its `timeout: nil == unbounded` contract. Both agent backends keep e2e parity.
- **No new external package dependencies.**
- Commit after every task; deletions get one line each in the commit body.
- Plan-tier: **L**.

## File Structure (end state)

```
Sources/OrchestraCore/ProcRunning.swift        NEW — async ProcRunning + RealProc; ProcResult gains public init
Sources/OrchestraKit/Config.swift              MODIFIED — scratchRoot + runtimeStateDir instance props (NON-Codable)
Sources/OrchestraKit/Control/ControlClient.swift  MODIFIED — clock injection (ping/probe/call timers)
Sources/OrchestraUI/BoardStore.swift           MODIFIED — clock injection (3 sleep sites)
Sources/OrchestraCore/{OrchestraService,TaskStore,BranchLineage,RemoteParents,PhaseStepper}.swift
                                               MODIFIED — clock/proc/scratchRoot threading
Sources/OrchestraCore/OrchestraService+{MergeRequest,Diff,Tree,Remote,Recovery,ParentRef,Converge}.swift
                                               MODIFIED — clock.sleep / await proc.run
Tests/TestSupport/                             NEW target: TestClock, Gate, FakeProc, GitConfigEmulator, Wait
Tests/UnitTests/                               NEW target (mirror of Sources/) + Support/ (TestEnv & stubs, split)
Tests/ContractTests/                           NEW target: Git/ Tmux/ Proc/ + Support/ + Fixtures/ (resources)
Tests/E2ETests/                                NEW target: Cli/ Mcp/ Daemon/ SlowRepo/ + Support/ + Fixtures/
scripts/test.sh                                MODIFIED — tier flags parsed FIRST, then BUILD_ARGS from the remainder
scripts/lint-tests.sh                          NEW — re-clumping guards (no exemption markers in the unit tier)
notes/designs/2026-07-13-test-deletion-decisions.md   NEW — category-4 list for Allen
```

---

# Stage 1 — Seams and semantics

### Task 1: `TestSupport` target + `TestClock`

**Files:**
- Modify: `Package.swift` (add target; add `"TestSupport"` to `OrchestraCoreTests` deps)
- Create: `Tests/TestSupport/TestClock.swift`
- Test: `Tests/OrchestraCoreTests/TestClockTests.swift` (moves in Task 11)

**Interfaces:**
- Produces: `TestClock: Clock` with `advance(by:)`, `parked(_ count: Int = 1, deadlineAtLeast: Duration? = nil) async`, `now`. Stdlib `Clock` conformance → anything typed `any Clock<Duration>` accepts it; `clock.sleep(for:)` is SE-0374.

- [ ] **Step 1: Add the target** (after `GitHermeticBootstrap`):

```swift
        // Pure test-support code shared by every test target: the fake clock, the gateable
        // fake process runner, and the yield-based wait helper. Depends on OrchestraCore only
        // for ProcResult/ProcRunning. NEVER a dependency of a product target.
        .target(name: "TestSupport",
                dependencies: ["OrchestraCore"],
                path: "Tests/TestSupport"),
```

- [ ] **Step 2: Write the failing tests** — `Tests/OrchestraCoreTests/TestClockTests.swift`:

```swift
import Foundation
import Testing
import TestSupport

@Suite("TestClock — deterministic time")
struct TestClockTests {
    @Test("advance resumes a parked sleeper; wall-clock does not")
    func advanceResumes() async throws {
        let clock = TestClock()
        let done = Signal()
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
        async let a: Void = clock.sleep(for: .seconds(5))     // SE-0317: `try` marks the read below
        async let b: Void = clock.sleep(for: .seconds(10))
        await clock.parked(2)
        clock.advance(by: .seconds(10))
        _ = try await (a, b)
    }

    @Test("parked(deadlineAtLeast:) ignores unrelated short sleepers")
    func scopedParked() async throws {
        let clock = TestClock()
        let short = _Concurrency.Task { try await clock.sleep(for: .milliseconds(750)) }   // a debounce, say
        await clock.parked(1)
        let long = _Concurrency.Task { try await clock.sleep(for: .seconds(300)) }         // the loop under test
        await clock.parked(1, deadlineAtLeast: .seconds(300))   // does NOT return early on the 750ms sleeper
        clock.advance(by: .seconds(300))
        _ = try? await short.value
        _ = try await long.value
    }

    @Test("a cancelled sleeper throws CancellationError instead of hanging teardown")
    func cancellation() async {
        let clock = TestClock()
        let t = _Concurrency.Task { try await clock.sleep(for: .seconds(60)) }
        await clock.parked(1)
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
    }

    @Test("cancel racing registration cannot strand the sleeper")
    func cancelRegistrationRace() async {
        // Regression guard for the lost-cancel window: cancel fired between checkCancellation
        // and the sleeper append must still resume-throwing (the `cancelled` id-set path).
        for _ in 0..<100 {
            let clock = TestClock()
            let t = _Concurrency.Task { try await clock.sleep(for: .seconds(60)) }
            t.cancel()                                        // no parked() — race the registration
            await #expect(throws: CancellationError.self) { try await t.value }
        }
    }
}

final class Signal: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
```

- [ ] **Step 3: Verify failure** — `./scripts/test.sh --filter "TestClockTests" 2>&1 | tail -3` → `cannot find 'TestClock'`.

- [ ] **Step 4: Implement `Tests/TestSupport/TestClock.swift`**

```swift
import Foundation

/// A manually-advanced Clock for tests.
/// - Stdlib `Clock` conformance: seams typed `any Clock<Duration>` accept it unchanged.
/// - `parked(_:deadlineAtLeast:)` is the anti-race primitive: tests synchronize on "the code
///   under test is parked", never on timing. `deadlineAtLeast` scopes the wait to the sleeper
///   you mean — one service shares one clock across its nudge/debounce/watch loops, so a bare
///   count can be satisfied by an unrelated short sleeper.
/// - Cancellation: a `cancelled` id-set closes the lost-cancel window (onCancel firing between
///   checkCancellation and the sleeper append must still resume-throwing).
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
    private var cancelled: Set<UUID> = []
    private var parkWaiters: [(count: Int, minDeadline: Instant?, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}
    public var now: Instant { lock.withLock { _now } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                enum Verdict { case resume, cancel, park }
                let verdict: Verdict = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }      // onCancel already fired
                    if deadline <= _now { return .resume }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    wakeParkWaitersLocked()
                    return .park
                }
                switch verdict {
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)                                   // not appended yet — mark for the append path
                    return nil
                }
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

    /// Suspend until at least `count` sleepers are parked — optionally only counting sleepers
    /// whose remaining duration is >= `deadlineAtLeast` (scope the wait to the loop you mean).
    public func parked(_ count: Int = 1, deadlineAtLeast: Duration? = nil) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let minDeadline = deadlineAtLeast.map { Instant(offset: lock.withLock { _now }.offset + $0) }
            let done: Bool = lock.withLock {
                if matchingSleepersLocked(minDeadline: minDeadline) >= count { return true }
                parkWaiters.append((count, minDeadline, c))
                return false
            }
            if done { c.resume() }
        }
    }

    private func matchingSleepersLocked(minDeadline: Instant?) -> Int {
        guard let m = minDeadline else { return sleepers.count }
        return sleepers.count { $0.deadline >= m }
    }
    private func wakeParkWaitersLocked() {
        let met = parkWaiters.enumerated().filter { matchingSleepersLocked(minDeadline: $0.element.minDeadline) >= $0.element.count }
        for (i, w) in met.reversed() { parkWaiters.remove(at: i); w.continuation.resume() }
    }
}
```

(Note `parked(deadlineAtLeast:)` computes the threshold against `_now` at wait time; advance() does not re-lower it — fine for its purpose: ordering an advance after a specific park.)

- [ ] **Step 5: Verify pass** — 6 tests green (the 100-iteration cancel-race case included).
- [ ] **Step 6: Commit** — `git commit -m "test: TestSupport target + TestClock (advance/scoped-parked/cancel-race-safe)"`

---

### Task 2: async `ProcRunning` seam + suspension-gated `FakeProc`

**Files:**
- Create: `Sources/OrchestraCore/ProcRunning.swift`
- Modify: `Sources/OrchestraCore/Proc.swift:4-9` — add `public init(stdout: String, stderr: String, exitCode: Int32)` to `ProcResult` (memberwise init is internal today; TestSupport imports non-`@testable`).
- Create: `Tests/TestSupport/Gate.swift`, `Tests/TestSupport/FakeProc.swift`
- Test: `Tests/OrchestraCoreTests/FakeProcTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ProcRunning: Sendable { @discardableResult func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult }`
    **Async on purpose:** `BranchLineage` and `RemoteParents` are ACTORS calling the seam from isolated methods. A blocking gate there would wedge the actor's cooperative-pool thread and deadlock the test's next `await` on that actor. An async seam lets `FakeProc` SUSPEND at a gate (deadlock-free from actors and `async let` alike) while `RealProc` runs blocking `Proc.run` inline — byte-for-byte today's thread semantics.
    **Timeout contract:** `nil` means truly unbounded, exactly like `Proc.run` (Proc.swift:18-22). Converted call sites that previously used the implicit default pass `.seconds(120)` explicitly.
  - `public struct RealProc: ProcRunning` — `try Proc.run(argv, cwd: cwd, env: env, timeout: timeout)` verbatim (nil passes through).
  - `FakeProc` (`on(_:_:)` rules returning `ProcResult?` — nil falls through to later rules/default; `onDefault`; `calls`; `gate(on:)`), `Gate` (`reached() async`, `release(_:)`, `park() async -> ProcResult` — all `public`).
- Consumed by: Task 5 (lineage/remote/tree), Task 6 (stub gates), Task 10.

- [ ] **Step 1: Write the failing tests** — `Tests/OrchestraCoreTests/FakeProcTests.swift`:

```swift
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("FakeProc — scripting, fall-through, recording, gates")
struct FakeProcTests {
    @Test("first matching rule wins; nil falls through; default answers the rest")
    func scripting() async throws {
        let proc = FakeProc()
        proc.on(["git"]) { argv in                       // a broad rule that only handles config
            argv.count > 3 && argv[3] == "config" ? ProcResult(stdout: "main\n", stderr: "", exitCode: 0) : nil
        }
        proc.on(["git", "fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        let r = try await proc.run(["git", "-C", "/r", "config", "--get", "k"], cwd: nil, env: [:], timeout: nil)
        #expect(r.stdout == "main\n")
        let f = try await proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil)   // fell through the broad rule
        #expect(f.ok)
        #expect(proc.calls.count == 2)
    }

    @Test("a gated call suspends until release — no thread is blocked")
    func gates() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "worktree", "add"])
        async let r = proc.run(["git", "worktree", "add", "/w", "-b", "b"], cwd: "/r", env: [:], timeout: nil)
        await gate.reached()                              // provably parked inside "git worktree add"
        gate.release(ProcResult(stdout: "", stderr: "", exitCode: 0))
        #expect(try await r.ok)
    }

    @Test("release with a failure makes the parked call return that failure")
    func gateFailure() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "fetch"])
        async let r = proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil)
        await gate.reached()
        gate.release(ProcResult(stdout: "", stderr: "fatal: no remote", exitCode: 128))
        #expect(try await r.exitCode == 128)
    }
}
```

- [ ] **Step 2: Verify failure**, then implement. `Gate.swift`:

```swift
import Foundation
import OrchestraCore

/// A rendezvous for deterministic race tests: the code under test SUSPENDS inside a faked call
/// until the test releases it. Replaces every usleep-to-widen-the-race-window.
/// Suspension (not semaphore-blocking) is load-bearing: gated calls happen inside actor-isolated
/// methods (BranchLineage/RemoteParents), where parking the thread would deadlock the actor.
public final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released: ProcResult? = nil
    private var parkedWaiters: [CheckedContinuation<ProcResult, Never>] = []

    public init() {}

    /// Test-side: suspend until the gated call has parked (at least once).
    public func reached() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if hits > 0 { return true }
                reachedWaiters.append(c); return false
            }
            if done { c.resume() }
        }
    }

    /// Test-side: let the parked call return `result`. Also satisfies a call that arrives late.
    public func release(_ result: ProcResult = ProcResult(stdout: "", stderr: "", exitCode: 0)) {
        let waiters: [CheckedContinuation<ProcResult, Never>] = lock.withLock {
            released = result
            defer { parkedWaiters.removeAll() }
            return parkedWaiters
        }
        for w in waiters { w.resume(returning: result) }
    }

    /// FakeProc-side: record the hit, wake `reached()` waiters, suspend until released.
    public func park() async -> ProcResult {
        let reached: [CheckedContinuation<Void, Never>] = lock.withLock {
            hits += 1
            defer { reachedWaiters.removeAll() }
            return reachedWaiters
        }
        for r in reached { r.resume() }
        return await withCheckedContinuation { (c: CheckedContinuation<ProcResult, Never>) in
            let early: ProcResult? = lock.withLock {
                if let r = released { return r }
                parkedWaiters.append(c); return nil
            }
            if let early { c.resume(returning: early) }
        }
    }
}
```

`FakeProc.swift`:

```swift
import Foundation
import OrchestraCore

/// Scripted, recording, gateable ProcRunning. Rules match by argv PREFIX in registration order;
/// a rule may return nil to FALL THROUGH (so the GitConfigEmulator's broad ["git"] rule composes
/// with later fetch/rev-parse rules). Unmatched calls get `defaultResult` (exit 0, empty output).
/// Respond closures run OUTSIDE the internal lock (a closure may re-enter the fake).
public final class FakeProc: ProcRunning, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public let argv: [String]
        public let cwd: String?
    }
    private struct Rule { let prefix: [String]; let respond: ([String]) -> ProcResult? }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var gates: [(prefix: [String], gate: Gate)] = []
    private var defaultResult = ProcResult(stdout: "", stderr: "", exitCode: 0)
    private var _calls: [Call] = []

    public init() {}
    public var calls: [Call] { lock.withLock { _calls } }

    public func on(_ prefix: [String], _ respond: @escaping ([String]) -> ProcResult?) {
        lock.withLock { rules.append(Rule(prefix: prefix, respond: respond)) }
    }
    public func onDefault(_ result: ProcResult) { lock.withLock { defaultResult = result } }

    /// One-shot park on the next call whose argv starts with `prefix`; the gate's release value
    /// REPLACES any scripted response for that call.
    public func gate(on prefix: [String]) -> Gate {
        let g = Gate()
        lock.withLock { gates.append((prefix, g)) }
        return g
    }

    @discardableResult
    public func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
        let (gate, candidateRules, fallback): (Gate?, [Rule], ProcResult) = lock.withLock {
            _calls.append(Call(argv: argv, cwd: cwd))
            var g: Gate? = nil
            if let i = gates.firstIndex(where: { argv.starts(with: $0.prefix) }) { g = gates.remove(at: i).gate }
            return (g, rules.filter { argv.starts(with: $0.prefix) }, defaultResult)
        }
        if let gate { return await gate.park() }
        for rule in candidateRules {                       // outside the lock — re-entrant-safe
            if let r = rule.respond(argv) { return r }
        }
        return fallback
    }
}
```

- [ ] **Step 3: Add `public init` to `ProcResult`** (Proc.swift, inside the struct):

```swift
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
```

- [ ] **Step 4: Verify pass** — 3 tests green. **Step 5: Full suite green.** **Step 6: Commit.**

---

### Task 3: scratch + runtime-state paths become injected state; delete `scratchTestLock`

**Files:**
- Modify: `Sources/OrchestraKit/Config.swift` — instance `scratchRoot` + `runtimeStateDir`, **both OUTSIDE `CodingKeys`**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:440,580,857` + `setConfig` (preserve non-wire fields)
- Modify: `Sources/OrchestraCore/PhaseStepper.swift:310,315` + `ConvergeContext` (new `scratchRoot: String` field) + its construction site (`OrchestraService.swift:~1197`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (TestEnv wires both; delete `AsyncLock`/`scratchTestLock`/`withScratchLock` :428-455)
- Modify: **every test-side `Config(` construction** — enumerate with `grep -rn 'Config(reposRoot' Tests/` — known extra site: `ArchiveIntentTests.swift:26` builds its own Config (its local `env()` helper); wire `scratchRoot`/`runtimeStateDir` there too
- Modify: the 12 `withScratchLock` call sites (ArchiveIntentTests ×3, Stubs ×2, TrustLedgerTests, TeardownFenceTests, StepperConvergeTests, SpawnBaseTests, ScratchSpawnTests, ScratchArchiveTests, OrchestraServiceTests)
- Modify: static→instance references in `ScratchPathTests`, `ScratchSweepTests`, `ScratchSpawnTests:13`, `StepperConvergeTests:394`, `HomeIsolationTests:81` (uses `Config.defaultScratchRoot` — that suite is about ambient defaults and moves to ContractTests in Task 11)

**Interfaces:**
- Produces: `config.scratchRoot`, `config.scratchDir(_ id: UUID)`, `config.runtimeStateDir` (instance); `Config.defaultScratchRoot` (static, the default value).
- **Wire-safety (review BLOCKER):** `ControlServer` `setConfig` decodes a whole `Config` off the control plane (`ControlServer.swift:130-133`) and `PhaseStepper` uses `scratchRoot` as the fence immediately before `rm -rf`. So: (a) neither new property appears in `CodingKeys` — decode always recomputes the default from the CURRENT `$HOME` (no stale persisted absolute path under HOME-redirect, no wire-settable fence); (b) `OrchestraService.setConfig` explicitly carries the running instance's values across the swap:

```swift
    public func setConfig(_ mutate: (inout Config) -> Void) {
        var next = config
        mutate(&next)
        // Non-wire runtime paths are NOT settable via config replacement (the rm -rf fence must
        // never move at runtime): preserve the running instance's values unconditionally.
        next.scratchRoot = config.scratchRoot
        next.runtimeStateDir = config.runtimeStateDir
        config = next
        …existing persistence/emit…
    }
```

  (Adapt to the actual `setConfig` body — the invariant is the two carried-across lines.)

- [ ] **Step 1: Failing test** — as previously specified (`ScratchPathTests`: two `TestEnv.make()` services; spawn a scratch card in A; `b.svc.sweepOrphanScratch()`; A's dir survives and lives under `a.base`). PLUS a wire-safety test in `ControlServerTests` or `OrchestraServiceTests`:

```swift
@Test("setConfig cannot move the scratch fence")
func setConfigPreservesScratchRoot() async throws {
    let env = TestEnv.make()
    let before = await env.svc.getConfig().scratchRoot
    await env.svc.setConfig { $0.reposRoot = $0.reposRoot }     // any wire-shaped replacement
    #expect(await env.svc.getConfig().scratchRoot == before)
}
```

- [ ] **Step 2: Verify both fail.**
- [ ] **Step 3: Implement Config** (instance props, non-Codable — `init(from:)` sets defaults, `encode` omits them; memberwise init gains `scratchRoot: String = Config.defaultScratchRoot, runtimeStateDir: String = Config.dataDir`).
- [ ] **Step 4: Switch callers.** `:440` → `config.scratchDir(id)`; `:580` → `root: String? = nil` + `let root = root ?? config.scratchRoot`; `:857` (`readonly-<shortId>.json` under `Config.dataDir`) → `config.runtimeStateDir`; `ConvergeContext` gains `public let scratchRoot: String`, PhaseStepper :310/:315 use it, construction at :~1197 passes `config.scratchRoot`.
- [ ] **Step 5: Wire TestEnv + ArchiveIntentTests + any other `Config(` sites from the grep** (`scratchRoot: base + "/scratch"`, `runtimeStateDir: base + "/state"`).
- [ ] **Step 6: Delete the mutex + unwrap the 12 call sites.**
- [ ] **Step 7: Full suite green ×3** (de-serialization needs repetition to trust).
- [ ] **Step 8: Commit.**

---

### Task 4: Clock injection through production sleeps

**Files:**
- Modify: `OrchestraService.swift` (init: `clock: any Clock<Duration> = ContinuousClock()`, `proc: any ProcRunning = RealProc()` — both params land HERE so the init changes once; stored as `nonisolated let`)
- Modify sleep sites: `+MergeRequest:90`, `+Diff:73`, `+Tree:474,489`, `+Remote:208`, `+Recovery:640` → `try? await clock.sleep(for: …)` (preserve each site's exact `try` spelling)
- Modify: `Sources/OrchestraCore/TaskStore.swift` — see the two-timeline note
- Modify: `Stubs.swift` TestEnv (`clock:` param, forwarded to BOTH the service and the TaskStore it builds)
- Test: `MergeRequestBackoffTests` TestClock case; `TaskStoreTests:86` conversion

**TaskStore two-timeline note (review MAJOR):** today the debounce sleep AND the max-deferral checkpoint both live on monotonic `ContinuousClock` (`TaskStore.swift:35,186-190,194`). Do NOT move the checkpoint to `Date` (wall-clock jumps would flush early/late) and do NOT leave it on `ContinuousClock` while the sleep moves (TestClock advance would never trip the cap). Restructure the debounce internals onto ONE injected clock with no instant arithmetic across existentials: on first deferral arm TWO competing sleepers — the extendable debounce sleep and a hard-cap task (`try? await clock.sleep(for: maxDeferral)` then flush) — whichever fires first flushes and cancels the other. Production default `ContinuousClock` keeps monotonic semantics; tests advance one TestClock and can exercise BOTH paths deterministically. The injected `now: @Sendable () -> Date = { Date() }` is used ONLY for persisted ISO-8601 stamps (never for scheduling).

- [ ] **Step 1: Failing test** — `MergeRequestBackoffTests`:

```swift
@Test("nudge backoff follows the schedule under a fake clock — no real waiting")
func backoffScheduleOnTestClock() async throws {
    let clock = TestClock()
    let env = TestEnv.make(clock: clock)
    // Arrange a child in .mergeRequested exactly as the suite's existing first test does, then:
    await env.svc.startMergeRequestNudge(childId: child.id)
    await clock.parked(1, deadlineAtLeast: .seconds(300))   // scoped: ignore unrelated debounce sleepers
    clock.advance(by: .seconds(300))
    await clock.parked(1, deadlineAtLeast: .seconds(600))   // backoff doubled — proves the schedule
    // assert exactly one re-nudge sent (the suite's existing sent-count probe)
}
```

- [ ] **Step 2–3: Thread it** (service init as above; sleep sites; TaskStore restructure per the note; TestEnv builds `TaskStore(path: …, clock: clock, now: …)` and forwards `clock`/`proc` to the service — review minor-11: without this forwarding, no TestEnv test can advance the store).
- [ ] **Step 4: Convert `TaskStoreTests:86`** to injected `now` (`var t = Date()` closure; `t += 1` replaces the 1.1s sleep) and add a debounce-cap test on TestClock (advance past `maxDeferral`, expect the flush — deterministic coverage the wall-clock version never had).
- [ ] **Step 5–6: Suite green; commit.**

---

### Task 5: `proc` threading — BranchLineage, RemoteParents, tree/parent-ref probes

**Files:** as before (`BranchLineage.swift` :33,:40,:46,:123; `RemoteParents.swift`; `OrchestraService.swift:47` + init; `+Tree/+ParentRef/+Converge` probe sites), plus `Tests/TestSupport/GitConfigEmulator.swift`; proof-test in `LineageTests`.

**Interfaces:**
- Produces: `BranchLineage(proc: any ProcRunning)`, `RemoteParents(proc: any ProcRunning)` — **NO default value** (confirm/deny fix: a `= RealProc()` default lets a unit test write `BranchLineage()` and run real git invisibly to every lint). This is the one sanctioned exception to the "new params default to today's behavior" constraint: the only production construction sites are inside `OrchestraService.init`, which passes its own `proc`, so production behavior is unchanged while the tier becomes structurally honest. Add a step: `grep -rn 'BranchLineage()\|RemoteParents()' Sources/ Tests/` and fix every construction (known test-side directs: `LineageTests.swift:32`, `MergeRequestBackoffTests.swift:76`). Call sites become `try await proc.run(argv, cwd: nil, env: [:], timeout: .seconds(120))` (the previous implicit default made explicit — review minor-13). Since the seam is async and these are actors, adding `await` inside isolated methods is legal and does not change callers (they already `await` the actor).
- `GitConfigEmulator.install(on:)` registers a `["git"]` rule that handles ONLY `git -C <repo> config …` shapes and returns **nil for everything else** (fall-through — review MAJOR-7), so fetch/rev-parse/merge-base rules registered before OR after compose. Emulator semantics per the prior draft (get/set/unset/get-regexp; exit 1 on missing), now returning `ProcResult?`.
- **Off-actor sync probes:** `+Tree`/`+ParentRef`/`+Converge` sites that run inside sync `offActor`/`offActorValue` closures get an async-closure overload of that helper (a `Task.detached`-based twin, ~6 lines, same name) rather than blocking bridges. Note it in the conversion commit.

- [ ] Steps as previously specified (failing LineageTests seam test over `/nonexistent/repo`; implement; thread; suite green ×1; commit). The Task-5 proof test asserts fall-through composition too: register a `["git", "rev-parse"]` rule after `install(on:)` and verify both answer.

---

### Task 6: Stub race-knobs become Gates

**AMENDED (implementation finding):** the premise "the stub protocol methods are async" was FALSE —
every knob-bearing method (`WorktreeManaging.ensure`/`remove`, `SessionManaging.ensure`/`isAlive`/
`capture`) is sync `throws` (Protocols.swift:14-16, 46-67), so a suspension `Gate.park()` cannot run
there. Asyncifying the protocols is rejected: ~35 cross-cutting call sites, and it would insert an
await into `WorktreeRegistry.ensure`'s DOCUMENTED no-await critical section (WorktreeRegistry.swift:
249-251 — the serialization that makes concurrent same-branch ensures fire `git worktree add` once).

**Sanctioned mechanism for sync seams: a bounded BLOCKING rendezvous (`SyncGate` in TestSupport).**
Stub-side `parkBlocking(timeout: 30s)` on a semaphore — the same thread-blocking semantics as the
`usleep` it replaces at the same call site (wherever usleep was safe, the gate is safe: these run
off-actor on GCD, or the blocking IS the invariant under test); test-side `reached() async` /
`release()` stay suspension-based. Precedent already in-tree: `StubWorktrees.blockEnsure`'s bounded
semaphore. Suspension `Gate` remains the mechanism for ASYNC seams (ProcRunning). The safety
timeout means a mis-armed test fails loudly instead of hanging the suite.

- Consumed knobs → SyncGate: `StubSessions.ensureSleepMs` (RecoveryTests), `isAliveSleepMs`
  (ReconcilerTests), `captureSleepMs` (StartupAbortTests), `StubWorktrees.ensureSleepMs`
  (WorktreeRegistryTests — the contention test becomes: gate first ensure, fire second, assert it
  has NOT entered via the stub's recorded state only — never await the blocked registry actor —
  release, assert both completed with one add).
- Dead knobs (`windowsSleepMs`, `listSleepMs`) deleted outright (already done).
- `blockEnsure`/`releaseEnsure` fold into the same SyncGate pattern if trivially compatible, else stay.
- Full suite ×3 green; commit.

---

### Task 7: The test-sleep sweep + Kit/UI clock seams

**Files:** inventory via `grep -rnE 'Task\.sleep|Thread\.sleep|usleep\(' Tests/ --include='*.swift'`, plus:
- Modify: `Sources/OrchestraKit/Control/ControlClient.swift` — `clock: any Clock<Duration> = ContinuousClock()` init param; sleep sites :155 (ping), :195 (probe), :241 (call timeout) → `clock.sleep` (its `callTimeout`/`pingInterval`/`probeTimeout` are already injectable `Duration`s, so this is mechanical)
- Modify: `Sources/OrchestraUI/BoardStore.swift` — same treatment for :274 (grace), :497 (retry backoff), :1163 (4.2s banner) 
- Create: `Tests/TestSupport/Wait.swift` (pollUntil moved from `MergeWatchTests.swift:120`, yield-based; coarse ContinuousClock deadline only as the failure backstop; the ONLY lint-allowlisted file)

**No `SLEEP-EXEMPT` marker exists** (review minor-12: an open-ended escape hatch voids the tier guarantee). The four remedies are: TestClock advance · pollUntil · Gate · **move the suite to ContractTests/Proc** (for real-fd/socket settling that has no observable condition — candidates: `UDSShutdownTests`, `UDSSigPipeTests`; decide per-file here, record the decision, Task 11's map follows it).

- [ ] Steps as before (pollUntil first; classify; `CodexWakeTests:143` flagship; sweep; ControlClient/BoardStore seams + their suites converted). TestEnv's default `clock` stays `ContinuousClock()` until Task 10 (transition safety), and its default `proc` flips in Task 10. Full suite ×3; note the wall-clock; commit.

---

### Task 8: Prune

As previously specified (three safe categories deleted directly with one-line reasons in the commit body; category-4 regression-guard judgment calls to `notes/designs/2026-07-13-test-deletion-decisions.md` in the stated format; **gated on Allen**; count reconciliation). One addition per review (d): a test whose ONLY real-git assertion is re-expressed over the emulator does NOT count as category 1-3 — its real-git assertion must appear in the Task-10 assertion map (below) or the test is not deletable.

---

# Stage 2 — The moves

### Task 9+11 (interlocked): targets, flags, lint, and the mirror move — ONE commit for the flip

Review made the interlock explicit (both reviewers): replacing the three test targets strands every legacy file (placeholder route), and new-path targets before the moves reference nothing (deferred route). So the sanctioned sequencing is:

1. **Task 10 runs FIRST** (suite conversions happen in place, under the OLD target names).
2. Then ONE commit contains: the `Package.swift` target flip + ALL `git mv`s + `import TestSupport` fixes + the `Stubs.swift` split. Nothing is unowned at any commit boundary.
3. `scripts/test.sh` + `scripts/lint-tests.sh` land in the SAME commit (the flags are meaningless before the flip and the default invocation is wrong after it without them).
4. Immediately verify: `--all` runs and the count equals the pre-flip count exactly; default / `--contract` / `--e2e` counts sum to it.

**`scripts/test.sh` (corrected order — tier flags parsed FIRST, then BUILD_ARGS from the remainder; review MAJOR):**

```bash
# --- tier selection (parse FIRST so tier flags never reach swift build) -------------------
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
else
  scripts/lint-tests.sh    # the merge-gate run enforces the guards
fi
# --- build-arg filtering: EXACTLY the existing loop, but over PASS not "$@" ---------------
BUILD_ARGS=()
skip_next=0
for a in ${PASS[@]+"${PASS[@]}"}; do
  … existing case statement unchanged …
done
scripts/lib/with-lock.sh build -- \
  swift build --build-tests "${SWIFT_TESTING_FLAGS[@]}" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
exec swift test --skip-build "${SWIFT_TESTING_FLAGS[@]}" ${TIER_ARGS[@]+"${TIER_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"}
```

**`scripts/lint-tests.sh` (revised per MAJOR-8/-9, minor-12):**

```bash
#!/bin/bash
# Guards against the test suite re-clumping. Runs on --all and standalone.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "lint-tests: $1" >&2; fail=1; }

# 1. No wall-clock waits in the unit tier. NO exemption marker — a test that truly needs to
#    settle real fds/sockets belongs in ContractTests. Wait.swift's coarse backstop is the
#    single allowlisted file.
if grep -rnE 'Task\.sleep|Thread\.sleep|usleep\(' Tests/UnitTests Tests/TestSupport \
     --include='*.swift' | grep -v 'Tests/TestSupport/Wait.swift'; then
  say "wall-clock sleep in the unit tier — TestClock.advance, a Gate, pollUntil, or move the suite to ContractTests"
fi
# 2. No ambient WRITE-TARGET path statics in unit tests. Deliberately narrow (confirm/deny fix):
#    - Config.home is a pure derivation input (asserted by config-derivation tests) — excluded.
#    - `Config.dataDir(` with a paren is the PURE resolver dataDir(isLinux:home:env:) — excluded;
#      the bare static `Config.dataDir` is the ambient write target — matched.
#    - socketPath/hooksPath are asserted as derived STRINGS by resolver/adapter unit tests
#      (ConnectionSocketResolverTests:15, AdapterTests:40) and their write paths are launch-time
#      (contract tier) — excluded. The hazard this rule guards is shared filesystem STATE.
if grep -rnE 'NSHomeDirectory\(\)|Config\.defaultScratchRoot|Config\.dataDir[^(A-Za-z]|Config\.(tasksPath|logPath)\b' \
     Tests/UnitTests --include='*.swift'; then
  say "ambient path in a unit test — use the TestEnv per-test base"
fi
# 3. No real forks in the unit tier — neither direct Proc calls nor a RealProc handed to a seam.
if grep -rnE '\bProc\.(run|checked|runShell)\(|\bRealProc\(' Tests/UnitTests --include='*.swift'; then
  say "real process runner in a unit test — inject FakeProc"
fi
# 4. makeReal is contract-tier-only.
if grep -rn 'makeReal' Tests/UnitTests --include='*.swift'; then
  say "TestEnv.makeReal in the unit tier — real git; move the test to ContractTests"
fi
exit $fail
```

**`Package.swift` targets:** as previously drafted, with one review fix — `ContractTests` gets `resources: [.copy("Fixtures")]` (SessionManagerTests loads `Fixtures/menu.sh` via `Bundle.module` — `SessionManagerTests.swift:210-212`); the fixture files split: `menu.sh` (and anything else contract-side) → `Tests/ContractTests/Fixtures/`, `gen-slow-repo.sh` + fake-agent fixtures → `Tests/E2ETests/Fixtures/` (follow `IntegrationSupport`'s actual `Bundle.module` lookups when splitting).

**Move-map corrections (review MAJOR):**
- `ReadOnlyLaunchTests` (omitted before) → `Tests/UnitTests/OrchestraCore/Service/`.
- `ModelReseatTests` has ONE home: `Service/` (drop the earlier "adapter-half" double listing).
- `HomeIsolationTests` → `Tests/ContractTests/Proc/` (it FileManager-probes ambient HOME paths — that is the process-environment contract, and it references `Config.defaultScratchRoot`, which lint rule 2 rightly bans from UnitTests).
- `UDSShutdownTests`/`UDSSigPipeTests` → per Task 7's recorded decision (default: `ContractTests/Proc/`).
- `RepoScannerTests` stays in UnitTests (its `Config.home` use is a pure derivation equality — lint rule 2 deliberately doesn't match `Config.home`).
- `E2EBinaryTests.swift:70-72` and `ReportHelperPipeTests.swift:16-18` compute the package root as three `deletingLastPathComponent()`s off `#filePath` — moving one level deeper breaks it. Replace with a walk-up helper in each target's `Support/` (`while !FileManager.default.fileExists(atPath: dir + "/Package.swift") { dir = parent }`), immune to future moves.
- Everything else per the original mapping table (unchanged and carried forward).

- [ ] **Step 1: Task 10 completes first** (below — it is sequenced before this task despite the numbering).
- [ ] **Step 2: The flip commit** (Package.swift + moves + test.sh + lint, as one).
- [ ] **Step 3: Verify counts** (`--all` == pre-flip total; default+contract+e2e sum; record each tier's count + wall-clock).
- [ ] **Step 4: `scripts/lint-tests.sh` clean.**
- [ ] **Step 5: Commit is already made in Step 2; push nothing extra.**

### Task 10: Split the 30 hidden-integration suites (runs BEFORE the flip)

Per-area table as previously specified, with these review-driven strengthenings:

- **Fidelity matrices extend beyond `git config`** (both reviewers' (d)): the exit codes that carry semantics are exactly where drift bites — `+Tree.swift:585` distinguishes nil-from-0 on `rev-list --count`, `:593` treats non-1 failures of `merge-base --is-ancestor` differently from exit 1, `RemoteParents.swift:32-49` branches on `fetch`/`ls-remote` exit codes. So THREE contract matrices, each running one operation table against BOTH the FakeProc rules and real git in a temp repo, asserting identical `(exitCode, stdout-shape, stderr-presence)`:
  1. `GitConfigContractTests` (get/set/unset/get-regexp × present/missing),
  2. `GitRevContractTests` (rev-parse, rev-list --count, merge-base --is-ancestor: ancestor/non-ancestor/unknown-ref),
  3. `RemoteFetchContractTests` (fetch/ls-remote against a local `--bare` origin: reachable/unreachable/missing-branch).
  The shared FakeProc rule-sets used by unit suites live in **`Tests/TestSupport/RepoScripts.swift`** — TestSupport exists from Task 1 and is a dependency of every test target, so the location is valid BEFORE the flip (Task 10 runs under the old target names) and AFTER it; the matrices exercise THE SAME rule objects (confirm/deny fix: the earlier `Tests/UnitTests/Support/` location was unowned pre-flip).
- **Assertion mapping is mandatory** (review MAJOR): each suite's conversion commit includes, in the commit body, a table mapping every original real-git assertion → `unit(<new test>)` | `contract(<matrix row / test>)` | `deleted(<reason>)`. "One test per real behavior" is replaced by this exhaustive mapping — nothing is silently discarded.
- **At the end of this task:** flip `TestEnv.make`'s default `proc` to `FakeProc` with `GitConfigEmulator` pre-installed (review MAJOR-9 — the unit tier's default construction path hands out no real runner); `TestEnv.makeReal` moves to `Tests/ContractTests/Support/RealEnv.swift` in the Task-9/11 flip commit.
- Full suite ×3 green; commit per area (6 commits), each with its assertion map.

### Task 12: E2E fat-cutting

As previously specified (single 12k fixture; hoisted E2EBinary setup; pollUntil for its 1.5s/200ms waits; one tmux server per SessionManager suite), with the review fix:

- **Slow-repo template + per-case copy** (confirm/deny fix — a truly shared repo is impossible: `WorktreeManager.ensure` runs `git -C realRepo worktree add -b …`, which writes branch refs and `.git/worktrees` metadata into the repo, so two parameterized cases would interleave writes and no suite-final teardown exists across cases). Instead: generate the 12k-file repo ONCE into a template `T = IntegrationSupport.tempDir("slowrepo-template")` (async-lazy static task — the expensive part, ~one generation instead of two), then each case does `cp -R T base/repos/repo` (cheap — the design doc's own template trick) and runs entirely inside its private base with today's per-case cleanup. No shared writes, no cross-case coordination; `T` lives under the OS temp dir (best-effort `removeItem` by whichever case runs last, and TMPDIR reaping as the backstop).

---

# Stage 3 — Docs, guardrails, accounting

### Task 13: Docs + final report

As previously specified (CLAUDE.md tiering section → new contract; `docs/08-building-operations.md`; living plan templates only; 3× idle-machine measurements of default/`--contract`/`--e2e`/`--all` with medians, stated post-nudge-fix; exact accounting start 1,157 → deletions/merges/additions → per-tier end counts; design-doc baseline table updated; then `superpowers:verification-before-completion`, the Claude+Codex diff review pair, and `merge-request`).

---

## Spec amendments (applied to `notes/designs/2026-07-13-test-suite-redesign.md` alongside this revision)

1. **§4.2 Paths — deliberate narrowing.** The full `Paths` value type is narrowed to instance `scratchRoot` + `runtimeStateDir`: every other derived path is ALREADY per-instance injected via store constructors (`TaskStore(path:)`, `TrustLedger(path:)`, `Inbox(path:)`, `WatchRegistryStore(path:)`, `borrowsPath`, `markersDir` — TestEnv passes all of them under its private base), and the remaining statics (`socketPath`, `hooksPath`, `tmuxSocket`) are launch/CLI-surface values that unit tests never exercise (stubbed at the SessionManaging/adapter seams; real behavior is contract/e2e territory). The two narrowed-in properties are exactly the two through which one test's filesystem effects could reach another.
2. **§4.3 example** — the `git worktree add` gate is delivered at the `StubWorktrees` seam (WorktreeRegistry is its own actor with its own `run:` closure), and `ProcRunning` is async (suspension gates; RealProc preserves blocking semantics inline).
3. **§8 tier honesty** — enforced by the default construction path (`TestEnv.make` hands out `FakeProc`; `makeReal` lives in ContractTests) plus lint rules 3/4 — not "the type system" (RealProc remains a public symbol).

## Self-review notes (applied)

- Both reviewers' findings folded; one rebuttal (async-let `try`) with the `swiftc -typecheck` probe as evidence.
- Task numbering kept (9..13) but the EXECUTION order is 10 → 9+11 (interlocked flip) → 12 → 13, stated at each site.
- Category-4 deletions remain gated on Allen; nothing in Stage 2 depends on the answer.
