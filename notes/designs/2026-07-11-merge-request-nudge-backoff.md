# Merge-request re-nudge: backoff + give-up cap

**Date:** 2026-07-11
**Branch:** `feat/merge-request-nudge-backoff` (stacked on `fix/nudge-leak-cooperative-pool-starvation`)
**Status:** design approved, ready to plan

## Summary

The merge-request re-nudge loop re-prods the parent card every 300s **forever**. A parent that has
ignored 50 reminders will not act on the 51st. Replace the flat infinite cadence with a **geometric
backoff** and a **hard cap**, after which the loop gives up and the child lands in a **visible,
persisted terminal state** (`mergeStalled`) instead of quietly nudging until the heat death of the
universe.

This is a **product/UX change, not a bug fix.** It is explicitly *not* a fix for the cooperative-pool
starvation wedge — see `2026-07-11-nudge-leak-cooperative-pool-starvation.md`, which fixes that on the
parent branch (weak timer loops + service teardown + `DispatchSerialQueue` executors). Backoff would
merely *dilute* that bug — fewer concurrent forks turns a deterministic deadlock into a rare
intermittent one, which is strictly worse. The two changes are independent and must stay so.

## Today

`OrchestraService+MergeRequest.swift`:

- `mergeRequest()` enqueues the request into the parent's inbox and `wake`s it **at t=0**, then arms
  the loop. The loop only ever sends *reminders*; a parent that ships within 5 minutes sees none.
- `startMergeRequestNudge` sleeps `mergeRequestNudgeInterval` (default 300s) and calls
  `reNudgeMergeRequest`, which re-enqueues + re-wakes, and returns `true` only when the child leaves
  the waiting state or the parent card has vanished. There is no counter, no ceiling, no give-up.
- `rebuildMergeRequestNudges()` re-arms every `mergeRequested` card at daemon start.

That last point is what shapes the whole design: **any counter kept in memory is reset by every daemon
restart**, and the daemon restarts often. An in-memory cap is a cap that never fires. The count must be
persisted or the feature is a fiction.

## Design

### The counter lives in `TreeStat`, and the loop is stateless

Add one field to the persisted per-card tree status:

```swift
public struct TreeStat: Codable, Sendable, Equatable {
    public var state: TreeState
    public var behind: Int
    public var parentIsRemote: Bool
    public var nudges: Int          // reminders sent so far (NOT counting the t=0 request)
}
```

Decoded leniently (`decodeIfPresent(Int.self, forKey: .nudges) ?? 0`), following the precedent `Task`
already sets (`Model.swift:514`), so cards persisted before this change keep loading.

The loop then holds **no state of its own**. Each tick reads `nudges` from the store, sleeps
`delay(for: nudges)`, sends the reminder, and writes `nudges + 1` back. A daemon restart re-arms the
loop and it *resumes at the right point in the backoff* rather than starting over — which is the whole
reason the counter is persisted rather than captured in the Task closure.

### Schedule: geometric, ceilinged, capped

```swift
/// Delay before reminder `n` (0-based). Doubles from the base, ceilinged at 12× it.
/// The shift operand is clamped before shifting — an unclamped `1 << attempt` would overflow on a
/// large persisted count (a hand-edited or corrupted card), which is a crash, not a long sleep.
static func nudgeDelay(base: Duration, attempt: Int) -> Duration {
    base * min(1 << min(max(attempt, 0), 8), 12)
}
```

The ceiling is expressed as a **multiple of the base**, not an absolute duration — so tests that inject
a 20ms base get a 240ms ceiling and stay fast. Cap: **8 reminders**, then give up.

With the production base of 300s:

| | delay | elapsed |
|---|---|---|
| **request** (t=0, already exists) | — | 0 |
| reminder 1 | 5m | 5m |
| reminder 2 | 10m | 15m |
| reminder 3 | 20m | 35m |
| reminder 4 | 40m | 1h15m |
| reminder 5 | 60m *(ceiling)* | 2h15m |
| reminder 6 | 60m | 3h15m |
| reminder 7 | 60m | 4h15m |
| reminder 8 → **give up** | 60m | 5h15m |

Front-loading matters: the early reminders are the ones most likely to land (the parent may simply be
mid-turn), and the late ones are the doomed ones. The first interval stays at 300s rather than
shortening — the request is *already in the parent's inbox* from t=0, so an earlier reminder mostly
double-posts to a card that has not yet checked its inbox.

Both knobs stay injectable (`setMergeRequestNudgeInterval` already exists; add
`setMergeRequestNudgeCap`) so the existing tests keep avoiding real 5-minute sleeps.

### Give-up: a visible terminal state, not a silent stop

Add a fourth case to the existing tree state:

```swift
public enum TreeState: String, Codable, Sendable {
    case inSync, stale, restackNeeded, mergeRequested, mergeStalled
}
```

On the capped tick, `reNudgeMergeRequest` flips the child to `.mergeStalled`, emits a `.warning`
activity entry naming the child, the parent, and the count, and stops the loop. This is a deliberate
**sibling of the existing "parent card vanished" path** (`OrchestraService+MergeRequest.swift:84-90`),
which likewise clears the sticky badge and recomputes rather than stopping silently.

`mergeStalled` is **sticky and terminal**:

- persisted, so it survives a daemon restart;
- `rebuildMergeRequestNudges()` re-arms only `.mergeRequested`, so a restart cannot resurrect the spam;
- the three "don't clobber the sticky badge" guards in `OrchestraService+Tree.swift` (`:194`, `:424`,
  `:435`) currently test `state == .mergeRequested`; they become `state.isMergePending`, a 1-line
  computed property covering both cases. Same carve-out for `restackNeeded`, unchanged.

It clears exactly the way `mergeRequested` does — `shipped` / `synced` / `set-parent` — plus a fresh
`merge-request`, which resets `nudges` to 0 and re-arms the full budget. That re-send is the human's
escape hatch, and it works today without a new verb: `alreadyPending` tests `state == .mergeRequested`,
so a *stalled* child is not deduped and correctly re-enqueues + re-wakes the parent.

### Surfacing: badge + activity now, converge on the delivery-stuck seam later

Both card faces switch exhaustively on `TreeState` (`App/Views/CardView.swift:215`,
`App-iOS/Views/BoardCardCell.swift:94`), so the compiler enumerates every consumer — there are six in
the whole repo and no way to miss one. `mergeStalled` renders as a red warning glyph with
*"Merge-request went unanswered — 8 reminders, nobody merged this"*, where `mergeRequested` renders its
amber clock.

**What this deliberately does NOT build: a notification pipeline.** The `plan/live-wake-delivery` card
(`notes/designs/live-wake-delivery/`, in Review) has already designed a *delivery-stuck* state with the
same anatomy — quiet retry with backoff, a persisted marker flipped only once it is "clearly not
self-healing (N failures / age)", surfaced via `AttentionReason.deliveryStuck` + `NotifyTrigger` +
an `AttentionTracker` one-shot (needed because notifications fire off *phase* transitions, and a
stuck-marker is not a phase change). Its mechanism is different from ours — delivery-stuck means the
message never reached the agent; merge-stalled means it arrived and the agent ignored it — but the
human-facing surface is identical: *this card is stuck, come look*.

Building a second, competing stuck-surfacing stack now would duplicate designed work and collide in
three shared enums. So: **build the mechanism here, borrow the surface there.** When B5b lands its
seam, `mergeStalled` joins it as a ~3-line addition (one case in `NeedsYouQueue.reason(for:)`, one
`NotifyTrigger`). Recorded as a follow-up on that card's own PR document so the two cannot silently
drift — see "Cross-card sync" below.

### Not unifying with `startRemoteWatch`

The card prompt asks whether the two loops should share a policy seam. They should not. `startRemoteWatch`'s
two-tier cadence is **signal-driven** — poll faster *because the parent tip moved*, i.e. it speeds up on
evidence of activity, and it never terminates because a base branch legitimately never merges. This loop is
**silence-driven** — it slows down and eventually dies *because nothing happened*. They are opposites
wearing the same clothes; a shared abstraction would be a parameter bag with no shared behaviour. YAGNI.

## Testing

TDD; each must fail against the current code.

1. **Schedule** — `nudgeDelay` is a pure function: doubling, ceiling at 12×, no negative/overflow at
   large attempts.
2. **Cap fires** — base 20ms, cap 3: the parent's inbox receives exactly 1 request + 3 reminders, the
   child ends `.mergeStalled`, `mergeRequestNudgeActive` is false, a `.warning` activity is emitted.
3. **Backoff resumes across restart** — seed a card with `TreeStat(.mergeRequested, nudges: cap-1)`,
   call `rebuildMergeRequestNudges()`: exactly one more reminder, then stall. Proves the count is read
   from the store, not from a fresh in-memory counter.
4. **Stalled is sticky** — a `recomputeTreeStat` does not clobber `.mergeStalled` (except the existing
   `restackNeeded` carve-out); it survives a store round-trip.
5. **Clearing** — `shipped` / `synced` / `set-parent` clear it; a fresh `merge-request` on a stalled
   child resets `nudges` to 0, re-enqueues, re-wakes, and re-arms the loop.
6. **Codable** — a `TreeStat` JSON without `nudges` decodes with `nudges == 0`.

Acceptance: full `swift test` green (on the parent branch's fix, which is what makes the suite
terminate at all); verified against **both** agent backends per `CLAUDE.md` — this path is
agent-agnostic, so the check confirms nothing regressed.

## Cross-card sync

The `plan/live-wake-delivery` card owns the stuck-surfacing seam. A message is sent to it asking that
its **B5b** work-item record the merge-stalled rider, so the convergence is written into that card's own
PR document rather than depending on a human remembering it.

## Scope

**In:** persisted `TreeStat.nudges`; geometric backoff with a base-relative ceiling; 8-reminder cap;
`TreeState.mergeStalled` + both badges; `.warning` activity on give-up; `isMergePending` helper;
injectable cap.

**Out:** any new `NotifyTrigger` / `AttentionReason` / `AttentionTracker` change (→ converge on B5b);
unifying with `startRemoteWatch` (→ rejected above); anything touching the starvation fix (→ parent
branch).
