# Bug #3 — a stale liveness snapshot kills a freshly-live session

**Date:** 2026-07-12
**Branch:** `test/deflake-suite`
**Status:** fixed
**Sibling:** `2026-07-11-stale-bring-up-suite-hang.md` (bug #2). Same hazard, opposite direction.

---

## Summary

`reconcile()` could mark a **healthy, freshly-launched agent** `dead(.sessionVanished)`.

It was found while de-flaking the test suite: `RecoveryTests.restart` "flaked" under `--parallel`. It was
not a flaky test. The card really was being killed, and the product really was killing it.

## The bug

`reconcile()` sampled the live-session set **before** it read the card phases, with two off-actor tmux hops
in between — each of which RELEASES the actor:

```swift
let aliveNames    = await offActor { sessions.list() }                   // (1) sessions sampled FIRST
let deadPaneNames = await offActor { sessions.agentPaneDeadSessions() }  // (2) actor released again
let tasks         = await store.all()                                    // (3) phases read LAST
```

`aliveNames` and `tasks` are a **snapshot pair**, and they were taken in the wrong order. A card that is
`.relaunching` at (1) — its session not yet created — but whose bring-up step completes during (1)/(2), is
read at (3) as `.live`. The `.live` branch then tests it against a session set captured **before its session
existed**:

```swift
case .live:
    if !alive { await markDead(t.id, reason: .sessionVanished, …) }   // kills a live agent
```

The session is up. The agent is up. The card is killed anyway, because the daemon looked at the session
before it existed and at the phase after it went live.

## Why it is the mirror of bug #2

Bug #2: *a stale **bring-up** must never resurrect a live session.*
Bug #3: *a stale **liveness snapshot** must never kill a live session.*

Both are the same underlying hazard — a decision taken off a snapshot that a concurrent step has already
invalidated. Bug #2 was fenced by re-verifying ownership immediately before the destructive act. The `.live`
kill path had no such fence.

`sweepOrphanSessions` had ALREADY learned this lesson — it re-probes off-actor before killing ("never off a
stale snapshot; bug #7"). The `.live` kill, the *other* destructive path in the same function, never got the
same treatment. The fix generalises what the sweep already does.

## Production impact (this is not a test-only bug)

The daemon reconciles every 2s. The window is the whole `agentPaneDeadSessions` tmux subprocess, so:

> restart or resume a card → the agent launches fine → the card immediately flips to `dead(sessionVanished)`.

A loaded machine widens the window; that is why it surfaced under `--parallel` load rather than at the desk.
It is a plausible source of previously-unexplained "card died right after restart" reports.

## The fix

1. **Read the phases first, then sample the sessions.** This makes the pair fail-safe *by direction*: a card
   observed `.live` at T0 must have `ensure`d its session before T0, so a session sample at T1 > T0
   necessarily sees it. A card that goes live after T0 is read as still-being-born and is simply skipped this
   tick; the next tick, whose snapshot pair is consistent, lands it.

   **We may be late to notice a death. We must never invent one.**

2. **Re-probe before the kill.** The loop suspends on every `await`, so by the time a given card is reached
   the snapshot can be arbitrarily old. Confirm the session is really gone with a fresh off-actor probe
   before concluding the agent died — the same fail-safe `sweepOrphanSessions` applies. This also absorbs a
   transient `list()` hiccup.

## Pinned by

`ReconcilerTests.freshlyLiveCardNotKilledByStaleSnapshot` — deterministic, ~0.25s, no load needed. It lands
the card `.live` *inside* the tick's second off-actor probe (via a one-shot `onAgentPaneDeadProbe` hook on
`StubSessions`, mirroring the existing `onStampedEpochProbe` seam), i.e. exactly where a real bring-up step
lands. Against the old code it reproduces the kill every time.

## Fallout worth knowing

`PhaseTransitionTests.runProvisioningDelivery` was **relying on the bug**. It seeds a card `.live` with no
session (spawn is non-blocking, so nothing ever ensured one). The old stale ordering suspended the actor on
the session probes just long enough for its wake's `.relaunching` intent to land before the phases were read
— so the kill never fired. With the ordering fixed, reconcile correctly concludes that a `.live` card with no
session has vanished.

The test's premise is the artificial thing: **in production a `.live` card always has a session**, because
`finishLaunch` ensures one before landing the phase. The fix was to model that precondition (seed the
session), not to weaken the product.
