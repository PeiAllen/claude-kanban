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

Three changes, all in the convergence machinery, agent-agnostic (no adapter branches).

**The invariant:** *while a bring-up step owns a card, nothing else may land that card `.live`.*
`inFlightSteps` is the ownership token — it is taken synchronously in `stepIfEligible`, before the step is
dispatched, and held across the step's off-actor `kill`+`ensure`.

An entry-only fence is **not** enough, and the first cut of this fix had exactly that hole (caught in
review): `finishLaunch` suspends at `resolveTrust` and `prepareToLaunch` between the fence and the
destructive hop, so a same-epoch `.live` landing — `report()`'s SessionStart(clear/resume), a re-title
prompt, or a rollout snapshot — could slip in *after* the fence passed. The step would then still believe it
owned a being-born card and kill the live session anyway. Hence (3): the claim gates the *other* writers,
which is what makes the entry fence sufficient.


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
   own claim removes the double-drive at the source.

3. **A report may not land a card `.live` under an in-flight bring-up.** `report()` has four direct `.live`
   writes (SessionStart clear/resume, the re-title prompt, the snapshot run-state); each is now gated on the
   claim. Only the *phase* write is suppressed — every other field (session id, title, desc, model, ctx)
   still applies, and the readiness signals (`resolveReadiness`) still fire, so the in-flight step confirms
   and lands `.live` itself through the funnel with the landing its flavor derives. Terminal writes
   (SessionEnd death, turn completion) are deliberately **not** gated: a card that genuinely died must still
   die, and the step's own `kill` is then harmless. This closes the window (1) alone leaves open.

## Regression tests

`StepperTests.swift` → `StaleBringUpFenceTests`, both parameterized over **claude-code and codex**:

- a bring-up whose card already left `.launching` stands down: `.superseded`, the vanished session is
  **not** resurrected, and the liveness pass therefore concludes the card `.dead(.sessionVanished)`;
- a bring-up from a superseded **generation** stands down;
- a **report cannot steal the landing** from an in-flight bring-up (the window the entry fence leaves open);
- **adopt does not race an in-flight step**.

Each verified RED against the un-fixed code — without the fence the session comes back alive and the card
sits `.live(.running)`, which is precisely the wedge; without the report gate the card lands `.live` under
the step.

## What the review pass changed (Claude + Codex, bounded pair)

Both reviewers converged on the same structural criticism, and it was right: **the fence was a check, not a
lease.** It is checked once on entry, but `finishLaunch` cannot hold the actor across its off-actor
`kill`+`ensure`, so the card can be taken away in between. Four concrete holes, all now closed and each with
a regression test verified RED against the un-fixed code:

1. **A report could steal the landing** (Codex, BLOCKER). `report()` has four direct `.live` writes; any of
   them landing at the same epoch after the entry fence passed would leave the step believing it still owned
   a being-born card, and it would kill the live session anyway. → the claim now gates them (change 3 above).
2. **The `kill`+`ensure` could land under a card that went terminal** (Claude, MAJOR). The launch-timeout
   `markDead` runs *outside* the `bringingUp` gate — deliberately, since it is what keeps a wedged bring-up
   converging — so a card can die while its session is coming up. Nothing would ever reap that session (the
   orphan sweep only touches archived/absent cards; reconcile's `.dead` case is a no-op), leaking a real tmux
   session + agent process under a dead card, across daemon restarts. → ownership is now re-verified
   immediately before the hop *and* after it, and a bring-up that lost the card **reaps the session it just
   created** — killing only a session stamped with its OWN generation, since a newer relaunch owns the same
   session *name*.
3. **The landing was epoch-fenced but not phase-fenced** (Claude, MAJOR). `markDead` does not bump
   `sessionEpoch` and `dead → live` is a legal revival edge, so a step whose readiness confirmed *after* the
   timeout concluded the card would flip it back to `.live` — re-animating a card whose death a watching
   parent's `wait` had already been told about. → the funnel's `transition` takes an `expecting` phase, and
   the steppers pass the phase they were dispatched for, so the landing carries the same single-winner fence
   as the bring-up.
4. **The startup-abort retry launched an UNSTAMPED session** (Claude, MAJOR) — `adapter.env` with no
   `withEpoch`. An unstamped session is invisible to the epoch machinery: `stampedEpoch` reads nil, so adopt
   and `reconcilePhasesAtBoot` can never epoch-match it (the next daemon boot tears a healthy retried session
   down and relaunches it, losing the agent's context), and its hooks report with `observedEpoch == nil`,
   skipping the funnel's generation fence entirely. The new fence *amplified* this into a silently-skipped
   restart. → the retry stamps its generation like every other launch.

Claude's review also independently *proved* the property I was least sure of — that the fence cannot wrongly
reject a legitimate bring-up: only the two steppers reach `finishLaunch`; `sessionEpoch` is bumped in exactly
one place (entry to `.creatingWorktree`/`.relaunching`); `.launching` has no re-entry edge, so its epoch is
frozen for the whole phase. A phase/epoch mismatch at the guard is therefore *always* a genuine supersede.

## The `wait` lost-wakeup — folded in after all

`OrchestraService.wait` read card state and *then* subscribed to `MergeWatch`, with two actor hops in
between, while `watch` registered first. A conclusion landing in that gap reached zero subscribers and was
dropped (`MergeWatch` kept no memory of it), and the waiter parked forever — on the one unbounded park in
the product.

This was **not** the cause of the wedge (the traced runs show no such drop), and the first cut of this
branch left it as a follow-up. The review pass correctly refused that: the regression test I wrote for it
(`waitSurvivesConclusionRacingSubscribe`) is racy *by construction*, so shipping it into the very suite this
branch is making green would have planted a flake that reads as "the fence broke `wait`". Land the fix or
drop the test — so the fix is landed.

`MergeWatch` is now two-phase (`subscribe` → `awaitConclusion(token:)`), with a `delivered` slot state that
RETAINS a conclusion arriving between the two, and `wait` subscribes **before** it reads. That is airtight
because `transition` writes the terminal phase to the store *before* it calls `concludeCard`: a conclusion
landing after the subscribe resolves the subscription, and one that landed before it is already visible in
the store to `firstConcluded`.
