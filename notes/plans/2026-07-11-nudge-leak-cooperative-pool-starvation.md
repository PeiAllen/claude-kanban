# Nudge leak → test-suite wedge — Implementation Plan (SCOPED)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `swift test` terminate. It currently wedges at ~975/1180 and never exits.

**Scope:** Narrowed by Allen after the plan review (see "What changed and why" below). **The `SerialExecutor` work is NOT in this card** — it is hardening, it is Darwin-only as originally written, and it is now a separate card. This card fixes the *amplifier*: the leak, plus the unbounded forks.

**Architecture:** `startMergeRequestNudge` and `startRemoteWatch` hoist `guard let self` **above** their `while`, so `[weak self]` buys nothing and every armed loop pins an immortal `OrchestraService`. Under `swift test --parallel` each test builds its own service, so the zombies pile up — each one still running a periodic loop that forks `git` synchronously on a Swift cooperative-pool thread (~1/core, no growth). Enough of them and every async task in the process stops, including the test runner. Move the `guard` inside the loop and the pile-up cannot form.

## What changed and why (post-review)

Two reviewers (Claude Opus 4.8 + GPT-5.6 Terra, read-only, pinned at `2ee80b7`) confirmed the diagnosis and the invariants, and produced two findings that reshaped the card:

1. **`DispatchSerialQueue` has no `SerialExecutor` conformance on Linux** (swift-corelibs-libdispatch lacks it), and `scripts/build-linux-daemon.sh:65` cross-builds `orchestrad` against the musl SDK. The original Task 4/5 would have broken the Linux daemon build at the next deploy, not in CI. `#if canImport(Darwin)` is rejected — it would leave Linux carrying the bug.
2. **In production the leak never multiplies.** `orchestrad/main.swift:11` holds `service` in a top-level `let` (and `ControlServer`/`PushNotifier` hold it too) — it is created once and never released. So the leak is a **test-suite amplifier**, not a daemon-wedge mechanism. `main` also already carries a merged actor-hygiene body of work that applied `offActor` in 62 places, draining production blocking down to a handful of sites. The demonstrated bug is the test wedge.

**Hypothesis to state explicitly in the writeup:** the leak fix alone may unwedge the suite, because without immortal services there is no pile-up of periodic forkers. If it does — say so, with evidence. If it does not, report what is still parking threads. **Do not silently escalate into the executor work.**

## Global Constraints

- **No `SerialExecutor`, no executor work, no new actor plumbing.** Small, portable, reviewable.
- **`Proc.checked` is NOT dead code** — 57 call sites in `Tests/`. Do not remove it. (An earlier claim that it had zero callers came from grepping `Sources/` only. It was wrong.)
- **No workarounds for the hang** — no `--skip` regexes, no `pkill` preambles. Fix it. (Wedge containment — timeout + process-group reaping in `scripts/test.sh` — is card `test/hang-containment`, not this one.)
- **Out of scope:** the `SerialExecutor` hardening (own card); suite slowness; git hermeticity (`test/git-hermeticity`); re-nudge backoff (`feat/merge-request-nudge-backoff`).

---

## Task 1: The merge-request nudge loop must not pin the service

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+MergeRequest.swift:64-76`
- Test: `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` (create)

- [ ] **Step 1: Write the failing test**

The weak reference is held in a **box**, not a bare `weak var` captured by an escaping closure — a mutable local captured into an async context is a Swift 6 strict-concurrency diagnostic waiting to happen (reviewer m4).

```swift
import Foundation
import Testing
@testable import OrchestraCore

/// The nudge/watch loops hoisted `guard let self` ABOVE their `while`, so `[weak self]` bought
/// nothing: an armed loop held a STRONG reference and pinned `OrchestraService` (plus its store,
/// lineage and inbox) for the life of the process. Under `swift test --parallel` every test builds
/// its own service, so the zombies piled up — each still forking `git` on a cooperative-pool thread
/// (~1/core, no growth) until the pool was gone and nothing async progressed again, test runner
/// included. In production the daemon holds one service forever, so the leak never multiplied there:
/// this is a test-suite amplifier, and it is what wedged the suite at ~975/1180.
@Suite("service teardown — long-lived loops must not pin the service")
struct ServiceTeardownTests {

    /// Box so the weak ref is never a mutable local captured into an escaping/async context.
    final class WeakBox: @unchecked Sendable { weak var svc: OrchestraService? }

    /// Deallocation is not synchronous with the last release — the loop must first hop, observe nil,
    /// and unwind — so poll. The bound is generous because a loop cancelled mid-`Proc.run` holds a
    /// transient strong ref until that fork returns (RemoteParents bounds its forks at 20s).
    private func awaitDeallocated(_ box: WeakBox, within: Duration = .seconds(30)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if box.svc == nil { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        }
        return box.svc == nil
    }

    @Test("an armed merge-request nudge does not pin the service")
    func nudgeDoesNotPinService() async throws {
        let box = WeakBox()

        // Scope the ONLY strong reference so it drops at the end of this block. A long interval parks
        // the loop in its sleep holding NOTHING — exactly the state that used to hold `self` strongly.
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
            box.svc = env.svc
        }

        #expect(await awaitDeallocated(box),
                "an armed merge-request nudge pinned OrchestraService — the loop is not genuinely weak")
    }
}
```

- [ ] **Step 2: Run it and verify it FAILS**

`swift test --filter ServiceTeardownTests` → FAIL: `an armed merge-request nudge pinned OrchestraService`.

If it PASSES, stop — the test is not measuring what it claims.

- [ ] **Step 3: Make the loop genuinely weak**

`OrchestraService+MergeRequest.swift`, replace `startMergeRequestNudge`'s Task body:

```swift
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        // `self` is re-acquired PER HOP, never hoisted above the loop. A hoisted `guard let self`
        // holds a strong ref for the loop's entire life — including the sleep, which is ~all of it —
        // so `[weak self]` would buy nothing and the service could never deallocate. Optional-chaining
        // each hop takes a temporary strong ref only for that call; once the service is gone the next
        // hop yields nil and the loop unwinds.
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

- [ ] **Step 4: Verify** — `swift test --filter 'ServiceTeardownTests|MergeRequestTests|RebuildMergeRequestNudgesTests'` → PASS, with the two existing suites unchanged and green (observable behaviour — cadence, stop conditions, `mergeRequestNudgeActive` — is identical; only retain semantics changed).

- [ ] **Step 5: Commit**

---

## Task 2: The remote-watch loop has the identical bug

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift:191-210`
- Test: `Tests/OrchestraCoreTests/ServiceTeardownTests.swift` (extend)

**The test needs a latch.** Both reviewers flagged this independently. The loop is `shouldStop → remoteMergeStep → sleep` — **sleep is LAST**. So a long interval does *not* park the loop on re-arm: it immediately runs a real `git fetch`/`ls-remote` (up to 20s), and under the rewrite `await self?.remoteMergeStep(…)` holds a transient strong ref for that whole call. Dropping the last strong ref during that window makes the test flake red *after* the fix. It must wait until the loop has actually reached its sleep.

- [ ] **Step 1: Add a DEBUG-only sleep probe to the loop**

In `OrchestraService.swift`, with the other test-support state:

```swift
    #if DEBUG
    /// Fired by the remote-watch loop immediately before it sleeps. Lets a test wait until the loop is
    /// genuinely parked (holding no strong ref) before dropping its last reference to the service —
    /// without which the leak test races the loop's in-flight `git fetch`. nil in production.
    var remoteWatchSleepProbe: (@Sendable () -> Void)?
    func _setRemoteWatchSleepProbeForTest(_ p: (@Sendable () -> Void)?) { remoteWatchSleepProbe = p }
    #endif
```

- [ ] **Step 2: Write the failing test**

```swift
    @Test("an armed remote watch does not pin the service")
    func remoteWatchDoesNotPinService() async throws {
        let box = WeakBox()
        let parked = DispatchSemaphore(value: 0)

        do {
            let (svc, _, card) = try await RemoteWatchLoopTests.remoteChild()
            // Long intervals so that once parked, the loop stays parked for the test's duration.
            await svc.setRemoteWatchIntervals(active: .seconds(3600), idle: .seconds(3600))
            await svc._setRemoteWatchSleepProbeForTest { parked.signal() }
            await svc.startRemoteWatch(cardId: card.id)
            #expect(await svc.remoteWatchActive(card.id))

            // Wait until the loop has finished its git work and reached the sleep — i.e. holds nothing.
            #expect(parked.wait(timeout: .now() + 60) == .success, "remote watch never reached its sleep")
            box.svc = svc
        }

        #expect(await awaitDeallocated(box),
                "an armed remote watch pinned OrchestraService — the loop is not genuinely weak")
    }
```

- [ ] **Step 3: Verify it FAILS** — `an armed remote watch pinned OrchestraService`.

- [ ] **Step 4: Make the loop genuinely weak (generation token untouched)**

`OrchestraService+Remote.swift`, replace the Task body inside `startRemoteWatch`. Keep `gen` exactly as-is — it guards a restart race and is orthogonal:

```swift
        remoteWatch[cardId] = _Concurrency.Task { [weak self] in
            // `self` re-acquired PER HOP — see the note on `startMergeRequestNudge`.
            while !_Concurrency.Task.isCancelled {
                guard let stop = await self?.shouldStopRemoteWatch(cardId) else { return }
                if stop { break }
                guard let outcome = await self?.remoteMergeStep(cardId: cardId) else { return }
                guard let delay = await self?.remoteWatchDelay(after: outcome) else { return }
                try? await _Concurrency.Task.sleep(for: delay)
            }
            await self?.clearRemoteWatch(cardId, gen: gen)
        }
```

and add, next to `shouldStopRemoteWatch`:

```swift
    /// The next poll delay: `active` right after the tip moved (poll faster while the parent churns),
    /// `idle` otherwise. Also the loop's "about to sleep" point — see `remoteWatchSleepProbe`.
    func remoteWatchDelay(after outcome: RemoteMergeOutcome) -> Duration {
        let (active, idle) = remoteWatchIntervals
        #if DEBUG
        remoteWatchSleepProbe?()
        #endif
        return (outcome == .fetched) ? active : idle
    }
```

(Check `remoteMergeStep`'s real return type and use it — the plan calls it `RemoteMergeOutcome`; use whatever the source says.)

- [ ] **Step 5: Verify** — `swift test --filter 'ServiceTeardownTests|RemoteWatchLoopTests|SetParentRemoteTests'` → PASS. `RemoteWatchLoopTests.restartThenStopIsInactive` (the generation-token race) must stay green.

- [ ] **Step 6: Commit**

---

## Task 3: No fork runs unbounded

**Files:** `Sources/OrchestraCore/Proc.swift`

- [ ] **Step 1: Bound `Proc.run`'s default**

```swift
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

- [ ] **Step 2: Bound `Proc.runStdoutToFile`** (`Proc.swift:142`) — still `p.waitUntilExit()` with no timeout. Reachable from `Launcher.swift:210` (`git show <base>:<path>`, once per changed file, for Zed's diff view). Give it the same defaulted `timeout` and terminate/kill on expiry, mirroring `run`'s escalation.

- [ ] **Step 3: Audit every remaining default caller**

```bash
grep -rn 'Proc\.run(' Sources/ | grep -v 'timeout:'
```

Note the grep yields **false positives** on multi-line calls (`RemoteParents.swift:32`, `OrchestraService.swift:1076`, `RepoScanner.swift:96` all pass a timeout on the following line) — check each hit in context. Reviewers independently re-audited every real call site in `Sources/`: **none can legitimately exceed 120s.** Also inherits: `Proc.checked` (57 `Tests/` call sites; the slowest is a worktree add, worst known ≈9s) and `Proc.toolExists` (`which`).

- [ ] **Step 4: Build + commit** — `swift build`, then the timeout suites.

---

## Task 4: Prove the suite terminates

This is the acceptance test and the entire point of the card.

- [ ] **Step 1: Run the full suite to completion, timed, with a real exit code**

SwiftPM's own `sandbox-exec` fails inside the Claude sandbox — run unsandboxed. Do **not** background it and poll; run it in the foreground with a generous timeout so a wedge surfaces as a timeout rather than an orphan.

```bash
time swift test --parallel 2>&1 | tail -40; echo "EXIT: ${PIPESTATUS[0]}"
```

Expected: it **terminates** and reports a result. Record the wall-clock and the exit code.

- [ ] **Step 2: Report the hypothesis result honestly**

State in the writeup whether the leak fix **alone** unwedged the suite.
- If yes: say so with evidence (before: ~975/1180 then silent forever; after: N tests, exit code, wall-clock).
- If no: report **what is still parking threads** — `sample` the helper once it goes quiet and give the stack. **Do not escalate into the executor work**; hand that evidence to the step-2 card.

- [ ] **Step 3: Verify both agent backends (CLAUDE.md)** — the nudge path is agent-agnostic, but confirm nothing regressed:
`swift test --filter 'CodexAdapterTests|CodexRolloutTests|CodexWakeTests|AdapterTests|AdapterEncodeTests'`

- [ ] **Step 4: Spawn the step-2 card** (`SerialExecutor` hardening) — seeded per the brief: hand-rolled portable executor, verified by actually running `scripts/build-linux-daemon.sh`; and it must argue explicitly why the cheaper `offActor` reuse is **wrong** (it introduces an `await` into `WorktreeRegistry.ensure`, breaking its documented no-suspension-point-between-marker-check-and-checkout invariant, so `git worktree add` could fire twice). Carry over that a low-core Linux VM is where 4 parked threads could genuinely starve the pool — the strongest remaining case for doing it at all.
