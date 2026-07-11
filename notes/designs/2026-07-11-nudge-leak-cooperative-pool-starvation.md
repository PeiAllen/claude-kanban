# Nudge leak + cooperative-pool starvation

**Date:** 2026-07-11
**Branch:** `fix/nudge-leak-cooperative-pool-starvation`
**Status:** design approved, ready to plan

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
