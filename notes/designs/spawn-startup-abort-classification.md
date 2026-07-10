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

## Files

`Model.swift` (enum), `Protocols.swift` (`PaneLiveness` + `SessionManaging` additions w/ defaults),
`SessionManager.swift` (tmux impls), `OrchestraService.swift` (state + spawn arming),
`OrchestraService+Recovery.swift` (`reconcileLiveness` branch + `confirmSpawnStartup`/`handleStartupAbort`/
`startupEvidence`/`clearSpawnPending`), both `RecoveryView.swift`, `Stubs.swift` + `StartupAbortTests.swift`.
