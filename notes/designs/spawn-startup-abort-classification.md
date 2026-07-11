# Spawn startup-abort classification (landed on main)

**Status:** implemented on `fix/spawn-startup-abort-classification` (based on `main`). Owner bug: card 760000.
**Coordination:** the `lifecycle-convergence` redesign (persisted phase + funnel + epochs + reconciler)
has NOT landed on main (still in `design/impl/orch lifecycle-convergence` branches). This fix is
implemented cleanly on the current `reconcileLiveness` seam; when convergence lands, fold the logic below
into its reconciler/funnel so the two don't double-classify.

## Problem

`SessionManager.ensure` runs `tmux new-session -d` — exit 0 the instant the session is CREATED, never
waiting for the agent to initialize. An agent that exits ~200ms–1s later (a transient auth/usage hiccup,
a config parse error) had its tmux window torn down (`remain-on-exit off`), and the 2s `reconcileLiveness`
poll saw the session gone → `markDead(.sessionVanished, detail: nil)`. Indistinguishable from a real
mid-run crash, with the dying pane's stderr discarded → undiagnosable, never retried. Bit two GPT-5.5
Codex reviewer cards.

## Fix (agent-agnostic; seam = `ensure` + `reconcileLiveness`)

1. **Arm evidence + mark startup-pending (spawn).** After `ensure`, `setRemainOnExit(agent, on)` so an
   immediate exit leaves a *dead pane in a still-present session* (its stderr intact), and record
   `spawnPending[id] = now + spawnGraceSeconds` (+ `spawnAttempts`, `spawnRelaunch` launch spec).
   Kept SEPARATE from `recovering` (holding `recovering` would no-op an immediate `send` at wake gate A).

2. **Classify in `reconcileLiveness`.** A startup-pending card is resolved by *pane* state, not session
   presence (`PaneLiveness { alive, dead, gone }`, `SessionManager.agentPaneState` via `#{pane_dead}`):
   - `.dead` (pane exited, session present — only observable because remain-on-exit kept it) → **startup
     abort**: `capture` the pane → `startupEvidence` (last non-empty lines, capped) → `deadDetail`; then
     **bounded retry** (`kill`+`ensure` the SAME session/cwd — no double-create, no worktree churn) or
     `markDead(.spawnExitedImmediately)`.
   - `.alive` past its deadline → **graduate**: `setRemainOnExit(off)` + clear pending → normal monitoring
     (a later exit vanishes the session and reads as `.sessionVanished`, exactly as before).
   - `.gone` (session absent — a deliberate kill or a lost remain-on-exit race) → the existing
     `.sessionVanished` path, NOT a startup abort and never re-spawned (don't fight an intentional kill).

3. **New `DeadReason.spawnExitedImmediately`** (Model.swift) with recovery copy in both mac + iOS
   `RecoveryView` (compile-forced exhaustive switches), surfacing `deadDetail` like `.resumeFailed`.

## Why a genuine mid-run vanish is unaffected

`remain-on-exit` is ON *only* during the startup grace (turned off at graduation). A mid-run crash
therefore vanishes the session (`.gone`) exactly as before → `.sessionVanished`. Tests that simulate a
mid-run crash with `setAlive(false)` (a *gone* session) keep passing unchanged.

## Tuning (non-persisted, injectable — the `remoteWatchIntervals` pattern, NOT `Config`)

`OrchestraService.spawnGraceSeconds` (default 4) · `maxStartupRetries` (default 1). Not added to `Config`
because `ConfigStore.load` falls back to all-defaults on any decode failure — a new non-optional field
would silently reset every user setting on an old config.json. `setStartupConfirmation(_:_:)` is the test
hook.

## Reentrancy / lifecycle safety

`handleStartupAbort` holds `recovering` across its capture/relaunch suspensions (so a late SessionEnd
for the exited agent — `report`'s death path gates on `!recovering` — can't race the classification) and
NEVER inherits it (dropped on every exit, so the next reconcile can re-examine). After the capture
`await` it re-validates the card (`spawnPending` still set, not archived, not **dead**, not **done**)
before relaunching, so a card the user archived/killed/restarted, or a fast read-only child that concluded
mid-capture, is not resurrected (requirement D). `spawnPending` is cleared on: `markDead` (any death),
`report`'s SessionEnd death, `resume`/`restart` (user supersede), and `archive`.

**Graduation is toggle-gated.** A card graduates (drops `spawnPending`) ONLY once `setRemainOnExit(off)`
is confirmed (the tmux verb now checks its exit status and throws on failure); if the toggle fails the
card stays pending and retries next tick. Otherwise a stuck-ON remain-on-exit would leave a later mid-run
crash as a dead pane in a present session that the generic vanish check (session-presence) never sees.

**Guaranteed convergence of an orphaned dead pane.** `spawnPending` is in-memory, so a daemon restart
inside the grace loses it while the tmux session (dead pane, remain-on-exit ON) survives — and the generic
vanish check keys on session-NAME absence, so it never fires. A card must ALWAYS converge, so the
**continuous** `reconcileLiveness` (not just the one-shot boot sweep) resolves it: `agentPaneDeadSessions()`
(one server-wide `list-panes -a` per tick) surfaces every orchestra session whose agent pane process
exited; a non-pending `.running` card in that set → `resolveOrphanedDeadPane` — capture surviving stderr →
remain-on-exit off → reap → `markDead(.spawnExitedImmediately)`. **No retry** (the budget record was lost
with `spawnPending`; per the convergence contract, just mark dead — never loop). A dead agent pane only
exists while remain-on-exit is ON (a startup-armed pane), so this never mis-fires on a healthy card.
`recoverSessions` is unified onto the same helper, so boot and poll agree and the evidence survives.
Reconcile order: `recovering` → `spawnPending` (budgeted retry) → orphaned-dead-pane (converge) → generic
vanish.

**Boot restores the "non-pending ⇒ remain-on-exit OFF" invariant.** While the daemon is up, remain-on-exit
is ON ⟺ the card is `spawnPending` (armed at spawn, cleared at graduation; a failed toggle-off keeps it
pending). The one way a *non-pending* card can carry it ON is a daemon restart *during the grace while the
pane is still alive* — the session survives armed but `spawnPending` is gone, so it would never graduate,
and a later NORMAL mid-run exit would leave a dead pane the orphan branch would MISclassify as a startup
abort. So `recoverSessions` clears remain-on-exit on every alive survivor's agent window: on success the
card is monitored normally and a later exit vanishes → `.sessionVanished` (correct). Trade-off: a startup
abort that straddles a restart may classify as `.sessionVanished` instead of `.spawnExitedImmediately` —
acceptable (still converges correctly; no wedge, no wrong-terminal hang). NOTE: this boot clear (and the
graduation toggle) is **best-effort** — see "Known limitations / accepted residuals" for the failure case.

## Known limitations / accepted residuals

All are **accepted** (owner 760000 + Allen): each still converges the card correctly — the residual is at
worst a *cosmetic dead-reason mislabel* under a compound-rare condition, and every case is strictly better
than the pre-fix behaviour (silent `.sessionVanished` / `deadDetail = nil` / no retry).

- **(a) Best-effort tmux toggles.** Two `remain-on-exit` writes are best-effort: the boot clear for an
  alive restart-survivor (`recoverSessions`, via `try?`) and, symmetrically, the arming right after
  `ensure` at spawn. `SessionManager.setRemainOnExit` now throws on a tmux non-zero exit, but these two
  call sites intentionally swallow it (the alternative — killing a *live, healthy* agent because one tmux
  `set-option` blipped — is worse). So a **single tmux `set-option` failure** can leave the flag in the
  wrong state.

- **(b) Resulting cosmetic misclassification window.** Compound-rare path: daemon restarts *during* a
  startup grace *while the pane is alive* → `spawnPending` is lost → the boot clear in (a) *fails once* →
  the card runs on with `remain-on-exit` stuck ON and no pending record. A **later NORMAL mid-run exit**
  then leaves a dead pane, which the continuous reconcile's orphan branch resolves as
  `.spawnExitedImmediately` instead of the strictly-correct `.sessionVanished`. (The symmetric spawn-arm
  failure in (a) degrades the *other* way — a genuine startup abort falls back to `.sessionVanished` with
  no captured evidence.)

- **(c) Why it's acceptable.** The card **always converges** — the orphan path does **no retry**, so there
  is no wedge, hang, or bad-retry loop; only the `deadReason` label is off (`.spawnExitedImmediately` vs
  `.sessionVanished`), and only when a tmux write fails *and* it coincides with a restart-mid-grace *and* a
  later exit. Both are still `.dead` and user-recoverable. This is the deliberate cost of not force-killing
  a live agent over a transient tmux error.

  **FUTURE (explicitly deferred, not in this PR):** the true class-closing fix is to stop deriving
  classification from ephemeral tmux state at all — persist the startup-grace deadline (and retry budget)
  on the `Task` record so `spawnPending` survives a daemon restart and graduation/classification no longer
  depend on a durable-vs-ephemeral coupling or a best-effort toggle. Deferred as a larger change; a natural
  fit for the [[lifecycle-convergence-design]] persisted-phase reconciler.

- **Residual `ensure`→arm race:** `remain-on-exit` is armed the statement *after* `ensure`. An agent that
  exits in that sub-ms window tears the session down → `.gone` → falls back to `.sessionVanished` (no
  evidence). Graceful degradation, not a regression; a true fix needs arming at session-creation time.

## Files

`Model.swift` (enum), `Protocols.swift` (`PaneLiveness` + `SessionManaging` additions w/ defaults),
`SessionManager.swift` (tmux impls), `OrchestraService.swift` (state + spawn arming),
`OrchestraService+Recovery.swift` (`reconcileLiveness` branch + `confirmSpawnStartup`/`handleStartupAbort`/
`startupEvidence`/`clearSpawnPending`), both `RecoveryView.swift`, `Stubs.swift` + `StartupAbortTests.swift`.
