# Bug #2 — the `--parallel` suite hang: a stale bring-up resurrects a live session

**Date:** 2026-07-11
**Branch:** `fix/suite-hang-lifecycle-tests`
**Status:** fixed
**Predecessor:** `2026-07-11-nudge-leak-cooperative-pool-starvation.md` (bug #1 — starvation; it was
*masking* this one)

---

## The symptom, and why every obvious reading of it was wrong

`swift test --parallel` got ~900 tests in and then went silent forever: **0% CPU, one main thread,
nothing blocking**. Roughly 15 tests were reported "started" and never finished.

Three plausible readings, all refuted by evidence before any code was touched:

1. **"The cooperative pool is dead / starved."** No. `swift-inspect dump-concurrency` on the wedged
   process, taken twice a few minutes apart, showed four tasks *completing* between the two dumps (the
   `awaitReadiness` grace timers). `Task.sleep` fires; the executor is healthy.
2. **"`awaitReadiness` leaks a continuation."** No. It is bounded by a `timeoutReadiness` timer that
   always fires. It was the prime suspect and it is innocent.
3. **"Fifteen tests are hung."** No. **Exactly one** is. The runner's task tree bottoms out at a single
   leaf; no other test has a live task. The other ~15 had *finished* — their result lines were still
   sitting in the helper's **block-buffered stdout** (its stdout is a file, not a tty), which is why the
   log ends mid-line. A buffering artifact, not fifteen hangs.

The one real leaf:

```
Task 1 (runner root) → … → Task 4370  WakeMergeWatchTests.crashConcludesWait()   ← awaiting Task.value
                              → Task 6720  OrchestraService.wait(watcher:refs:)
                                            → MergeWatch.awaitConclusion  ← parked forever
```

## The root cause

`wait` is the only **unbounded** park in the product — no timeout, by design. It resolves when the
watched child *concludes*. The child never concluded, because **the child never died**.

Instrumenting the real wedged run (stderr, unbuffered, so it survives the wedge) gave the mechanism
directly:

```
FL ensure card=X phaseAtDispatch=launching phaseNow=launching   ← the genuine launch
MW wait ENTER / SUBSCRIBE                                        ← the test's wait subscribes
FL ensure card=X phaseAtDispatch=live      phaseNow=live         ← a SECOND bring-up, on an already-.live card
CSS card=X phase=live state=alive                                ← liveness sees the RESURRECTED session
```

A phase step is dispatched off a **snapshot** (`stepIfEligible` → unstructured `Task` → `runStep`) and
runs asynchronously. By the time a `LaunchStepper` step reached `finishLaunch`, the card had already
been landed `.live` by someone else — the reconciler's **adopt** path (a `.launching` card whose session
is up at the matching epoch), or `report()`'s SessionStart(clear/resume), which writes `.live` directly.

`finishLaunch`'s bring-up is **`kill` + `ensure`**. Unfenced, the stale step therefore tore down the live
session and created a fresh one. In the suite it re-created the session the test had *just* killed, so:

- `confirmSpawnStartup` probed the pane, saw `alive`, and took the "still starting / graduate" path
  instead of `.gone` → **no `markDead`**;
- no death → no `concludeCard` → no `mergeWatch.conclude`;
- the `wait` parked on that child suspended **forever**, and with it the whole runner tree.

It is load-dependent only because the adopt-vs-step interleave needs the step to lag — which is exactly
what a saturated cooperative pool under `--parallel` produces. In isolation the step always wins its own
race, so the tests pass.

**This is not a test bug.** In production the same stale step kills a live agent's tmux session and
relaunches it blank — losing a running agent's session. The hang was the loud symptom of a quiet
data-loss bug.

## The fix

Two changes, both in the convergence machinery, agent-agnostic (no adapter branches):

1. **Fence the bring-up on its dispatched phase + generation.**
   `finishLaunch(_:flavor:expecting:epoch:)` re-reads the card and returns `.superseded` — *before any
   `kill`/`ensure`* — if the card has left the phase the step was dispatched for, or its `sessionEpoch`
   has moved. The steppers already treat `.superseded` as "stand down", so nothing else changed. This is
   the single-winner discipline the funnel already applies to *phase writes*, extended to the *side
   effects*, which is where it was missing.

2. **Close the adopt window.** `reconcile`'s `bringingUp` test now includes `inFlightSteps`, not just
   `readinessWaiters`. A step registers its readiness waiter only *after* its off-actor `kill`+`ensure`
   returns; in that gap a waiter-only check reads "nobody is bringing this card up" while its session is
   already up, so adopt would land it `.live` out from under its own in-flight step. Taking the step's
   own claim removes the double-drive at the source. (1) alone fixes the hang; (2) stops the race from
   being run in the first place.

## Regression tests

`StepperTests.swift` → `StaleBringUpFenceTests`, both parameterized over **claude-code and codex**:

- a bring-up whose card already left `.launching` stands down: `.superseded`, the vanished session is
  **not** resurrected, and the liveness pass therefore concludes the card `.dead(.sessionVanished)`;
- a bring-up from a superseded **generation** stands down.

Verified RED against the unfenced code — without the fence the session comes back alive and the card
sits `.live(.running)`, which is precisely the wedge.

## Leftover, deliberately not bundled

`OrchestraService.wait` reads card state and *then* subscribes to `MergeWatch`, with two actor hops in
between, while `watch` registers first. A conclusion landing in that gap reaches zero subscribers and is
dropped (`MergeWatch` keeps no memory of it, unlike readiness's `pendingReadiness`), and the waiter would
park forever. This was **not** the cause of this hang — the traced runs show no such drop — but it is a
real latent lost-wakeup on an unbounded park, and `wait` having no timeout means it is unrecoverable when
it does fire. Worth its own card: subscribe-before-read makes it airtight, because `transition` writes the
terminal phase to the store *before* it calls `concludeCard`.
