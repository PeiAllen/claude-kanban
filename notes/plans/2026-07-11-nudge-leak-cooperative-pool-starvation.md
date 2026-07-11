# Nudge leak + cooperative-pool starvation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `swift test` (and a live `orchestrad`) from wedging forever, by making the merge-request/remote-watch timer loops genuinely weak, giving `OrchestraService` a real teardown, and moving the three fork-blocking actors off the Swift cooperative pool.

**Architecture:** Two composing defects. (1) Timer loops hoist `guard let self` above their `while`, so `[weak self]` buys nothing and every armed loop pins an immortal `OrchestraService`. (2) `BranchLineage` / `RemoteParents` / `WorktreeRegistry` are actors that call synchronous `Proc.run`, which parks a cooperative-pool thread (~1/core, no thread donation) on a `DispatchSemaphore`. Leaked loops × blocking forks = every pool thread consumed = nothing async ever progresses again. Fix (1) with per-iteration weak re-acquisition + a `shutdown()`; fix (2) by giving those three actors a `DispatchSerialQueue`-backed executor so their blocking work parks a **GCD** thread instead — preserving their load-bearing serial semantics, which an `offActor` hop would dissolve.

**Tech Stack:** Swift 6, swift-testing (`Testing`) + XCTest, SwiftPM, macOS 14+.

**Design doc:** `notes/designs/2026-07-11-nudge-leak-cooperative-pool-starvation.md` — read it first.

## Global Constraints

- **Tasks 1–5 ship together, in order, on one branch.** The executor fix (Tasks 4–5) must **never** be cherry-picked without the leak fix (Tasks 1–3). Alone it would convert a cooperative-pool deadlock into GCD thread explosion — worse, because there is no clean deadlock left to catch it. This is a correctness constraint, not a preference.
- **Do not change any actor's serialization or reentrancy semantics.** `WorktreeRegistry.ensure` documents "NO `await` between the marker check and the checkout"; `BranchLineage.set` is a read-modify-write with rollback. Introducing an `await` inside either method reopens a concurrent-spawn race and a torn-parent-link write. The executor change adds **no new suspension points** — verify this holds for every method you touch.
- **The custom serial executor is safe only because these actors are per-daemon** (one `OrchestraService` ⇒ one instance of each). Every executor site carries a comment saying so. Do not attach one to a per-request actor.
- **No test may hang on failure.** The bug being fixed *is* a hang. A regression test that deadlocks the cooperative pool instead of failing is worthless. Task 4's starvation test is therefore a **synchronous XCTest** whose waits are `DispatchSemaphore.wait(timeout:)` on a non-cooperative thread.
- Platform floor macOS 14 / Swift 6 — `DispatchSerialQueue`'s `SerialExecutor` conformance requires it. Already satisfied by `Package.swift` (`platforms: [.macOS(.v14), .iOS(.v17)]`).
- **Out of scope** (separate cards, do not touch): suite slowness (12k-file fixture, per-test tmux servers, 73 hardcoded sleeps); test-suite git hermeticity (`test/git-hermeticity`); re-nudge backoff/give-up cap (`feat/merge-request-nudge-backoff`).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/OrchestraCore/OrchestraService+MergeRequest.swift` | Modify `startMergeRequestNudge` (64-76) | Per-iteration weak self |
| `Sources/OrchestraCore/OrchestraService+Remote.swift` | Modify `startRemoteWatch` (191-210) | Per-iteration weak self |
| `Sources/OrchestraCore/OrchestraService.swift` | Add `shutdown()` + `deinit` | Cancel every long-lived loop |
| `Sources/orchestrad/main.swift` | Modify SIGTERM handler (~74) | Call `shutdown()` on clean exit |
| `Sources/OrchestraCore/BranchLineage.swift` | Add executor + injectable timed `run` | Off-pool, bounded git config |
| `Sources/OrchestraCore/RemoteParents.swift` | Add executor + timeout on `rev-parse` | Off-pool, bounded remote git |
| `Sources/OrchestraCore/WorktreeRegistry.swift` | Add executor to the actor (192) | Off-pool `git worktree add` |
| `Sources/OrchestraCore/Proc.swift` | Default `timeout` = 120s | No unbounded fork by default |
| `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` | Create | Leak + shutdown regressions |
| `Tests/OrchestraCoreTests/CooperativePoolStarvationTests.swift` | Create | Pool-starvation regression (XCTest) |

---

## Task 1: The merge-request nudge loop must not pin the service

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+MergeRequest.swift:64-76`
- Test: `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` (create)

**Interfaces:**
- Consumes: `TestEnv.make()`, `TestEnv.spawnAndAwaitLive`, `ShipChoreoTests.repoWithChild(_:)` (all existing, see `Tests/OrchestraCoreTests/Stubs.swift` and `RebuildMergeRequestNudgesTests.swift`).
- Produces: nothing new; `startMergeRequestNudge(childId:)` keeps its exact signature.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/ServiceTeardownTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

/// The nudge/watch loops used to hoist `guard let self` ABOVE their `while`, so `[weak self]` bought
/// nothing: an armed loop held a STRONG reference and pinned `OrchestraService` (plus its store,
/// lineage and inbox) for the life of the process. Every test that left a card `.mergeRequested`
/// leaked an immortal service still forking `git`. Enough of them and the cooperative pool starved
/// and nothing async in the process progressed again — including the test runner.
@Suite("service teardown — long-lived loops must not pin the service")
struct ServiceTeardownTests {

    /// Bounded wait for `ref` to become nil. Deallocation is not synchronous with the last release
    /// (the loop must first hop, observe nil, and unwind), so poll rather than assert immediately.
    private func awaitDeallocated(_ ref: @escaping () -> AnyObject?, within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if ref() == nil { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return ref() == nil
    }

    @Test("an armed merge-request nudge does not pin the service")
    func nudgeDoesNotPinService() async throws {
        weak var weakSvc: OrchestraService?

        // Scope the ONLY strong reference so it drops at the end of this block. A long interval parks
        // the loop in its sleep — exactly the state that used to hold `self` strongly.
        do {
            let env = TestEnv.make()
            let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
            _ = try await TestEnv.spawnAndAwaitLive(
                env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
            let child = try await TestEnv.spawnAndAwaitLive(
                env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
            try await BranchLineage().set(repo: repo, branch: "child",
                                          link: ParentLink(parent: "parent", base: parentTip))
            await env.svc.setMergeRequestNudgeInterval(.seconds(3600))   // park the loop in its sleep
            _ = try await env.svc.mergeRequest(ref: child.ref())
            #expect(await env.svc.mergeRequestNudgeActive(child.id))     // the loop IS armed
            weakSvc = env.svc
        }

        #expect(await awaitDeallocated({ weakSvc }),
                "an armed merge-request nudge pinned OrchestraService — the loop is not genuinely weak")
    }
}
```

- [ ] **Step 2: Run it and verify it FAILS**

```bash
swift test --filter ServiceTeardownTests 2>&1 | tail -20
```

Expected: FAIL — `an armed merge-request nudge pinned OrchestraService`. The loop's hoisted `guard let self` holds a strong reference, so `weakSvc` never goes nil.

If it *passes*, stop: something else is retaining or releasing the service and the test is not measuring what it claims. Investigate before proceeding.

- [ ] **Step 3: Make the loop genuinely weak**

Replace `startMergeRequestNudge` (`OrchestraService+MergeRequest.swift:64-76`) with:

```swift
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        // `self` is re-acquired PER CALL, never hoisted above the loop. A hoisted `guard let self`
        // would hold a strong reference for the loop's entire life — including the sleep, which is
        // ~all of it — so `[weak self]` would buy nothing and the service could never deallocate.
        // Optional-chaining each hop takes a temporary strong ref only for that call's duration; once
        // the service is gone the next hop yields nil and the loop unwinds.
        mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let interval = await self?.mergeRequestNudgeInterval else { return }
                try? await _Concurrency.Task.sleep(for: interval)
                if _Concurrency.Task.isCancelled { return }
                guard let stop = await self?.reNudgeMergeRequest(childId) else { return }
                if stop { break }                       // no longer pending — stop
            }
            await self?.clearMergeRequestNudge(childId)
        }
    }
```

- [ ] **Step 4: Run the new test AND the existing nudge suites**

```bash
swift test --filter 'ServiceTeardownTests|MergeRequestTests|RebuildMergeRequestNudgesTests' 2>&1 | tail -20
```

Expected: PASS. The existing `MergeRequestTests` / `RebuildMergeRequestNudgesTests` must be **unchanged and still green** — the loop's observable behaviour (re-prod cadence, stop conditions, `mergeRequestNudgeActive`) is identical; only the retain semantics changed.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+MergeRequest.swift Tests/OrchestraCoreTests/ServiceTeardownTests.swift
git commit -m "fix: merge-request nudge loop must not pin OrchestraService

The hoisted `guard let self` held a strong ref for the loop's whole life, so
`[weak self]` bought nothing and every armed nudge leaked an immortal service
still forking git. Re-acquire self per hop instead."
```

---

## Task 2: The remote-watch loop has the identical bug

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift:191-210`
- Test: `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` (extend)

**Interfaces:**
- Consumes: `RemoteWatchLoopTests.remoteChild()` (existing, `Tests/OrchestraCoreTests/RemoteWatchLoopTests.swift:8`) → `(svc: OrchestraService, repo: String, card: Task)`; `TestEnv.makeReal()`; `RemoteParentTests.makeOriginWithPR(repoDir:)`.
- Produces: nothing new; `startRemoteWatch(cardId:)` keeps its exact signature, generation-token logic untouched.

- [ ] **Step 1: Write the failing test**

Append to `ServiceTeardownTests`:

```swift
    @Test("an armed remote watch does not pin the service")
    func remoteWatchDoesNotPinService() async throws {
        weak var weakSvc: OrchestraService?

        do {
            // A remote-base spawn arms the watch loop (see RemoteWatchLoopTests.spawnStartsWatch).
            // A long idle interval parks it in its sleep — the state that used to hold `self`.
            let (svc, _, card) = try await RemoteWatchLoopTests.remoteChild()
            await svc.setRemoteWatchIntervals(active: .seconds(3600), idle: .seconds(3600))
            await svc.startRemoteWatch(cardId: card.id)          // re-arm on the long interval
            #expect(await svc.remoteWatchActive(card.id))
            weakSvc = svc
        }

        #expect(await awaitDeallocated({ weakSvc }),
                "an armed remote watch pinned OrchestraService — the loop is not genuinely weak")
    }
```

- [ ] **Step 2: Run it and verify it FAILS**

```bash
swift test --filter 'ServiceTeardownTests.remoteWatchDoesNotPinService' 2>&1 | tail -20
```

Expected: FAIL — `an armed remote watch pinned OrchestraService`.

- [ ] **Step 3: Make the loop genuinely weak**

Replace the Task body in `startRemoteWatch` (`OrchestraService+Remote.swift:199-209`). **Keep the generation token (`gen`) exactly as-is** — it guards a restart race and is orthogonal to this fix:

```swift
        remoteWatch[cardId] = _Concurrency.Task { [weak self] in
            // `self` is re-acquired PER CALL, never hoisted above the loop — see the note on
            // `startMergeRequestNudge`. A hoisted `guard let self` pins the service for the loop's
            // entire life, so `[weak self]` buys nothing and the service can never deallocate.
            while !_Concurrency.Task.isCancelled {
                guard let stop = await self?.shouldStopRemoteWatch(cardId) else { return }
                if stop { break }
                guard let outcome = await self?.remoteMergeStep(cardId: cardId) else { return }
                guard let intervals = await self?.remoteWatchIntervals else { return }
                let delay = (outcome == .fetched) ? intervals.active : intervals.idle  // movement ⇒ poll faster
                try? await _Concurrency.Task.sleep(for: delay)
            }
            await self?.clearRemoteWatch(cardId, gen: gen)
        }
```

- [ ] **Step 4: Run the new test AND the existing remote-watch suite**

```bash
swift test --filter 'ServiceTeardownTests|RemoteWatchLoopTests|SetParentRemoteTests' 2>&1 | tail -20
```

Expected: PASS, with `RemoteWatchLoopTests` (including `restartThenStopIsInactive`, which exercises the generation-token race) unchanged and still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Remote.swift Tests/OrchestraCoreTests/ServiceTeardownTests.swift
git commit -m "fix: remote-watch loop must not pin OrchestraService

Identical hoisted-\`guard let self\` bug to the merge-request nudge. Generation
token logic is untouched."
```

---

## Task 3: `OrchestraService` gets a real teardown

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add after `flushBeforeShutdown`, ~line 255)
- Modify: `Sources/orchestrad/main.swift:74` (SIGTERM handler)
- Test: `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` (extend)

**Interfaces:**
- Produces: `public func shutdown()` on `OrchestraService` — cancels every long-lived loop. Callable from the daemon's SIGTERM path and from tests.
- Consumes: the five task registries declared in `OrchestraService.swift`: `mergeRequestNudge` (66), `remoteWatch` (52), `diffStatDebounce` (166), `treeStatDebounce` (169), `childFanoutDebounce` (172) — all `[UUID: _Concurrency.Task<Void, Never>]`.

- [ ] **Step 1: Write the failing test**

Append to `ServiceTeardownTests`:

```swift
    @Test("shutdown() cancels every outstanding merge-request nudge")
    func shutdownCancelsNudges() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        await env.svc.setMergeRequestNudgeInterval(.seconds(3600))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(await env.svc.mergeRequestNudgeActive(child.id))

        await env.svc.shutdown()

        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false,
                "shutdown() left a merge-request nudge armed")
    }
```

- [ ] **Step 2: Run it and verify it FAILS**

```bash
swift test --filter 'ServiceTeardownTests.shutdownCancelsNudges' 2>&1 | tail -20
```

Expected: FAIL to **compile** — `value of type 'OrchestraService' has no member 'shutdown'`. A compile failure is a legitimate red for a new API.

- [ ] **Step 3: Add `shutdown()` and `deinit`**

In `Sources/OrchestraCore/OrchestraService.swift`, directly after `flushBeforeShutdown()`:

```swift
    /// Cancel every long-lived loop this service owns. The daemon calls this on SIGTERM; tests call it
    /// to prove no timer outlives the service. Distinct from `flushBeforeShutdown` (which persists
    /// state): this releases *work*, that one releases *data* — a clean exit wants both.
    ///
    /// Before the weak-loop fix there was nothing to call: an armed nudge/watch held a STRONG ref, so
    /// the service could not deallocate and no teardown could run. The loops are now genuinely weak;
    /// this makes teardown DETERMINISTIC rather than merely possible.
    public func shutdown() {
        for t in mergeRequestNudge.values { t.cancel() }
        for t in remoteWatch.values { t.cancel() }
        for t in diffStatDebounce.values { t.cancel() }
        for t in treeStatDebounce.values { t.cancel() }
        for t in childFanoutDebounce.values { t.cancel() }
        mergeRequestNudge.removeAll(); remoteWatch.removeAll()
        diffStatDebounce.removeAll(); treeStatDebounce.removeAll(); childFanoutDebounce.removeAll()
    }

    /// Backstop for the paths that never call `shutdown()` (a test's service simply going out of
    /// scope). Cancellation is idempotent, so double-cancelling after an explicit `shutdown()` is a
    /// no-op. NOTE: this is only REACHABLE because the loops above are genuinely weak — a pinned
    /// service never deinits.
    deinit {
        for t in mergeRequestNudge.values { t.cancel() }
        for t in remoteWatch.values { t.cancel() }
        for t in diffStatDebounce.values { t.cancel() }
        for t in treeStatDebounce.values { t.cancel() }
        for t in childFanoutDebounce.values { t.cancel() }
    }
```

**Contingency:** if Swift 6 strict concurrency rejects reading actor-isolated stored properties from `deinit`, **drop the `deinit` entirely and keep `shutdown()`**. The `deinit` is a backstop, not the fix — Tasks 1–2 are what stop the leak. Do not reach for `@_unsafeInheritExecutor`, `assumeIsolated`, or an `isolated deinit` shim to force it.

- [ ] **Step 4: Run the test**

```bash
swift test --filter 'ServiceTeardownTests' 2>&1 | tail -20
```

Expected: PASS (all four tests: two leak, one shutdown, plus whatever you added).

- [ ] **Step 5: Wire `shutdown()` into the daemon's SIGTERM path**

In `Sources/orchestrad/main.swift`, replace the SIGTERM handler (line ~74):

```swift
sigterm.setEventHandler {
    _Concurrency.Task {
        await service.shutdown()             // cancel the nudge/watch/debounce loops
        await service.flushBeforeShutdown()   // then persist any debounced tasks.json write
        exit(0)
    }
}
```

Order matters: cancel the loops *first* so an in-flight nudge can't enqueue new work into the store after the flush.

- [ ] **Step 6: Build the daemon and commit**

```bash
swift build --product orchestrad 2>&1 | tail -5
git add Sources/OrchestraCore/OrchestraService.swift Sources/orchestrad/main.swift Tests/OrchestraCoreTests/ServiceTeardownTests.swift
git commit -m "feat: OrchestraService.shutdown() cancels every long-lived loop

Wired into orchestrad's SIGTERM path ahead of flushBeforeShutdown, so an
in-flight nudge cannot enqueue work after the final persist."
```

---

## Task 4: `BranchLineage` off the cooperative pool, with bounded git

**Files:**
- Modify: `Sources/OrchestraCore/BranchLineage.swift`
- Test: `Tests/OrchestraCoreTests/CooperativePoolStarvationTests.swift` (create)

**Interfaces:**
- Produces: `BranchLineage.init(run:)` — an **internal** test seam taking `@Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult`. Mirrors the existing `WorktreeManager.run` seam (`WorktreeRegistry.swift:16-27`).
- Public API (`read`/`set`/`clear`/`updateBase`/`children`/`ancestors`) and `public init()` are **unchanged**. No call site in `Sources/` or `Tests/` changes.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/CooperativePoolStarvationTests.swift`.

**This is a synchronous XCTest on purpose.** An `async` test body runs *on* the cooperative pool, so once the pool is starved the body can never resume and the test would **hang instead of failing** — reproducing the very bug we are fixing. A sync XCTest body runs on a plain thread, so its `DispatchSemaphore.wait(timeout:)` is safe and a starved pool produces a clean, fast FAIL.

```swift
import XCTest
import Foundation
@testable import OrchestraCore

/// The cooperative pool is ~one thread per core and does NOT grow (no thread donation) — that is the
/// enforcement mechanism for Swift's "async code never blocks a thread" contract. An `actor` runs on
/// that pool, so a synchronous `Proc.run` inside an actor method parks a pool thread on a semaphore.
/// Park enough of them and every async task in the process stops forever — which is exactly how
/// `swift test` used to wedge at ~975/1180 tests, and how a live `orchestrad` wedges.
///
/// `BranchLineage` now runs on its own `DispatchSerialQueue` executor, so its blocking git forks park
/// GCD threads instead. This test proves it: saturate the pool's worth of lineage reads, then require
/// unrelated async work to still make progress.
final class CooperativePoolStarvationTests: XCTestCase {

    func test_blockingLineageReadsDoNotStarveTheCooperativePool() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let instances = cores + 4          // more than enough to saturate the pool if it can be saturated
        let entered = DispatchSemaphore(value: 0)   // signalled once per git call that has begun
        let release = DispatchSemaphore(value: 0)   // held shut until the assertion is made

        // Each instance gets its OWN BranchLineage — mirroring the leak, where every zombie
        // OrchestraService brought its own. A single instance could only ever block one thread.
        let lineages = (0..<instances).map { _ in
            BranchLineage(run: { _, _ in
                entered.signal()
                release.wait()                       // park here, as a real `git config` fork would
                return ProcResult(stdout: "", stderr: "", exitCode: 0)
            })
        }

        // `read` calls `get(kParent)` first; an empty stdout makes it return nil immediately after,
        // so this is exactly ONE blocking `run` per instance.
        for l in lineages {
            _Concurrency.Task { _ = await l.read(repo: "/repo", branch: "b") }
        }

        // Wait until at least `cores` git calls are parked — i.e. the pool WOULD be saturated if these
        // ran on it. (On the fixed code all `instances` enter, on their own GCD threads; either way
        // `cores` signals arrive.)
        for _ in 0..<cores {
            XCTAssertEqual(entered.wait(timeout: .now() + 10), .success,
                           "lineage reads never entered their git call")
        }

        // The falsifying observation: can the cooperative pool still run ANY async work?
        let progressed = DispatchSemaphore(value: 0)
        _Concurrency.Task { progressed.signal() }
        let ok = progressed.wait(timeout: .now() + 5) == .success

        for _ in 0..<instances { release.signal() }   // unpark every blocked call, always

        XCTAssertTrue(ok, """
            The Swift cooperative pool was starved: \(cores) blocking BranchLineage reads stopped a \
            trivial unrelated Task from running at all. This is the orchestrad/swift-test wedge.
            """)
    }
}
```

- [ ] **Step 2: Run it and verify it FAILS (cleanly, in ~5s — not by hanging)**

```bash
time swift test --filter CooperativePoolStarvationTests 2>&1 | tail -25
```

Expected: FAIL to **compile** first (`BranchLineage` has no `init(run:)`). Add *only* the `init(run:)` seam plus the `run` property (Step 3's first half), re-run, and confirm you now get a genuine **assertion failure**: `The Swift cooperative pool was starved…`, in roughly 5 seconds.

If it PASSES before the executor is added, the test is not saturating the pool — do not proceed. Raise `instances` and re-check that `cores` really is the pool width on this machine.

- [ ] **Step 3: Add the serial executor and the bounded, injectable `run`**

Rewrite the head of `Sources/OrchestraCore/BranchLineage.swift` (the `public actor BranchLineage {` block, lines 21-30):

```swift
public actor BranchLineage {
    /// Blocking `git config` forks happen on THIS actor. A default actor runs on Swift's cooperative
    /// pool — ~one thread per core, and it does NOT grow — so a synchronous `Proc.run` there parks a
    /// pool thread on a semaphore. Enough concurrent lineage reads and every async task in the process
    /// stops forever (the orchestrad wedge; `swift test` used to die this way at ~975/1180 tests).
    ///
    /// A `DispatchSerialQueue` executor parks a GCD thread instead. It is still a SERIAL executor, so
    /// the mailbox still runs one call at a time — which every method below relies on: `set` is a
    /// read-modify-write with a rollback path, correct only because nothing can interleave. Hopping
    /// each fork off-actor (the `offActor` seam) would have dissolved exactly that guarantee.
    ///
    /// SAFE ONLY BECAUSE THIS ACTOR IS PER-DAEMON: one `OrchestraService` ⇒ one `BranchLineage` ⇒ one
    /// queue. A custom serial executor is NOT free in general — attach one to a per-request actor and
    /// you trade cooperative-pool starvation for GCD thread explosion.
    private let queue = DispatchSerialQueue(label: "orchestra.lineage")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Git runner. `timeout` is a REQUIRED `Duration` — an unbounded `git config` in this file is a
    /// compile error (mirrors `WorktreeManager.run`). Injectable so tests can park it deterministically.
    private let run: @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult

    /// `git config` is a metadata op — milliseconds in the normal case. This bound only exists so a
    /// fork wedged on a held `.git/config.lock` can never park its thread forever.
    private static let gitTimeout: Duration = .seconds(15)

    public init() { self.run = { try Proc.run($0, timeout: $1) } }

    /// Test seam: inject the timed runner (e.g. one that blocks, to prove the pool is not starved).
    internal init(run: @escaping @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult) {
        self.run = run
    }
```

Then replace all four `Proc.run` calls in this file with the injected, bounded `run`:

```swift
    private func get(_ repo: String, _ branch: String, _ suffix: String) -> String? {
        guard let r = try? run(["git", "-C", repo, "config", "--get", key(branch, suffix)], Self.gitTimeout),
              r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func setKey(_ repo: String, _ branch: String, _ suffix: String, _ value: String) throws {
        let r = try run(["git", "-C", repo, "config", key(branch, suffix), value], Self.gitTimeout)
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "git config write failed" : r.stderr) }
    }

    /// `--unset` one key; exit 5 (key absent) is not an error.
    private func unset(_ repo: String, _ branch: String, _ suffix: String) {
        _ = try? run(["git", "-C", repo, "config", "--unset", key(branch, suffix)], Self.gitTimeout)
    }
```

and in `children(repo:of:)`:

```swift
        guard let r = try? run(["git", "-C", repo, "config", "--get-regexp", pattern], Self.gitTimeout), r.ok
        else { return [] }
```

Also update the type doc at the top of the file (line 20): replace `Every op is \`Proc.run([...])\` — the house git idiom.` with `Every op is a bounded \`git config\` on this actor's own serial queue — see the executor note below.`

- [ ] **Step 4: Run the starvation test AND the lineage suites**

```bash
time swift test --filter 'CooperativePoolStarvationTests|LineageTests|LineageSpawnTests|LineageModelTests|BoardTreeTests' 2>&1 | tail -20
```

Expected: PASS, fast. `LineageTests` et al. must be unchanged and still green — public behaviour is identical.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/BranchLineage.swift Tests/OrchestraCoreTests/CooperativePoolStarvationTests.swift
git commit -m "fix: run BranchLineage on its own serial queue, bound its git calls

An actor runs on the cooperative pool (~1 thread/core, no growth), so its
synchronous git forks parked pool threads and starved every async task in the
process. A DispatchSerialQueue executor parks GCD threads instead while keeping
the mailbox serial — which set()'s read-modify-write rollback depends on."
```

---

## Task 5: `RemoteParents` and `WorktreeRegistry` off the cooperative pool

**Files:**
- Modify: `Sources/OrchestraCore/RemoteParents.swift:15-16`, and the untimed `rev-parse` at line 38
- Modify: `Sources/OrchestraCore/WorktreeRegistry.swift:192` (the `public actor WorktreeRegistry {` block)

**Interfaces:** No API change to either type. No call site changes.

- [ ] **Step 1: Give `RemoteParents` a serial executor and bound its last untimed fork**

`RemoteParents` forks `git fetch` / `git ls-remote` — network ops, up to 20s each, currently on the cooperative pool. In `Sources/OrchestraCore/RemoteParents.swift`, replace lines 15-16:

```swift
public actor RemoteParents {
    /// Network git (`fetch`/`ls-remote`) blocks for up to `timeout`. On the cooperative pool that
    /// parks a thread that cannot be replaced — see the executor note on `BranchLineage`. Per-daemon
    /// actor (one instance), so one queue.
    private let queue = DispatchSerialQueue(label: "orchestra.remote-parents")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init() {}
```

And bound the one fork in this file that has no timeout (line 38) — its siblings already carry `Self.timeout`:

```swift
        let v = try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref.privateRef],
                             timeout: Self.timeout)
```

- [ ] **Step 2: Give `WorktreeRegistry` a serial executor**

This is the worst offender: `git worktree add` carries a **600s** timeout (`Config.worktreeAddTimeout`), so a single slow checkout can pin a cooperative thread for ten minutes.

In `Sources/OrchestraCore/WorktreeRegistry.swift`, immediately after `public actor WorktreeRegistry {` (line 192):

```swift
public actor WorktreeRegistry {
    /// `git worktree add` runs synchronously on THIS actor with a 600s timeout — on the cooperative
    /// pool that pins a non-replaceable thread for up to ten minutes. A `DispatchSerialQueue` executor
    /// parks a GCD thread instead.
    ///
    /// Serial semantics are LOAD-BEARING here and are preserved exactly: `ensure` documents "NO `await`
    /// between the marker check and the checkout, so two concurrent same-branch calls run one-at-a-time
    /// and `git worktree add` fires once". This change adds no suspension point, so that still holds.
    /// Hopping the fork off-actor would NOT have — it would have reopened the concurrent-spawn race.
    ///
    /// Per-daemon actor (one instance), so one queue. See the note on `BranchLineage`.
    private let queue = DispatchSerialQueue(label: "orchestra.worktrees")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let config: Config
```

- [ ] **Step 3: Verify NO new suspension point was introduced**

This is the constraint most likely to be violated silently. Confirm by inspection that neither file gained an `await`:

```bash
git diff Sources/OrchestraCore/RemoteParents.swift Sources/OrchestraCore/WorktreeRegistry.swift | grep '^+' | grep -c 'await'
```

Expected: `0`. If it is not 0, you have changed reentrancy semantics — revert and rethink.

- [ ] **Step 4: Run the affected suites**

```bash
swift test --filter 'WorktreeRegistryIntegrationTests|WorktreeTests|BorrowLifecycleTests|BorrowedSpawnTests|RemoteWatchLoopTests|SetParentRemoteTests|RemoteRecomputeTests|LadderTests' 2>&1 | tail -20
```

Expected: PASS, all unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/RemoteParents.swift Sources/OrchestraCore/WorktreeRegistry.swift
git commit -m "fix: run RemoteParents + WorktreeRegistry on their own serial queues

git worktree add carries a 600s timeout — on the cooperative pool that pinned a
non-replaceable thread for ten minutes. Serial semantics preserved exactly: no
new suspension point, so ensure()'s no-await-between-check-and-checkout
invariant still holds."
```

---

## Task 6: `Proc.run` stops defaulting to unbounded

**Files:**
- Modify: `Sources/OrchestraCore/Proc.swift:17-22`

**Interfaces:** `Proc.run`'s signature keeps `timeout: Duration?`; only the **default value** changes from `nil` to `.seconds(120)`. Passing `timeout: nil` explicitly remains the opt-out. Every existing caller that passes an explicit timeout is unaffected.

- [ ] **Step 1: Change the default**

In `Sources/OrchestraCore/Proc.swift`:

```swift
    /// Run `argv` (argv[0] resolved on PATH via /usr/bin/env), capturing stdout/stderr.
    ///
    /// `timeout` defaults to a generous ceiling rather than to nothing: an unbounded `exited.wait()`
    /// parks the calling thread FOREVER on a wedged fork, and callers reached for that default without
    /// meaning to. Long ops pass their own (e.g. `Config.worktreeAddTimeout` = 600s). Pass `nil`
    /// explicitly for the rare op that must genuinely run unbounded.
    @discardableResult
    public static func run(
        _ argv: [String],
        cwd: String? = nil,
        env extraEnv: [String: String] = [:],
        timeout: Duration? = .seconds(120)
    ) throws -> ProcResult {
```

- [ ] **Step 2: Audit every caller that relied on the old unbounded default**

```bash
grep -rn 'Proc\.run(\|Proc\.checked(' Sources/ | grep -v 'timeout:'
```

For each hit, confirm 120s is comfortably above its worst realistic runtime. The full set and its verdicts:

| Site | Op | Verdict |
|---|---|---|
| `BranchLineage.swift` (×4) | `git config` | **N/A** — Task 4 already gave these an explicit 15s |
| `RemoteParents.swift:38` | `git rev-parse` | **N/A** — Task 5 already gave this an explicit 20s |
| `Launcher.swift:61` | `bash open-obsidian-vault.sh` | OK — opens an editor; 120s is a backstop it should never approach |
| `Launcher.swift:141,165` | `open -a Zed`, `zed -n` | OK — launch-and-return |
| `Launcher.swift:238,243,254,267` | `git merge-base` / `ls-files` / `diff` | OK — local git, sub-second |
| `Diff/DiffBaseline.swift` (×4) | `git symbolic-ref` / `rev-parse` / `merge-base` | OK — local git, sub-second |
| `Diff/GitDiffProvider.swift` (×2) | `git diff` | OK — local git; already runs off-actor via `DiffProvider` |
| `SessionManager.swift:49` | `tmux …` | OK — local IPC, sub-second |
| `ConfigStore.swift:48` | `which` | OK |
| `OrchestraService+ParentRef.swift:22` | `git remote` | OK |
| `Control/DaemonLifecycle.swift:12` | `launchctl` | OK |
| `OrchestraUI/SSHMaster.swift:43,76` | `ssh -O exit` | OK — control-socket teardown |
| `Proc.checked` | delegates to `run` | Inherits the 120s default — intended |

If you find a site not in this table, add it and judge it explicitly. **If any site could legitimately exceed 120s, give it an explicit larger timeout rather than reverting the default.**

- [ ] **Step 3: Build and run the timeout suite**

```bash
swift build 2>&1 | tail -5
swift test --filter 'ConfigTimeoutTests|WorktreeRegistryIntegrationTests' 2>&1 | tail -10
```

Expected: builds clean; PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/Proc.swift
git commit -m "fix: Proc.run defaults to a 120s ceiling, not unbounded

An unbounded exited.wait() parks the calling thread forever on a wedged fork,
and callers reached for that default without meaning to. Explicit nil remains
the opt-out; long ops already pass their own."
```

---

## Task 7: Prove the suite terminates — and that we did not trade the bug for thread explosion

This is the **definition of done**. Until the suite terminates, "tests pass" is not a claim anyone can make.

**Files:** none — this is verification. Findings go in the PR body.

- [ ] **Step 1: Run the full suite to completion, timed, unsandboxed**

SwiftPM's own `sandbox-exec` fails inside the Claude sandbox, so this must run unsandboxed.

```bash
time swift test --parallel 2>&1 | tail -40
```

Expected: the suite **terminates** and reports a result. Record the wall-clock number — it goes in the PR body. (Before this fix it ran ~975/1180 tests and then sat silent, burning CPU, forever — 47 min before being killed on the first attempt.)

If any test fails, fix it. If the suite still hangs, `sample` the helper once it goes quiet and compare the stack against the one in the design doc:

```bash
pgrep -f swiftpm-testing-helper | head -1 | xargs sample
```

- [ ] **Step 2: Measure peak thread count — the falsification check**

The executor fix moves blocking off a pool that *cannot* grow onto GCD, which *can*. Under `--parallel` many services are alive at once, each now carrying three serial queues. **If this drives thread count somewhere ugly, the design is wrong and a number must say so.**

Run the suite in the background and sample the helper's thread count:

```bash
swift test --parallel > /tmp/claude/suite.log 2>&1 &
for i in $(seq 1 60); do
  pid=$(pgrep -f swiftpm-testing-helper | head -1)
  [ -n "$pid" ] && ps -M "$pid" 2>/dev/null | tail -n +2 | wc -l
  sleep 10
done | sort -n | tail -1
```

Expected: peak comfortably below GCD's ~64-per-QoS ceiling. Record the number.

**If it is at or near the ceiling**, fall back per the design doc's open sub-decision: give `BranchLineage` and `RemoteParents` a **shared static** queue (one per type, not per instance) instead of a per-instance one. Do **not** do this for `WorktreeRegistry` — a shared queue there would serialize every test's `git worktree add` and make an already-slow suite far slower.

- [ ] **Step 3: Verify both agent backends (CLAUDE.md)**

The nudge path is agent-agnostic, but confirm nothing regressed for either:

```bash
swift test --filter 'CodexAdapterTests|CodexRolloutTests|CodexWakeTests|AdapterTests|AdapterEncodeTests' 2>&1 | tail -10
```

Expected: PASS. Then exercise a real card end-to-end on an isolated daemon (never the live board) per `scripts/orch-test.sh`, for **claude** and for **codex**, and confirm a `merge-request` arms and re-nudges on both.

- [ ] **Step 4: Record the numbers and commit**

Put the wall-clock time and peak thread count in the PR body. They are the evidence the fix works; a green checkmark alone is not.

```bash
git commit --allow-empty -m "chore: full-suite verification

swift test --parallel terminates in <TIME> (was: never). Peak thread count
under --parallel: <N>. Both backends green."
```

---

## Self-Review Notes

- **Spec coverage:** Fix 1 (weak loops) → Tasks 1–2. Fix 1 (teardown) → Task 3. Fix 2 (executors) → Tasks 4–5. Fix 3 (timeouts) → Tasks 4 (BranchLineage 15s), 5 (RemoteParents 20s), 6 (Proc default 120s). Testing §1 leak → Task 1. §2 teardown → Task 3. §3 starvation → Task 4. §4 sibling leak → Task 2. DoD suite-terminates + wall-clock + thread-count + both-backends → Task 7.
- **The one thing most likely to go wrong:** Task 5's "no new `await`" constraint. `WorktreeRegistry.ensure`'s correctness depends on it. Step 3 of that task greps for it explicitly — do not skip it.
- **The one thing that could invalidate the design:** Task 7 Step 2's thread count. If it is ugly, the fallback is written down; take it rather than shipping and hoping.
