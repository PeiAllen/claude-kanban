# Nudge leak + cooperative-pool starvation

**Date:** 2026-07-11
**Branch:** `fix/nudge-leak-cooperative-pool-starvation`
**Status:** SHIPPED (scope narrowed — see "What actually happened", which corrects several claims below)

---

## What actually happened (read this first — it corrects the design)

The design below was written before implementation and **three of its claims turned out to be wrong**.
They are left in place rather than quietly edited, because the corrections are the interesting part.

**1. "The live-daemon wedge is the real bug; the test hang is a symptom." — FALSE.**
`orchestrad/main.swift:11` holds `service` in a top-level `let` (and `ControlServer`/`PushNotifier`
hold it too). It is created once and never released, so **the leak never multiplies in production** —
there is exactly one `OrchestraService`, forever. The leak is a **test-suite amplifier**: only under
`swift test --parallel`, where every test builds its own service, do the zombies pile up. `main` also
already carries a merged actor-hygiene body of work that applied `offActor` in 62 places, draining
production blocking down to a handful of sites. The demonstrated bug is the test wedge.

**2. The `DispatchSerialQueue` executor (Fix 2 below) does not compile on Linux.**
`SerialExecutor` conformance is Darwin-only; swift-corelibs-libdispatch has no `DispatchSerialQueue`.
`scripts/build-linux-daemon.sh:65` cross-builds `orchestrad` against the musl SDK, so Fix 2 as written
would have broken the Linux daemon at the next deploy — not in CI. A `#if canImport(Darwin)` gate is
the wrong answer: it leaves Linux carrying the bug. **The executor work is deferred to its own card**
with a hand-rolled portable `SerialExecutor`. It is hardening, not the fix.

**3. "Fixing this makes the suite terminate." — FALSE, and it was never achievable here.**
There are **two independent bugs**, and the starvation was masking the second. A/B against `main`
(c3eb421) confirms this fix works:

| wedged process | `main` | this branch |
|---|---|---|
| threads | 10 | **1** |
| cooperative-pool threads | 3 | **0** |
| `semaphore_wait_trap` | yes | **no** |
| `BranchLineage` / nudge frames | yes | **no** |

The starvation stack is gone. But the suite **still** wedges — idle, 0% CPU, no blocked threads —
on a set of lifecycle/convergence tests (`test_machineRebootPath`, `test_archiveDuringLaunching`,
`test_everyStepperConvergesFromAnyBoundary`, the readiness/wait suites). `main` hangs on 17 of them;
this branch on 15 — the same set. So bug #2 is **pre-existing and unrelated**. It is not starvation
(nothing is blocking); the remaining test tasks are suspended on something that never resumes. They
pass in isolation (32 tests, 8s, exit 0) and only hang under full `--parallel`. **The executor card
would not fix it either.** → its own card.

### What this card actually delivered
- The nudge + remote-watch leaks (both had the identical hoisted `guard let self`), with regression tests.
- The cooperative-pool starvation, gone — proven by A/B stack comparison, not asserted.
- Every unbounded `Proc` fork bounded, including `Proc.runStdoutToFile`, which had **no** bound at all.

---

## Summary

Two defects compose into a hard process-wide deadlock: a timer loop that never releases
`OrchestraService`, and actors that park Swift cooperative-pool threads on `git` subprocess forks.
Together they consume every thread in the cooperative pool, after which **no async task in the
process makes progress again**.

The reproduction is `swift test --parallel`, which wedges deterministically at ~975/1180 tests
(twice, same point, same stack) and never terminates. But the test hang is a *symptom*: `orchestrad`
runs the identical code and wedges the same way. **The live-daemon wedge is the real bug.**

This is the same failure class as the already-landed `fix(ui): stop live board updates silently
wedging + cut report-funnel actor contention` (07-10), at sites that fix did not reach.

## The bug

### Defect 1 — the nudge task pins the service forever

`Sources/OrchestraCore/OrchestraService+MergeRequest.swift:64-76`:

```swift
mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
    guard let self else { return }          // ← hoisted ABOVE the loop
    while !_Concurrency.Task.isCancelled {
        let interval = await self.mergeRequestNudgeInterval
        try? await _Concurrency.Task.sleep(for: interval)
        if _Concurrency.Task.isCancelled { return }
        if await self.reNudgeMergeRequest(childId) { break }
    }
    await self.clearMergeRequestNudge(childId)
}
```

`guard let self` sits *outside* the `while`, so the closure holds a **strong** reference for the
entire life of the loop. The `[weak self]` capture buys nothing. `OrchestraService` has no `deinit`
and no shutdown path, and the only cancellations are the re-arm on line 65 and
`stopMergeRequestNudge` for one specific child. Nothing cancels the `mergeRequestNudge` map when the
service goes away — and it *cannot* go away while a nudge runs.

Net effect: **any test that leaves a card in `.mergeRequested` leaks an immortal `OrchestraService`**
(plus its store, lineage, and inbox), running a git-forking loop for the rest of the process's life.

`startRemoteWatch` (`OrchestraService+Remote.swift:191-210`) has the **identical** hoisted
`guard let self`. A remote-parent watch loop leaks a service the same way. Found during this design;
not in the original report.

The one-shot debounces (`diffStatDebounce`, `treeStatDebounce`, `childFanoutDebounce`, the wake and
readiness timers) all use `self?.` and terminate on their own. They are clean.

### Defect 2 — actors block the cooperative pool on subprocess I/O

Swift's cooperative pool has roughly one thread per core and performs **no thread donation**. A
synchronous `Proc.run` parks the calling thread on an unbounded `DispatchSemaphore`
(`Proc.swift:83`, `exited.wait()`). An `actor` runs on that pool. Therefore every synchronous
`Proc.run` inside an actor method **consumes a cooperative-pool thread for the duration of the
fork**.

Three actors do exactly this:

| Actor | Forks | Timeout |
|---|---|---|
| `BranchLineage` | up to 4 sequential `git config` per `read()` | **none** |
| `RemoteParents` | `git fetch`, `git ls-remote` | 20s (`rev-parse` untimed) |
| `WorktreeRegistry` | `git worktree add` | **600s** |

A single `git worktree add` can pin a cooperative thread for ten minutes.

Each leaked `OrchestraService` owns its *own* `BranchLineage` instance, so leaked nudge loops block
in genuine parallel. Enough of them and the pool is fully consumed — every async task in the process
stops progressing, including swift-testing's own runner.

Sampled stack, both runs:

```
OrchestraService.startMergeRequestNudge → reNudgeMergeRequest
  → BranchLineage.read → BranchLineage.get → Proc.run → semaphore_wait_trap
```

## Design

### The constraint that shapes the fix

The obvious fix — make each actor `await` its forks off-actor via the existing PR5 `offActor` seam —
**is wrong here**, because these actors' synchronous bodies are load-bearing.

`WorktreeRegistry.ensure` says so explicitly:

> Serialized by the actor mailbox. NO `await` between the marker check and the checkout, so two
> concurrent same-branch calls run one-at-a-time and `git worktree add` fires once.

`BranchLineage.set` has the same shape: a read-modify-write with a rollback path, correct only
because nothing can interleave. Introducing an `await` inside either method introduces actor
reentrancy and reopens a concurrent-spawn race and a torn-parent-link write.

So: **do not move the blocking work off the actor — move the actor off the cooperative pool.**

### Fix 1 — genuinely weak timer loops + real teardown

Re-acquire `self` per call rather than once for the loop's lifetime, so nothing is retained across
the sleep:

```swift
mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
    while !_Concurrency.Task.isCancelled {
        guard let interval = await self?.mergeRequestNudgeInterval else { return }
        try? await _Concurrency.Task.sleep(for: interval)
        if _Concurrency.Task.isCancelled { return }
        guard let stop = await self?.reNudgeMergeRequest(childId) else { return }
        if stop { break }
    }
    await self?.clearMergeRequestNudge(childId)
}
```

Each `self?.` optional-chained call takes a temporary strong reference only for the duration of that
call. The sleep — the overwhelming majority of the loop's wall-clock — holds nothing. Once the
service deallocates, the next hop yields `nil` and the loop exits. Applied identically to
`startRemoteWatch`.

Add an explicit teardown:

- `OrchestraService.shutdown()` — cancels every task registry (`mergeRequestNudge`, `remoteWatch`,
  `diffStatDebounce`, `treeStatDebounce`, `childFanoutDebounce`).
- `deinit` — cancels the same registries as a backstop. Note the weak-self fix is what makes `deinit`
  *reachable at all*; today it could never run.
- Wire `shutdown()` into `orchestrad`'s SIGTERM handler alongside `flushBeforeShutdown()`.

### Fix 2 — custom serial executor on the fork-blocking actors

Give `BranchLineage`, `RemoteParents`, and `WorktreeRegistry` a `DispatchSerialQueue`-backed
executor (macOS 14+ / Swift 6; `DispatchSerialQueue` conforms to `SerialExecutor`):

```swift
public actor BranchLineage {
    private let queue = DispatchSerialQueue(label: "orchestra.lineage")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}
```

The blocking `Proc.run` calls stay exactly where they are. They now park a **GCD** thread rather than
a cooperative-pool thread. Consequences:

- **Starvation becomes structurally impossible**: a fork can never touch the cooperative pool.
- **Serialization semantics are unchanged**: the actor is still a serial executor, so the mailbox
  still serializes calls one-at-a-time. Every documented invariant holds verbatim.
- **Reentrancy is unchanged**: no new suspension points are introduced.
- **Zero call-site churn**: `await lineage.read(…)` etc. are untouched.

This is the same principle as PR5's `offActor` (keep blocking work off the pool), applied at the
actor boundary instead of the call site — which is what these three actors need, since their
exclusion is load-bearing and `offActor` would dissolve it.

Cost: each of the three actors holds a GCD thread while forking. That is bounded (one per actor
instance, serial) and is precisely what GCD threads are for.

### Fix 3 — bound the git calls

- `BranchLineage` gets an injectable timed `run` seam, mirroring the one `WorktreeManager` already
  has:
  ```swift
  let run: @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult
  ```
  `timeout` is a **required** `Duration`, so an unbounded git call in this file is a compile error.
  This bounds the forks *and* gives tests a blocking-git seam.
- `RemoteParents.fetch`'s untimed `rev-parse` gets the same 20s bound its siblings already carry.
- `Proc.run` gains a bounded **default** timeout (120s); `nil` becomes an explicit opt-out for the
  rare site that genuinely needs to run unbounded. The ~30 call sites currently relying on the
  unbounded default are audited; any that can legitimately exceed 120s (they already pass explicit
  timeouts — e.g. `worktreeAddTimeout` = 600s) are confirmed unaffected.

Defence in depth: the executor fix means a stuck fork cannot starve the pool, and the timeout means a
stuck fork cannot hang *at all*. Either alone would fix the reproduction; both together close the
class.

## Testing

Regression tests must **fail on the current code** and pass after.

1. **Leak** — arm a card in `.mergeRequested`, drop the last strong reference to the service, assert a
   `weak var` reference to it goes `nil` within a bounded wait. Fails today: the nudge Task pins it.
2. **Teardown** — after `shutdown()`, no nudge or watch task survives (`mergeRequestNudgeActive` is
   false for every card; the registries are empty).
3. **Starvation** — more than `ProcessInfo.activeProcessorCount` `BranchLineage` instances, each
   parked inside a blocking injected `run`, while an unrelated `Task` must still make progress within
   a bounded time. Today this deadlocks the cooperative pool; with the executor fix it cannot.
4. **Sibling leak** — the same leak assertion for `startRemoteWatch`.

Acceptance (definition of done):

- **The full `swift test` suite runs to completion and reports a result.** Today it does not, so
  "tests pass" is not a meaningful claim until the suite terminates. Wall-clock time is measured and
  reported.
- **Peak thread count during the parallel suite is measured and reported.** The falsification check
  for the executor design (see "Cost of the executor fix", consequence 3).
- Verified against **both agent backends** (claude + codex) per `CLAUDE.md`. The nudge path is
  agent-agnostic; this confirms nothing regressed.

## Cost of the executor fix — read this before calling it free

The serial-executor fix trades a **deadlock** for **bounded degradation**. The cooperative pool cannot
grow, so blocking it wedges the process permanently. GCD overcommits, so blocking a serial queue just
uses a thread — and if you use too many, you get thread explosion (memory per thread, scheduler
thrash, a ceiling around 64 per QoS class). That is bad, but it recovers, and it does not take every
unrelated task in the process down with it.

It is cheap here **because the instance count is bounded**: production has exactly one
`OrchestraService`, hence exactly one `BranchLineage`, one `RemoteParents`, one `WorktreeRegistry`.
Three serial queues, for the life of the daemon. Custom executors are *not* free in general — spraying
them across per-request actors would reinvent thread explosion.

**This is why Fix 1 (the leak) is primary and Fix 2 (the executor) is defence-in-depth, not the
reverse.** With the leak still present, hundreds of zombie `BranchLineage` actors would each bring
their own serial queue, all blocking — trading a cooperative-pool deadlock for GCD thread explosion,
arguably worse because there is no clean deadlock to catch it. The two fixes only work together.

Minor costs accepted: hopping to a GCD queue is a slightly more expensive context switch than staying
on the cooperative pool, and a custom executor loses automatic `Task` priority propagation (the
queue's QoS applies instead). Both are noise next to a call that forks `git`. What *is* preserved
bit-for-bit is serialization and reentrancy — the mailbox still runs one call at a time, so the
no-`await`-between-check-and-checkout invariants hold.

### Consequences of the above (binding on the plan)

1. **The two fixes ship together, leak first.** Fix 1 and Fix 2 are NOT independent, and the executor
   fix must never be cherry-picked alone. This is an ordering constraint on the plan, not a
   preference.
2. **"Only three instances exist" is an invariant to defend.** A comment at each executor site states
   that the custom executor is safe *because* the actor is per-daemon — and that attaching one to a
   per-request actor would reinvent thread explosion. Without that note, "starvation impossible" is
   the sentence that gets copy-pasted six months from now.
3. **Thread count is measured, not assumed.** Under `swift test --parallel` many services are alive at
   once, each now carrying three serial queues. The full-suite run therefore samples peak thread count
   as well as wall-clock. **This is the observation that can still falsify the design** — if the
   parallel suite drives GCD thread count somewhere ugly, the design is wrong and a number should say
   so, not a hand-wave.

**Open sub-decision, settled by measurement:** per-instance queue vs. one shared static queue per
actor *type*. Production is identical either way (one instance of each). It only bites in the parallel
test suite. **Decision: per-instance, then measure (consequence 3).** If measurement shows explosion,
fall back to a shared queue for `BranchLineage` and `RemoteParents` — but *not* `WorktreeRegistry`, a
shared queue there would serialize every test's `git worktree add` and make an already-slow suite far
slower.

## Explicitly out of scope

Deliberately excluded to keep the diff reviewable and focused on the reproduced wedge:

- **Backoff / give-up cap for the re-nudge loop.** The loop re-prods the parent every 300s forever,
  with no limit. Worth fixing — a parent that ignored 50 reminders will not act on the 51st — but it
  is a product/UX concern, **not** a fix for this bug. Backoff would merely *dilute* the starvation:
  fewer concurrent forks, so the deterministic deadlock becomes a rare intermittent one. That is
  strictly worse, because the reproducibility is what let us find it. → card
  `feat/merge-request-nudge-backoff`, stacked on this branch.
- **Test-suite git hermeticity.** `Tests/` has no `HOME` / `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_NOSYSTEM`
  isolation, so all ~116 real-`git` forks read the developer's personal `~/.gitconfig` — invoking
  `credential.helper = osxkeychain`, which the Claude Code sandbox denies. The suite's existing guard
  `RemoteParents.remoteEnv()` (`GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS=/usr/bin/false`) is applied at
  only 3 call sites and does **not** disable the credential helper — only `-c credential.helper=`
  does. → card `test/git-hermeticity`.
- **Suite slowness** (12k-file slow-repo fixture, per-test tmux servers, per-test git repos, 73
  hardcoded sleeps). Orthogonal to termination. → **separate card.**
- **Blocking *file* I/O actors** (`TaskStore`, `Inbox`, `TrustLedger`, `RolloutTailer`). Same class,
  but local file writes are milliseconds rather than multi-second forks and cannot realistically
  starve the pool. → **follow-up audit.**

---

# Postscript (2026-07-12): Fix 2 (the serial executor) was MEASURED AND DECLINED

Card `harden/serial-executor-forking-actors` was cut to implement Fix 2 above — give `BranchLineage`,
`RemoteParents` and `WorktreeRegistry` a hand-rolled portable `SerialExecutor` so their `git` forks
park a GCD thread instead of a cooperative-pool thread. **It was not built. The measurement says the
hazard cannot get large.** This section records why, so nobody re-derives it.

## The ceiling nobody computed

Fix 2's premise is "enough concurrent forks park enough pool threads to exhaust the pool." Count the
forks that can actually be in flight at once:

**These three types are `actor`s, so each is SERIAL.** One `BranchLineage` can have at most **one**
`git config` running. One `RemoteParents`, one `git fetch`. One `WorktreeRegistry`, one
`git worktree add`. And production holds exactly one of each, because it holds exactly one
`OrchestraService` (`orchestrad/main.swift:11`, a top-level `let` that never releases).

> **Production can therefore park at most THREE cooperative-pool threads. Ever. By construction.**

Starvation needs ≈ `activeProcessorCount`. On the dev Mac that is 18. On the remote Linux box
(`scripts/build-linux-daemon.sh` — the deployment that *would* be the strongest case for the executor,
since a small pool is easier to exhaust) the owner confirms the box is generously provisioned. A
ceiling of 3 is not close to 18 on any machine this project targets. **The wedge requires a ≤3-core
host, which is not a deployment this project has.**

## The one place the ceiling does NOT hold — and the measurement there

The "one instance of each" invariant is a *production* invariant. **The test suite violates it**:
every test constructs its own `OrchestraService`, so hundreds of these actors coexist, and
`swift test --parallel` runs swift-testing's cases as Tasks *on the same cooperative pool they would
starve*. If the hazard is real anywhere, it is real there. So it was measured there, not argued.

Method (`scripts/pool-probe.sh`): run the in-process swift-testing phase under full `--parallel` load
and sample the helper process throughout, classifying every thread as *cooperative* (its `sample`
thread header names `com.apple.root.<qos>.cooperative`) and *blocked* (`semaphore_wait_trap` —
`Proc.run`'s `exited.wait()`). A thread that is **both** is the bug.

| | |
|---|---|
| pool width (`hw.activecpu`) | **18** |
| tests executed under load | 1060 |
| samples across the load window | 73 |
| peak cooperative threads in use | 20 |
| peak *total* threads | 67 |
| **peak PARKED cooperative threads** | **1** |
| samples with ≥ 1 parked | **1 of 73** (mean 0.01) |

**Peak 1 of 18.** Not 18, not 9 — one, once. Starvation is two orders of magnitude away, and the gap
is *structural*, not lucky: a serial actor cannot fork in parallel with itself, and `git config` calls
finish faster than the next one arrives.

## The mechanism is real — it just cannot scale

This is not a "couldn't reproduce it" result. The single parked sample captured **exactly** the stack
the design predicted:

```
BranchLineage.read   (BranchLineage.swift:57)
  → BranchLineage.get (BranchLineage.swift:33)
    → Proc.run        (Proc.swift:82)          ← semaphore_wait_trap
```

The design was right about the *mechanism* and wrong about the *magnitude* — because it reasoned about
a world with leaked zombie services, each bringing its own `BranchLineage` and all forking in genuine
parallel. **Fix 1 deleted that world.** Once the leak is gone, the serial-actor ceiling binds, and the
executor defends a number that cannot grow.

## What the executor would have cost

Not free, and worth naming since "it's only 40 lines" was the pitch:

- A hand-rolled `SerialExecutor` — `DispatchSerialQueue`'s `SerialExecutor` conformance is a **Darwin
  overlay**; swift-corelibs-libdispatch has none. The obvious implementation compiles on macOS and
  **breaks `orchestrad` on Linux at deploy time, not in CI.**
- Trading a *deadlock* for *unbounded GCD thread growth*. Cheap only while the instance count is
  bounded — the exact invariant that also makes the executor unnecessary. **Both arguments live and
  die together.**
- A permanent "do not copy-paste this onto a per-request actor" comment at three sites, forever.

## What would flip this decision

Re-open the card if **either** becomes true:

1. **A small deployment target appears** — a ≤3-core Linux VM, or a cpuset-pinned container. Then the
   pool is narrower than the fork ceiling and the wedge is live.
2. **The instance count stops being bounded** — anything that creates `OrchestraService`, or these
   three actors, per-request/per-connection (a multi-tenant daemon). Note this cuts *both* ways: it
   would make the executor necessary **and** make a per-instance queue dangerous (thread explosion).
   That variant needs a shared static queue per actor *type*, not per instance.

A third, weaker trigger: if a fork under one of these actors starts routinely blocking for *minutes*
(a `git worktree add` on a huge repo genuinely hitting its 600s bound), the ceiling of 3 stops being
harmless even at width 18 — 3 threads gone for ten minutes is a real capacity dent, though still not a
wedge.

## Reusable artifact

`scripts/pool-probe.sh` measures peak cooperative-pool starvation in any `swift test --parallel` run.
Three traps it already encodes, all of which cost real time to learn:

- **A cooperative thread is identified by its `sample` THREAD HEADER** (`…-qos.cooperative`), *not* by
  a `swift_job_run` frame. Keying on frame names reports a clean `parked=0` **on a process that is
  provably 100% starved.** The script ships with a positive control (`scripts/pool-probe-control`) that parks
  every pool thread; a classifier that does not light up there is lying.
- **`swift-test` and `swiftpm-testing-helper` each `setpgrp` into their own process group**, so
  `kill -PGID` misses them. A survivor holds the SwiftPM **`.build` lock** and the next run blocks on
  it forever. The script reaps its runner's descendant tree by PID and verifies.
- **Never pattern-kill** (`pkill -f swift-test`): other agents run the suite concurrently on this
  machine, and a name match kills *their* run.
