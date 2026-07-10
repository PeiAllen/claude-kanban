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
`await` it re-validates the card (`spawnPending` still set, not archived, not dead) before relaunching, so
a card the user archived/killed/restarted/concluded mid-grace is not resurrected (requirement D).
`spawnPending` is cleared on: `markDead` (any death), `report`'s SessionEnd death, `resume`/`restart`
(user supersede), and `archive`.

## Known limitations (accepted / for the convergence reconciler)

- **Daemon restart inside the ≤`spawnGraceSeconds` window:** `spawnPending` is in-memory. If the daemon
  restarts while a just-aborted card's dead-pane session is still present (remain-on-exit ON), the reboot
  `recoverSessions` sees the session in `sessions.list()` and treats the card as alive — leaving it wedged
  with a stuck remain-on-exit. Narrow (needs a restart within a few seconds of an abort). The
  lifecycle-convergence reconciler (persisted phase) is the natural place to close this; until then a
  user restart clears it.
- **Residual `ensure`→arm race + `setRemainOnExit` failure:** `remain-on-exit` is armed the statement
  after `ensure`, and best-effort (`try?`). An agent that exits in that sub-ms window (or a tmux hiccup
  arming the option) tears the session down → `.gone` → falls back to the old `.sessionVanished` (no
  evidence). Graceful degradation, not a regression; a true fix needs arming at session-creation time.

## Files

`Model.swift` (enum), `Protocols.swift` (`PaneLiveness` + `SessionManaging` additions w/ defaults),
`SessionManager.swift` (tmux impls), `OrchestraService.swift` (state + spawn arming),
`OrchestraService+Recovery.swift` (`reconcileLiveness` branch + `confirmSpawnStartup`/`handleStartupAbort`/
`startupEvidence`/`clearSpawnPending`), both `RecoveryView.swift`, `Stubs.swift` + `StartupAbortTests.swift`.
