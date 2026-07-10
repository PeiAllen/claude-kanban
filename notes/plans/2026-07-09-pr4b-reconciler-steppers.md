# PR4b — Reconciler + Phase-Keyed Steppers + Non-Blocking Spawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Orchestra's card lifecycle *reconciler-driven*: verbs only persist intent (`transition()` to a phase and return), and a per-tick reconciler drives four stateless phase-keyed steppers (Materialize / Launch / Relaunch / Teardown) to convergence — with non-blocking spawn, startup reconciliation with epoch-identity adoption, a durable watch registry, corrupt-`tasks.json` recovery + conservative mode, and the crash/race battery that proves it.

**Architecture:** The funnel (`transition()`, PR2) stays the sole writer of `phase`. PR4a shipped the `PhaseStepper` protocol + `ConvergeContext` skeleton, the verb `kind`/`phaseGate` taxonomy, and the dispatch gate chokepoint. THIS PR fills in the four real steppers, wires the reconciler to dispatch them by `Phase.Kind` each tick (≤1 in-flight step per card, `phaseChangedAt` timeouts, capped backoff, orphan-session sweep, epoch-identity adoption), flips spawn + archive + reopen + resume/restart/handoff to intent-only verbs, persists the watch registry, and adds corrupt-store recovery driving a `conservativeMode` `release()`.

**Tech Stack:** Swift (Swift Concurrency actors), swift-testing (`swift test`), tmux, git worktrees, atomic-JSON persistence beside the inbox.

**Companion vault (READ FIRST, in this worktree):**
- `notes/designs/lifecycle-convergence/02-contract.md` — stepper + registry + funnel contracts.
- `notes/designs/lifecycle-convergence/03-implementation.md` — boot order, adoption identity, resource epilogue, conservative mode, key mechanics.
- `notes/designs/lifecycle-convergence/04-tests.md` — the crash/race battery mapped to bugs.
- `notes/designs/lifecycle-convergence/05-pr-tree.md` — I am **PR4b**.
- `notes/designs/2026-07-08-card-lifecycle-convergence.md` — spec (pillar P2).
- `notes/plans/2026-07-08-card-lifecycle-convergence.md` — Stage 4, Tasks 4.2 / 4.3 / 4.4 / 4.6 / 4.7 (my scope) + Global Constraints + test doctrine.

---

## Global Constraints (copied verbatim from the vault — every task inherits these)

- **Agent-agnostic.** No `if agentId == "claude"` in shared code. Every mechanism is gated on `adapter.capabilities.*`. **Every stepper crash test runs for BOTH `claude-code` and `codex`** (today's provisioning tests are Claude-only — fix that).
- **Non-blocking daemon.** No RPC and no periodic loop blocks the `OrchestraService` actor on a subprocess. Spawn returns immediately; steppers run off-actor (via the existing `offActor` hop or the `WorktreeRegistry` actor). Keep the single `OrchestraService` actor — no per-card executors.
- **Fail-safe defaults.** Never kill without a fresh epoch-stamped probe; never adopt an old-epoch session; never force-remove a dirty/shared worktree; never remove a path outside the registry's owned roots; on ambiguity keep the card AND the tree.
- **Full suite (~680 tests) stays green after every task.** `swift test`. Never leave a task red.
- **Test doctrine.** Race/crash coverage comes from **deterministic stub seams**, not E2E. Extend `Tests/OrchestraCoreTests/Stubs.swift` with the blockable/recording seams (`blockEnsure`, `stampedEpoch`, and the existing `removed`/`killed`/`ensureArgv`/`ensureEnv`/`isAliveQueries` recorders). "Crash" is simulated deterministically by `TestEnv.remake(base:)` — a fresh service over the same on-disk store (in-memory timers/loops gone; steppers re-derive from persisted phase). No in-process kill hook needed — that IS the stateless-stepper guarantee.
- **Anchor provenance.** All `file:line` anchors verified @ `f1aa568`; symbols are the fallback if a line drifted.

## Deviations from the vault plan's literal task order (recorded — fold into vault Decisions on completion)

The vault plan lists 4.2 (non-blocking spawn) → 4.3 (relaunch/teardown verbs) → 4.4 (reconciler driving). Implemented **enabler-before-consumer** so the suite stays green at every task boundary:

1. **Steppers as pure units first** (Task 1) — testable via `convergeContext()` + direct `stepper.step(card, ctx)`; verbs unchanged (still synchronous), so the suite stays green while the driving machinery doesn't exist yet.
2. **Reconciler driving + boot reconciliation + durable registries next** (Task 2) — the *enabler*. Tests seed transitional cards directly (`store.update { $0.phase = … }`); synchronous-spawned live cards are non-transitional, so stepping is a no-op for them — suite green.
3. **Non-blocking spawn flip + the ~30-file test migration** (Task 3) — the *consumer*; only safe once the reconciler drives. This is the flag-day; `spawnAndAwaitLive` drives the reconciler in-test.
4. **Relaunch/Teardown verb flips + carried requirement #5** (Task 4) — archive→`archivedPending`, reopen→`creatingWorktree`, resume/restart/handoff→`relaunching`; retire the Bool-bridge + tighten `isLegalEdge`.
5. **Matrix + crash battery** (Task 5), **docs** (Task 6).

This matches the brief's own guidance ("steppers before reconciler-driving; the test migration lands with non-blocking spawn").

## The five CARRIED requirements (prior PRs deferred these to PR4b — tracked to their gating test)

| # | Requirement | Where wired | Gating test |
|---|---|---|---|
| 1 | **`pendingSeed` write+consume TOGETHER** | write: handoff/seeded-wake verb (Task 4, same patch as `transition(.relaunching)`); consume+clear: LaunchStepper/RelaunchStepper on readiness-at-current-epoch (Task 1); keep on `resumeFailed` | `test_handoffSeedSurvivesCrash` (Task 4) |
| 2 | **Consume `sessionLaunchTimeout`** (PR3a added it unconsumed) | reconciler `launching`/`relaunching` `phaseChangedAt` timeout (Task 2) | `test_launchTimeoutSurvivesCrash`, `test_launchingMissedHookConvergesViaLiveness` (assert `N×tick < sessionLaunchTimeout`) |
| 3 | **Wire conservative mode** into PR3b's `release()` seam | corrupt-recovery sets `worktrees.setConservativeMode(true)` at boot (Task 2) | `test_corruptTasksJsonRecovers` |
| 4 | **Persist the watch registry** (today in-memory `OrchestraService.swift:60`) | new `WatchRegistryStore.swift` + boot reload (Task 2) | `test_mcpWatchSurvivesRestart` |
| 5 | **Route archive through the funnel** (TeardownStepper); retire the `gatedKind` Bool-bridge; tighten `isLegalEdge` (no direct `*→archivedComplete`); epoch-fence reopen resume-finalize; restart-blank capability-gated under the stepper; verb-vs-verb restart single-winner via epoch supersede | Task 4 | `test_gatePolicyConformance`, tightened `test_illegalEdgesRejected`, `test_archiveDuring*` battery, `test_reopenCrashRestart` |

---

## File structure (this PR)

| File | Change | Task |
|---|---|---|
| `Sources/OrchestraCore/PhaseStepper.swift` | Fill in `MaterializeStepper`/`LaunchStepper`/`RelaunchStepper`/`TeardownStepper`; register `PhaseSteppers.byKind`; add stepper helpers (launch-flavor derivation, resource epilogue) | 1 |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | Reconciler `reconcile()` per-tick discipline (step transitional cards, orphan-session sweep, `phaseChangedAt` timeouts, attempt counter + backoff, epoch-identity adoption); startup phase reconciliation; pre-kill fresh probe | 2 |
| `Sources/OrchestraCore/OrchestraService.swift` | Non-blocking spawn (shrink sync part); archive→`archivedPending`; per-card `attempts`/`inFlightSteps` reconciler state; `reconcile()` seam; drop the manual `concludeCard` in archive | 3, 4 |
| `Sources/OrchestraCore/OrchestraService+Lifecycle.swift` | Tighten `isLegalEdge` (remove direct `*→archivedComplete`); the funnel is unchanged otherwise | 4 |
| `Sources/OrchestraCore/CommandRegistry.swift` | Retire `gatedKind`'s Bool-bridge → `card.phase.kind`; gate SETS unchanged | 4 |
| `Sources/OrchestraCore/WatchRegistryStore.swift` (new) | Persist `[watcherId: Set<childId>]` atomic-JSON beside the inbox; reload at boot | 2 |
| `Sources/OrchestraCore/TaskStore.swift` | Corrupt-`tasks.json` → timestamped `.corrupt-<ISO8601>` backup + boot empty + a `loadWasCorrupt` flag the boot reads | 2 |
| `Sources/OrchestraCore/Inbox.swift` | `enqueue(..., dedupKey: String? = nil)` (skip if an undelivered message with the same key exists) | 4 |
| `Sources/orchestrad/main.swift` | Boot order (`:47-53`): `sweepOrphanScratch → phase reconciliation → sweepOrphanBorrows → watch-registry reload → rebuildRemoteWatches → rebuildMergeRequestNudges → treeStat recompute`; poll loop calls `reconcile()` | 2 |
| `Sources/OrchestraCore/Protocols.swift` | Add `stampedEpoch(name:) throws -> Int?` to `SessionManaging` (default `nil`) | 1 |
| `Tests/OrchestraCoreTests/Stubs.swift` | `blockEnsure` gate on `StubWorktrees`; `stampedEpoch` on `StubSessions` (parse `ensureEnv[name]["ORCH_EPOCH"]`); `TestEnv.spawnAndAwaitLive`; `TestEnv.reconcile` driver | 1, 3 |
| `Tests/OrchestraCoreTests/StepperTests.swift`, `RecoveryTests.swift`, `VerbContractTests.swift`, ReopenTests, WakeMergeWatchTests, ArchiveOriginTests, ~30 spawn-then-assert files | New tests + the `spawnAndAwaitLive` migration | all |
| `docs/05-command-reference.md`, `docs/02-architecture.md` | Verb taxonomy + Convergence model | 6 |

---

## Task 1 — The four stepper units + stub seams + `stampedEpoch`

**Deliverable:** `MaterializeStepper`, `LaunchStepper`, `RelaunchStepper`, `TeardownStepper` implemented as pure stateless `step`/`verify`, registered in `PhaseSteppers.byKind`, tested directly (no reconciler, no verb changes). Plus the deterministic stub seams every later task needs.

**Files:** `PhaseStepper.swift`; `Protocols.swift` (SessionManaging); `Tests/OrchestraCoreTests/Stubs.swift`; `StepperTests.swift`

**Interfaces produced (consumed by Tasks 2–5):**
```swift
enum PhaseSteppers { static let byKind: [Phase.Kind: any PhaseStepper] }   // filled: 4 entries
struct MaterializeStepper: PhaseStepper  // drives .creatingWorktree
struct LaunchStepper: PhaseStepper       // drives .launching
struct RelaunchStepper: PhaseStepper     // drives .relaunching
struct TeardownStepper: PhaseStepper     // drives .archivedPending
```
The steppers reuse the existing off-actor launch mechanics rather than duplicating them: `LaunchStepper`/`RelaunchStepper` derive their launch inputs from persisted `Task` fields, delegate the readiness-machinery-bound bring-up to a service-actor callback (`ctx.finishLaunch`), and reach `.live`/`.dead` through `ConvergeContext.transition`. The service actor's `launchAndConfirm`/`resume` bodies are the reference for the argv/env/readiness details; extract the shared logic into a `finishLaunch(id:flavor:)` service method the context exposes, so the funnel + `ORCH_EPOCH` stamping + `pendingReadiness`/`readinessWaiters` semantics stay on the actor and intact.

### Step 0 — Extend `ConvergeContext` (BLOCKER fix — GPT-5.5 finding 1)

PR4a's `ConvergeContext` (`PhaseStepper.swift:19-33`) exposes only `store/worktrees/sessions/adapters` + `transition(id, to, observedEpoch)`. That is insufficient: carried #1 (clear `pendingSeed` atomically with `→.live`), carried #5 (set `archived` Bool + `deadDetail` atomically), and the Teardown duty list all need more. Extend it (fold into the vault as a PR4a-skeleton amendment):

- [ ] **Step 0a — Failing test** `test_convergeContextTransitionAppliesMutate`: a stepper transition through the context's mutate form lands the phase AND the companion field-write in one patch (assert both on a single store read). Run red (the mutate overload doesn't exist).
- [ ] **Step 0b — Implement.** Add to `ConvergeContext` (the steppers are THIN orchestrators; anything touching actor-private deps — `lineage` `OrchestraService.swift:36`, `remoteParents` `:38`, `gitRemotes` `+ParentRef.swift:13`, `recordSpawnBase`/`recordSpawnRemoteBase`/`derivedCard` `+Tree.swift`, `wake` `Wake.swift:120` — is delegated through an actor callback, NOT reached directly):
  - `transition: @Sendable (UUID, Phase, Int?, @escaping @Sendable (inout Task) -> Void) async -> TransitionResult` — the funnel's `mutate:` form (replaces the 3-arg closure; callers pass `{ _ in }` when no companion write). The ONE way steppers write `pendingSeed`/`deadDetail`/`archived`/`parentBranch`/`spawnBase` atomically with the phase.
  - `materialize: @Sendable (UUID) async -> MaterializeOutcome` (**Opus finding 1**) — the actor-bound materialization the MaterializeStepper delegates to: remote-base fetch (`remoteParents.fetch`) + `worktrees.ensure` + lineage recording (`recordSpawnBase`/`recordSpawnRemoteBase` + stale-child prune `lineage.clear`) + S2-3(iii) rollback via `release(force:false)`. Extract today's inline spawn body (`OrchestraService.swift:329-401`) into a `materialize(id:) async -> MaterializeOutcome` service method that reads `spawnBase`/remote-ref from the persisted card; the interim synchronous spawn calls it too (safe refactor). Returns `.launching(parentBranch:)` or `.failed(detail:)`. This keeps `lineage`/`remoteParents` actor-owned and makes Task 3's "delete the inline walk" honest (the walk becomes this method the ctx wraps).
  - `inbox: Inbox` — Teardown's dedup child-nudge.
  - `emitActivity: @Sendable (UUID, ActivityKind, String) async -> Void` — re-materialized / spawn-failed / backoff activities.
  - `finishLaunch: @Sendable (UUID, LaunchFlavor) async -> ReadinessOutcome` — the actor-bound bring-up + capability-gated readiness (wraps today's `launchAndConfirm` readiness machinery; Launch/Relaunch steppers delegate so `readinessWaiters`/`pendingReadiness`/`launchReadyTicks` stay actor-owned).
  - `teardownActorDuties: @Sendable (UUID) async -> Void` — cancel treeStat/child-fanout debounces + remote watch + re-nudge timer **AND the child find+nudge+wake** (needs `lineage.children`/`derivedCard`/`wake` — all actor-private, so this MUST be the actor callback, not in the stepper — **Opus finding 1**). The child nudge uses `inbox.enqueue(dedupKey:)`. Session-kill / releaseBorrow / `release()` tree stay in the stepper (reachable via `ctx.sessions`/`ctx.worktrees`, stub-recorded).
  `convergeContext()` (`OrchestraService.swift:1143`) builds all of these closing over the actor. Update `StepperTests`' `DoubleStepper` + existing callers to the new `transition` arity.
- [ ] **Step 0c — Persist the `spawnBase` carrier (Opus finding 4 / GPT-5.5 R2 finding 1).** Add a **single** `spawnBase: String?` to `Task` — the RAW normalized base string exactly as `spawn` receives it (`input.base` after the refs/heads strip). No separate remote-ref field: `materialize` re-derives the classification with `RemoteParentRef.parse(spawnBase, remotes: gitRemotes(repo:))` at materialize time — identical to today's inline spawn (`OrchestraService.swift:344`), so a remote base (`origin/<b>`/`pr#<N>`) survives a restart deterministically. Set at spawn's `store.create` (Task 3), read by `materialize`, cleared on the `→.launching` transition. Additive-optional Codable (mirror `pendingSeed`). `test_spawnBaseCarrierRoundTrips` + `test_materializeRemoteBaseFromCarrier` (a persisted remote `spawnBase` re-fetches + checks out after a `remake`).
- [ ] **Step 0d — Run green.**

### Stub seams (do FIRST — the doctrine requires them)

- [ ] **Step 1a — `blockEnsure` on `StubWorktrees`.** Add a gate the test arms and releases: `func blockEnsure()` sets an internal `DispatchSemaphore`/flag; `ensure(...)` waits on it (with a short safety timeout) before returning; `func releaseEnsure()` opens it. This lets `test_spawnReturnsBeforeProvisioned` prove the RPC returns while `ensure` is still blocked. Keep the existing `ensureSleepMs` for contention tests.
- [ ] **Step 1b — `stampedEpoch` on the protocol + stubs.** Add `func stampedEpoch(name: String) throws -> Int?` to `SessionManaging` with a **default returning `nil`** (so unrelated stubs need no change). Implement on `StubSessions`: parse `ensureEnv[name]?["ORCH_EPOCH"]` → `Int`. The real `SessionManager.stampedEpoch` already exists (`SessionManager.swift:83`) — just ensure it's declared in the protocol so the reconciler can call it through `sessions`.
- [ ] **Step 1c — verify build green** (`swift build`); no behavior yet.

### MaterializeStepper (`drives .creatingWorktree`) — owns ALL of spawn's materialization (GPT-5.5 finding 2)

Build the FULL materialization here (remote-base fetch + worktree `ensure` + lineage recording + S2-3 rollback) so Task 3's spawn flip is a clean delete of the inline walk. The logic mirrors today's inline spawn body (`OrchestraService.swift:329-401`) but reads from the persisted card. The card is persisted (Task 3) with `cwd = worktrees.path(repo:branch:)` (the deterministic target, computed synchronously) and the base/remote-ref inputs carried on the card (add transient fields OR re-derive from `branch`+lineage) — resolve the exact carrier in review (Open question 1).

- [ ] **Step 2 — Failing tests** (worktree, scratch, borrowed each where applicable):
  - `test_materializeStepAdvancesToLaunching`: a `creatingWorktree` card, one `step`, `ensure` called once, phase → `.launching`.
  - `test_materializeFailureClassified`: an `ensure` that throws → `dead(.spawnFailed)` with git stderr in `deadDetail`; a timeout → explicit "timed out after Ns" (no generic passthrough); `release(force:false)` called (via `removed`/`removedForce` recorder — the single removal policy).
  - `test_materializeRemoteFetchFailureClassified`: a remote base (`origin/<b>`/`pr#<N>`) whose fetch fails → `dead(.spawnFailed)` with the fetch context in `deadDetail`; no worktree cut.
  - `test_materializeLineageRecordFailureRollsBack`: a lineage-record throw AFTER `ensure` → the synthetic-card `release(force:false)` rollback runs, a brand-new branch is deleted, and a **shared or dirty** sibling tree is NOT removed (assert via `removedForce` + a seeded sibling).
  - `test_materializeStaleChildPrune`: a brand-new branch with a dangling `orchestra-parent == branch` (name reuse) prunes the stale lineage before recording (S2-3(ii)).
  - `test_materializeResourceEpilogueReleasesOnArchive`: if the card was archived (newer intent) during the `ensure` await, the epilogue releases the just-cut tree and does NOT transition to `.launching`.
  Run red.
- [ ] **Step 3 — Implement.** `step` delegates to `ctx.materialize(id)` (the actor callback from Step 0b — it owns fetch+ensure+lineage+rollback, keeping `lineage`/`remoteParents` actor-owned): on `.launching(parentBranch)` → `transition(.launching, mutate: { $0.parentBranch = parentBranch; $0.spawnBase = nil })`; on `.failed(detail)` → `transition(.dead(.spawnFailed), mutate: { $0.deadDetail = detail })` (the callback already routed the rollback through `release(force:false)` + `branch -D`). A checkout timeout yields an explicit "timed out after Ns" detail. **Resource epilogue** lives inside `materialize`: after the `ensure` await it re-reads on-actor and, if a newer intent made the card terminal, `release`s what was acquired and returns `.failed`/a terminal-noop. `verify` = cwd materialized (dir + marker) AND phase past `creatingWorktree`. The failure-mode tests (remote-fetch/lineage-rollback/stale-child) drive `stepper.step` → `materialize`; remote cases use the `makeReal` git harness (or a stubbed `remoteParents`).
- [ ] **Step 4 — Run green** (steppers still unused by the synchronous spawn — tested directly).

### LaunchStepper (`drives .launching`) — carries requirement #1 (consume side)

- [ ] **Step 5 — Failing test** `test_launchFlavorDerivedFromState`: a `launching` card with `agentSessionId` + a transcript on disk derives **resume**; a never-prompted card with no transcript derives **blank**; `initialPrompt` is submitted only if the card was never prompted. `test_launchStepReachesLiveOnReady` (both agents): a `.relaunchLiveness` cap lands `.live` on successful `ensure`; a `.sessionStartHook`/`.rolloutMeta` cap lands `.live` only after the readiness signal (delivered via `report(sessionSource:)` / N=3 fallback). `test_launchConsumesPendingSeed`: a `launching` card carrying `pendingSeed` has it delivered (folded into the resume seed) and **cleared on readiness-at-current-epoch**. Run red.
- [ ] **Step 6 — Implement.** `step`: derive `LaunchFlavor` purely from persisted fields (`agentSessionId` + `adapter.sessionInfo` transcript-exists → `.resume(seed: pendingSeed)`, else `.blank(landing:prompt:)` where `prompt = initialPrompt` iff `titleProvisional == false && never-prompted`). Stamp `withEpoch(adapter.env, card.sessionEpoch)`. `transition(.launching)` is already the entry (idempotent); bring the session up off-actor (`ctx.sessions.ensure`); confirm readiness (capability-gated, reusing `confirmReadiness`/`awaitReadiness` semantics); on `.confirmed` `transition(.live(landing), observedEpoch: card.sessionEpoch)` **and clear `pendingSeed` in the same patch**; on `.timedOut` leave the card `.launching` for the reconciler's `phaseChangedAt` timeout (Task 2) — do NOT hot-loop; on `.superseded` return. `verify` = session alive at current epoch (`stampedEpoch(name:) == card.sessionEpoch`) AND phase `.live`.
- [ ] **Step 7 — Run green.**

### RelaunchStepper (`drives .relaunching`)

- [ ] **Step 8 — Failing test** `test_relaunchStepKillsThenEnsures`: a `relaunching` card kills the old session then `ensure`s a fresh one (recorders: `killed` before `ensureArgv`); identity via epoch readback (`ensureEnv` carries the current `sessionEpoch`). `test_relaunchReMaterializesMissingWorktree`: the tree deleted under a `relaunching` card → the stepper `ensure`s it back + emits a "re-materialized" activity → `.live`. `test_relaunchBranchGoneFailsSafe`: branch also gone → `dead(.resumeFailed)`, conclusion fires. Run red.
- [ ] **Step 9 — Implement.** `step`: require the worktree (call `ctx.worktrees.ensure` — re-materializes a missing tree, emitting the "re-materialized" activity when `created`); kill the predecessor then `ensure` the session off-actor with `withEpoch(env, sessionEpoch)`; derive flavor (resume when resumable — `pendingSeed` folded — else blank); confirm readiness; `.confirmed` → `transition(.live, observedEpoch:)` + clear `pendingSeed`; branch-gone / transcript-gone → `transition(.dead(.resumeFailed))` (keeps `pendingSeed` for a retry); `.superseded` → return (a newer relaunch bumped the epoch and owns the card — the single-winner discipline). `verify` = session alive at current epoch AND `.live`.
- [ ] **Step 10 — Run green.**

### TeardownStepper (`drives .archivedPending`)

- [ ] **Step 11 — Failing test** `test_teardownFullDutyList` (× **worktree / scratch / borrowed** — GPT-5.5 R2 finding 2): an `archivedPending` card runs, IN ORDER — **kill session → release borrow → origin-aware run-dir reclaim → cancel treeStat/child-fanout debounces + remote watch + re-nudge timer → nudge live children with dedup key `(childId, "parent-archived:<branch>")` → `transition(.archivedComplete)`**. Assert the **origin-aware reclaim**: worktree → `worktrees.release(force:false)` (removed recorder); **scratch → `rm -rf` under `Config.scratchRoot` (path-guarded)** (assert the scratch dir gone); borrowed → NOT removed. Assert child nudge targets the deterministic (oldest) live child. `test_teardownRedriveNoDuplicateNudges`: re-running `step` from `archivedPending` (crash-then-redrive) nudges children **only once** (`dedupKey`) and does not re-reclaim a gone dir. Run red.
- [ ] **Step 12 — Implement.** Each duty idempotent, sourced from the current `archive()` body (`OrchestraService.swift:722-772`). Split by reachability: **in the stepper** (via `ctx`) — kill session (`ctx.sessions.kill`), release borrow (`ctx.worktrees.releaseBorrow`), and the **origin-aware run-dir reclaim** matching today's `archive()` switch (`OrchestraService.swift:747-767`): `.worktree` → `ctx.worktrees.release(cardId:cards:force:false)`; `.scratch` → `FileManager.removeItem` **double-guarded** (`assert` + runtime `if t.cwd.hasPrefix(Config.scratchRoot + "/")` — a pure filesystem op, stub-observable); `.borrowed` → no-op (never deleted). **Via `ctx.teardownActorDuties(id)`** (actor-private, Opus finding 1) — cancel treeStat/child-fanout debounces + remote watch + re-nudge timer **and the child find+nudge+wake** (`lineage.children`/`derivedCard`/`wake`, child nudge carrying `inbox.enqueue(dedupKey: "(childId, parent-archived:<branch>)")`). Add the `dedupKey` param to `Inbox.enqueue` first (no-op-safe; the dedup-skip logic + `test_teardownRedriveNoDuplicateNudges` land here). Order: session-kill → releaseBorrow → origin-reclaim → `teardownActorDuties` → `transition(.archivedComplete, mutate: { $0.archived = true })` (the final flip, companion-writing the `archived` Bool mirror). `verify` = phase `.archivedComplete`. (Under conservative mode the `.worktree` reclaim no-ops via `release`'s gate; scratch reclaim is also skipped under conservative mode — see Task 2 Step 17.)
- [ ] **Step 13 — Run green.**

### Register + idempotency contract

- [ ] **Step 14 — Register `PhaseSteppers.byKind`** = `[.creatingWorktree: MaterializeStepper(), .launching: LaunchStepper(), .relaunching: RelaunchStepper(), .archivedPending: TeardownStepper()]`. Update `test_stepperMapEmptyInPR4a` → `test_stepperMapHasFourSteppers` (the map is no longer empty). Keep `test_stepperStepIsIdempotent` green (the `DoubleStepper` there still exercises the protocol contract; or repoint it at a real stepper).
- [ ] **Step 15 — Run green** — `swift test` full suite (verbs unchanged, so nothing else moved).
- [ ] **Step 16 — Commit** `feat(converge): four phase-keyed steppers + blockEnsure/stampedEpoch stub seams`

---

## Task 2 — Reconciler driving discipline + startup reconciliation + durable registries

**Deliverable:** a per-tick `reconcile()` that steps transitional cards (≤1 in-flight each), enforces `phaseChangedAt` timeouts (consuming `sessionLaunchTimeout` — carried #2), sweeps orphan sessions (fresh epoch probe), adopts sessions only on epoch-identity match, and backs off failing steps; boot phase-reconciliation in the correct order; a persisted `WatchRegistryStore` (carried #4); corrupt-`tasks.json` recovery + conservative-mode wiring (carried #3). **Verbs remain synchronous** — tests seed transitional cards directly.

**Files:** `OrchestraService+Recovery.swift` (`reconcileLiveness:350`, `recoverSessions:24`), `OrchestraService.swift` (reconciler state + `reconcile()` seam), new `WatchRegistryStore.swift`, `TaskStore.swift` (corrupt recovery), `orchestrad/main.swift` (`:47-63`); Test `RecoveryTests.swift`

### Reconciler state + per-tick `reconcile()`

- [ ] **Step 1 — Failing test** `test_strandedTransitionalCardRedriven`: a card seeded at `.creatingWorktree` with no in-flight step is stepped on the next `reconcile()` tick and reaches `.live` (drive the ticks like `reconcileUntilLive`). `test_stepFailureBacksOff`: a stepper whose `ensure` always throws emits an activity and is retried on a **capped backoff** (assert Nth tick does NOT re-step within the backoff window; never a hot loop). Run red.
- [ ] **Step 2 — Implement.** Add per-card reconciler state on the actor: `var inFlightSteps: Set<UUID>` (at most one step in flight per card — set before dispatching a step off-actor, cleared in its completion) and `var stepAttempts: [UUID: (count: Int, nextEligible: Date)]` (attempt counter + capped exponential backoff). Add `func reconcile() async` = the per-tick body:
  1. Batched `sessions.list()` snapshot (one call/tick).
  2. Liveness only for `.live` cards (the existing `reconcileLiveness` `.live` arm → `markDead(.sessionVanished)`).
  3. **Tick `launchReadyTicks` for `.launching`/`.relaunching` cards whose session is alive — gated ONLY on phase + session-alive, NEVER on `inFlightSteps` (Opus finding 2).** The LaunchStepper/RelaunchStepper delegate readiness to `finishLaunch`→`awaitReadiness`; for Codex `codex resume` (no rollout) and any missed hook, the N=3 `tickLaunchReady` pass is the ONLY resolver. If it were gated on `inFlightSteps`, a card holding an in-flight step would never get ticked → `finishLaunch` times out at `grace`(15s) → churn → dead — a Codex-specific correctness regression. Run `tickLaunchReady` every tick, independent of stepping.
  4. **Step transitional cards** — iterate the stepping set **explicitly by `phase.kind`** (`.creatingWorktree`/`.launching`/`.relaunching`/`.archivedPending`), **NOT** via `!isTerminal` (Opus finding 8 — `archivedPending` is `isTerminal == true` per `Model.swift:99-104` yet MUST be stepped by Teardown). For each with no in-flight step and `now >= nextEligible`, look up `PhaseSteppers.byKind[phase.kind]`, run `step` off-actor; a throw bumps `stepAttempts` + emits an activity; success resets the counter.
  5. Orphan-session sweep (below).
  6. `phaseChangedAt` timeouts (below).
  `main.swift`'s poll loop calls `reconcile()` + `pollTelemetry()`. Keep the `.live` liveness arm inside `reconcile()`.
- [ ] **Step 3 — Run green.** **Invariant to preserve (Opus finding 12):** a re-step's `transition(.launching)`/`transition(.relaunching)` from the same phase is a funnel noop that MUST NOT re-stamp `phaseChangedAt` (verified — the funnel only stamps on an applied edge, `OrchestraService+Lifecycle.swift:68-69`), so the `sessionLaunchTimeout` bound stays anchored to the original entry across re-steps. Document it; an accidental re-stamp would make `launching` un-timeout-able. (`grace`(15s) < `sessionLaunchTimeout`(30s) so the N=3 fallback fires well before the timeout.)

### `phaseChangedAt` timeouts — carries requirement #2

- [ ] **Step 4 — Failing test** `test_launchTimeoutSurvivesCrash`: a card `.launching` since before a restart (persisted `phaseChangedAt` older than `sessionLaunchTimeout`) is classified `dead(.spawnFailed)` from its persisted timestamp on the next tick. `test_launchingMissedHookConvergesViaLiveness`: a `.launching` card whose readiness signal was lost still reaches `.live` via the N=3 liveness fallback — and the test asserts `launchReadyTickThreshold × pollInterval(2s) < config.sessionLaunchTimeout` (the inequality the fallback depends on). Run red.
- [ ] **Step 5 — Implement.** In `reconcile()`, for `.launching`/`.relaunching` cards where `now.timeIntervalSince(phaseChangedAt) > TimeInterval(config.sessionLaunchTimeout)` and readiness never confirmed: `markDead(.spawnFailed, detail: "launch timed out after \(config.sessionLaunchTimeout)s")` (relaunch → `.resumeFailed`). This is the **first consumer of `config.sessionLaunchTimeout`**. Keep the N=3 `launchReadyTicks` fallback (it fires well inside the timeout — assert the inequality in test).
- [ ] **Step 6 — Run green.**

### Orphan-session sweep + pre-kill fresh probe + epoch-identity adoption

- [ ] **Step 7 — Failing test** `test_orphanSessionSwept`: an `orchestra-<uuid>` session whose card is **archived or nonexistent** is killed within a tick — after a **fresh epoch-stamped probe**; a `dead(.completed)` card's surviving session is **NOT** killed (revival stays possible). `test_preKillProbeIsFresh` (bug #7): the kill decision consults a fresh probe, not a stale snapshot. `test_preKillProbeOffActor`: the probe runs off the service actor (a concurrent fast RPC returns promptly while it runs). `test_adoptionChecksEpochIdentity`: a `relaunching` card with a surviving **old-epoch** session → boot **completes the relaunch** (kill + launch), never adopts; a matching-epoch session → adopt to `.live`; the N-tick fallback never promotes an old-epoch session. Run red.
- [ ] **Step 8 — Implement.** Orphan sweep: for each live session name with no matching non-terminal card (card archived / absent, excluding `dead(.completed)` whose revival stays possible), run a fresh off-actor `stampedEpoch`/`isAlive` probe, then `sessions.kill`. Adoption (used at boot + when a transitional card's session is found alive): read back `sessions.stampedEpoch(name:)`; adopt to `.live` ONLY on `== card.sessionEpoch`; a `relaunching` card with an older-epoch session is never adopted — the RelaunchStepper completes the relaunch (kill + launch).
- [ ] **Step 9 — Run green.**

### Startup phase reconciliation + boot order

- [ ] **Step 10 — Failing test** `test_startupReconcilesInFlightPhases`: a persisted `creatingWorktree`/`launching` card in a fresh process (`TestEnv.remake`) is re-driven to `.live` or, if unrecoverable, `dead(.spawnFailed)` — no stuck-Creating (bug #5). Run red.
- [ ] **Step 11 — Implement.** Add `func reconcilePhasesAtBoot() async` = one reconciliation pass over all cards from persisted phase: adopt sessions on epoch-identity match; re-drive transitional phases via the steppers; terminal cards need nothing except `archivedPending` → Teardown re-drive. **`recoverSessions` overlap (Opus finding 9 — commit): FOLD `recoverSessions`'s resumable-revival into `reconcilePhasesAtBoot`.** A `.live`-persisted card whose session died while the daemon was down is transitioned to `.relaunching` (routing through the funnel intent) and the RelaunchStepper drives it — one owner, guarded by `inFlightSteps` so nothing double-drives. A non-resumable never-prompted card → `.creatingWorktree` (blank restart intent); an unrecoverable card → `dead(.rebootUnrevived)`. Delete the standalone `recoverSessions` loop (its windowed-revival cap is superseded by the reconciler's `inFlightSteps` + backoff). Set boot order in `main.swift:47-53`: `sweepOrphanScratch → stampMigratedWorktreeMarkersOnce → reconcilePhasesAtBoot → sweepOrphanBorrows(cards) → watch-registry reload → rebuildRemoteWatches → rebuildMergeRequestNudges → treeStat recompute`.
- [ ] **Step 12 — Run green.**

### Durable watch registry — carries requirement #4

- [ ] **Step 13 — Failing test** `test_mcpWatchSurvivesRestart`: an MCP `wait` watcher survives a daemon restart (`remake`) — the registry is persisted + reloaded; a watched child **already terminal at reload** delivers its conclusion immediately. Run red.
- [ ] **Step 14 — Implement.** New `WatchRegistryStore.swift`: atomic-JSON `[String: [String]]` (watcher uuid → child uuids) beside the inbox (mirror `WorktreeRegistry`'s borrow persistence pattern — `replaceItemAt`, load-fail distinguished from absent). Route **EVERY** `watchRegistry` mutation (`:60`) through the persisted store — not only `registerWatch` (`Wake.swift:9-11`) / `unregisterWatch` (`:67-69`) but also **`concludeCard`'s inline remove** (`Wake.swift:95-96`) which mutates `watchRegistry` directly (Opus finding 5 — miss it and a concluded child stays registered on disk → duplicate conclusion on the next boot reload). Collapse that inline remove to call `unregisterWatch`. At boot (after phase reconciliation) reload + deliver conclusions for already-terminal children.
- [ ] **Step 15 — Run green.**

### Corrupt-store recovery + conservative mode — carries requirement #3

- [ ] **Step 16 — Failing test** `test_corruptTasksJsonRecovers`: an unparseable top-level `tasks.json` is renamed `tasks.json.corrupt-<ISO8601>` (**timestamped** — a second corruption must not clobber the first backup), logged; the daemon boots empty in **conservative mode** — `worktrees.release()` (and the Teardown scratch reclaim) perform **no removals**. `test_conservativeModePersistsForDaemonLifetime` (GPT-5.5 R2 finding 3): after a corrupt boot, a fresh spawn + archive in the SAME daemon session still removes nothing (conservative mode is NOT cleared by a `store.create`/`store.update`/report); a subsequent **clean restart** (`remake` over a now-healthy store) boots with conservative mode OFF and normal reclaim resumes. Run red.
- [ ] **Step 17 — Implement.** In `TaskStore.load` (the existing `.bak`-on-top-level-unparseable path), rename to `tasks.json.corrupt-<ISO8601>` and expose a `loadWasCorrupt` signal. At boot, when corrupt, call `worktrees.setConservativeMode(true)` (the PR3b seam — gates `release()` at `WorktreeRegistry.swift:407`; also gate the Teardown scratch reclaim on it, Task 1 Step 12). **Conservative-clear trigger (GPT-5.5 R2 finding 3 — reframed to the unambiguously fail-safe model): conservative mode stays ON for the ENTIRE lifetime of a corrupt-boot daemon; it is cleared only by a subsequent CLEAN restart** (a normal boot from a healthy `tasks.json` never sets it). Rationale: after a corrupt `tasks.json` the pre-existing trees' ownership is genuinely unknowable from an empty board — no in-session write "proves" ownership of a tree cut before the corruption, so any auto-clear risks removing a tree a pre-crash live session still uses. Leaking a worktree is the fail-safe direction (vs data loss) and is restart-healed (a clean boot re-establishes the card↔tree map and clears the mode; a later `ensure` prunes a truly-orphaned clean tree). This is simpler and strictly safer than the store.create trigger — **recorded as a deliberate simplification of the vault's "until ownership is positively re-established" (the clean restart IS that re-establishment).**
- [ ] **Step 18 — Run green** — full `swift test`.
- [ ] **Step 19 — Commit** `feat(converge): reconciler driving discipline; epoch-identity adoption; durable watch registry; conservative recovery`

---

## Task 3 — Non-blocking spawn + the ~30-file test migration

**Deliverable:** spawn's sync part shrinks to persist + `transition(.creatingWorktree)` + return `(card, rev)`; the reconciler drives it to `.live`. `spawnAndAwaitLive` helper + the migration of every spawn-then-assert test.

**Files:** `OrchestraService.swift` spawn (`:286-498`); `Tests/OrchestraCoreTests/Stubs.swift`; ~30 test files; `Tests/IntegrationTests/E2EBinaryTests.swift`; Test `StepperTests.swift`

- [ ] **Step 1 — Failing test** `test_spawnReturnsBeforeProvisioned`: with `blockEnsure` armed, the spawn RPC returns a card in `.creatingWorktree` (cwd set) while `ensure` is still blocked; a concurrent `list()` answers promptly (actor not frozen). `test_spawnStepperCrashRestart` (**both agents**): `remake` between `creatingWorktree`→`launching` and `launching`→`live`; on `reconcile`, `verify` becomes true (tree materialized, session up, no duplicate cards/sessions). `test_spawnFailureClassified`: a checkout failure → `dead(.spawnFailed)` with git stderr in `deadDetail`; a timeout → explicit "timed out after Ns". Run red.
- [ ] **Step 2 — Implement.** Shrink `spawn` to its synchronous, must-fail-fast core (the full materialization already lives in the MaterializeStepper from Task 1 — this task just flips spawn to stop walking it inline): resolve+**allowlist** the repo (security gate — must reject a non-allowlisted repo BEFORE creating anything); scratch-mkdir / borrowed-cwd resolution (cheap, no subprocess); compute `cwd = worktrees.path(repo:branch:)` (pure, no checkout); resolve agent/model/origin/title/landing; `store.create(task)` at `.creatingWorktree, sessionEpoch: 1` carrying the base/remote-ref inputs the stepper needs; `emit` + `emitActivity(.spawned)`; return `(created, rev)`. **Delete** the inline `launchAndConfirm` walk (Task 2.5's interim synchronous path), the inline `worktrees.ensure`/remote-fetch/lineage-record/rollback (now the stepper's), and the inline `dead(.spawnFailed)` catch. Preserve the client-minted-id idempotency contract (a retried spawn returns the existing card as-is — full wiring PR6a; the schema stands).
- [ ] **Step 3 — Migration helper (pin the readiness-cap contract — Opus finding 7).** Add `TestEnv.spawnAndAwaitLive(_ svc:_ input:)`: `spawn`, then drive `reconcile()` in a poll loop (~3s cap) until `phase == .live`. **The driver must resolve readiness for the fixture's adapter cap:** the default stub adapter is `.relaunchLiveness` (readiness = successful `ensure`, immediate — the loop's `reconcile` ticks suffice). For a **both-agent** variant, `.sessionStartHook`/`.rolloutMeta` caps need either the N=3 `launchReadyTicks` fallback (guaranteed by ticking `reconcile` ≥3× — now `inFlightSteps`-independent per Task 2 finding 2) OR an injected readiness signal (`report(sessionSource:)`). Provide `spawnAndAwaitLive` (relaunchLiveness/N=3 path) AND `spawnAwaitedAndAwaitLive` (injects the hook), mirroring today's `spawnAwaited`/`reconcileUntilLive` split. State the contract in the helper doc-comment. The CLI E2E smoke test polls `sessions <id> --json` for the `:agent` window (~15s cap) before driving `exec`.
- [ ] **Step 4 — Migrate the ~30 spawn-then-assert files.** Every test that spawns then asserts on post-launch state (RecoveryTests, ReopenTests, WakeMergeWatchTests, OrchestraServiceTests, SpawnRaceTests, ScratchSpawnTests, BorrowedSpawnTests, LineageSpawnTests, SpawnBaseTests, SpawnPhaseTests, …) switches to `spawnAndAwaitLive` (or explicit `reconcile` drives). Sweep with `grep -rln "\.spawn(" Tests/` and audit each for a post-`.live` assumption. Tests that already use `spawnAwaited`/`reconcileUntilLive` may need re-pointing at the new driver.
- [ ] **Step 5 — Run green** — full `swift test`.
- [ ] **Step 6 — Commit** `feat(converge): non-blocking spawn (reconciler-driven) + spawnAndAwaitLive test migration`

---

## Task 4 — Relaunch/Teardown verb flips + carried requirement #5

**Deliverable:** archive/reopen/resume/restart/handoff become **intent-only** verbs (transition + return); the reconciler drives the steppers. Retire the `gatedKind` Bool-bridge, tighten `isLegalEdge`, epoch-fence reopen resume-finalize, capability-gate restart-blank under the stepper, give verb-vs-verb restart a single-winner. Persist `pendingSeed` on handoff (carried #1 write side).

**Files:** `OrchestraService.swift` (`archive:720`), `OrchestraService+Recovery.swift` (`reopen:204`, `resume:66`, `restart:143`), `OrchestraService+Lifecycle.swift` (`isLegalEdge:111`), `CommandRegistry.swift` (`gatedKind:64`), `Inbox.swift`; Test `StepperTests.swift`, `ReopenTests.swift`, `ArchiveOriginTests.swift`, `PhaseTransitionTests.swift`, `VerbContractTests.swift`

### Archive → funnel (retire the Bool-bridge)

- [ ] **Step 1 — Failing test** `test_archiveIsIntentOnly`: `archive` returns after `transition(.archivedPending)` (companion `mutate { $0.archived = true }` so the card leaves the board instantly) — the duty list runs on the reconciler; polling `reconcile` reaches `.archivedComplete`. `test_reArchiveIsIdempotent`: archiving an already-`archivedPending` OR `archivedComplete` card returns `.ok()` success (NOT a `phaseGated` error and NOT a `.rejected` illegal-edge error) — the idempotency guarantee (spec §P1/§6/§11). `test_gatePolicyConformance` updated so an archived card gates via `card.phase.kind` (no Bool-bridge) and `archive.phaseGate` stays `gAll` (so the gate never denies an idempotent re-archive). Supersede races `test_archiveDuringMidCheckout` / `test_archiveDuringLaunching` / `test_archiveRacesLaunch_reclaimsSession` — **each × worktree / scratch / borrowed**: archive landing at each launch-bound phase → the funnel takes the card to `archivedPending`; the stepper's resource epilogue or the orphan-session sweep reclaims the session within a tick; a late `→ .live` is funnel-rejected (illegal from `archivedPending`). Run red.
- [ ] **Step 2 — Implement.** Rewrite `archive()` sync part: **idempotency guard first** — `if card.phase.kind == .archivedPending || card.phase.kind == .archivedComplete { return }` (an already-archived card is idempotent success; without this, my tightened `isLegalEdge` makes `archivedComplete → archivedPending` illegal → a `.rejected` error, breaking the retried-archive guarantee — the archive HANDLER is the idempotency point, per the PR4a decision that keeps `archive.phaseGate = gAll`). Then `transition(id, to: .archived(teardownComplete: false), mutate: { $0.archived = true })` + return. The full duty list (kill/releaseBorrow/release/cancel-loops/nudge-children/flip) moves to the TeardownStepper (Task 1) — delete it from `archive()`. The manual `concludeCard(.done)` goes away (the funnel concludes on the non-terminal→`archivedPending` entry). **Retire `gatedKind`'s Bool-bridge** → `static func gatedKind(of card: Task) -> Phase.Kind { card.phase.kind }` (per PR4a's "As-built deviations" note in `02-contract.md`; the gate SETS are unchanged — `archive.phaseGate = gAll`, `reopen` gate stays `{archivedPending, archivedComplete, …}`). Keep `phaseGate` typed `Set<Phase.Kind>` (Phase isn't Hashable — PR4a decision).
- [ ] **Step 3 — Run green.**

### Reopen / resume / restart / handoff → intent-only + carried #1 + single-winner
> **Ordered BEFORE the `isLegalEdge` tightening (Opus finding 3):** reopen's `dead→archivedComplete` normalize (`+Recovery.swift:212`) uses an edge the tightening removes — so remove the normalize (here) before making that edge illegal (below), else Step "run green" hits a red window on any reopen path/fixture still on the legacy `.dead(.completed)+archived` shape.

- [ ] **Step 4 — Failing test** `test_reopenCrashRestart`: reopen enqueues intent (`transition(.creatingWorktree)`, epoch++) + returns; a `remake` mid-checkout re-drives to `.live` **as a resume** (transcript preserved — launch-flavor rule); the actor is never blocked during checkout. `test_handoffSeedSurvivesCrash`: handoff persists `pendingSeed` (incl. folded drained-inbox) in the **same patch** as `transition(.relaunching)`; `remake` before launch → the re-driven relaunch delivers the seed; a `resumeFailed` keeps it. `test_restartSingleWinner` (**reframed per Opus finding 11**): two `restart`s for the same card → the second's `transition(.relaunching)` supersede self-edge bumps the epoch; the reconciler's `inFlightSteps` admits ONE step; only one session survives; the earlier attempt's `→.live` finalize is epoch-fenced to a no-op (the single-winner comes from the epoch bump + `inFlightSteps`, NOT competing stepper instances). Run red.
- [ ] **Step 5 — Implement.** Flip each verb's sync part to transition-only + return:
  - `reopen` → **remove the `.dead(.completed)`→`.archived` normalize** (archived cards are already `.archived(_)` after the Archive-→-funnel rewrite + the migration seeds legacy archived as `.archived(teardownComplete:true)`); `transition(.creatingWorktree, mutate:)` (epoch++ closes the ghost-SessionEnd window) carrying the resume-vs-blank persist block; MaterializeStepper→LaunchStepper drive it. The LaunchStepper's `.live` finalize is `observedEpoch`-fenced (carried #5 "epoch-fence reopen resume-finalize").
  - `resume`/`handoff` → `transition(.relaunching, mutate:)`; **handoff/seeded-wake persist `pendingSeed`** (folded seed) in that same patch (carried #1 write side); the RelaunchStepper consumes+clears it on readiness.
  - `restart` → `transition(.relaunching, mutate: { fresh id / rolled prior ids / provisional / cleared dead+desc })`; the RelaunchStepper's blank launch is **capability-gated** (goes through `confirmReadiness`, not immediate `.live` — carried #5 item 4). The `relaunching→relaunching` supersede self-edge + `inFlightSteps` give the single-winner (carried #5 item 5).
  - Delete the now-dead inline off-actor bring-up in `resume`/`restart`/`reopen` (`+Recovery.swift`) — the steppers own it. (`recoverSessions` was already folded into `reconcilePhasesAtBoot` in Task 2 — nothing left here calls it.)
- [ ] **Step 6 — Migrate affected tests** (ReopenTests, HandoffResumeTests, RecoveryTests, WakeMergeWatchTests, ArchiveOriginTests) to drive `reconcile` after the intent verb. Run green.

### Tighten `isLegalEdge` (AFTER the reopen/archive rewrites)

- [ ] **Step 7 — Failing test** update `test_illegalEdgesRejected`: remove the direct `(X, .archivedComplete)` edges for X ∈ {creatingWorktree, launching, live, relaunching, dead} from the legal set (a card reaches `.archivedComplete` ONLY via `archivedPending → archivedComplete`, the stepper). Keep: any non-archived → `archivedPending`; `archivedPending → archivedComplete`; `archivedPending/archivedComplete → creatingWorktree` (reopen); `dead → relaunching`; `dead → live` (viaSignal). Run red.
- [ ] **Step 8 — Implement.** Edit `isLegalEdge` (`OrchestraService+Lifecycle.swift:126-137`): drop the `(*, .archivedComplete)` direct arms except `(.archivedPending, .archivedComplete)`. Verify no other caller drives a direct `*→archivedComplete` — reopen's normalize is now gone (Step 5); the migration seeds `.archivedComplete` in `Task.init` (decode, not a funnel edge — unaffected). Run green.
- [ ] **Step 9 — Commit** `feat(converge): intent-only relaunch/teardown verbs; retire Bool-bridge; tighten isLegalEdge; pendingSeed durability`

---

## Task 5 — The matrix + crash-recovery test battery (4.6)

**Deliverable:** the gate-soundness + stepper crash-convergence + adopt/reboot/missed-hook/conclude battery, all green (both agents where lifecycle is exercised).

**Files:** `Tests/OrchestraCoreTests/VerbContractTests.swift`, `StepperTests.swift`

- [ ] **Step 1 — Test A (gate soundness)** `test_gatePolicyConformance`: every Mutation/Convergence verb's declared allow-set matches spec §6 default policy (+ documented exceptions: `archive.phaseGate = gAll` per PR4a's idempotency decision); probe one denied phase per verb through the real dispatcher.
- [ ] **Step 2 — Test B (stepper crash-convergence).** `test_everyStepperConvergesFromAnyBoundary` **explicitly enumerated as `agent × boundary`** (GPT-5.5 finding 3), swift-testing parameterized `@Test(arguments:)` over the cross-product `[.claudeCode, .codex] × [creatingWorktree, launching, live, relaunching, dead, archivedPending, archivedComplete]`: drive the phase, `remake` (crash) at that `step` boundary, re-run `reconcile`, assert convergence. **Per-cell oracle (Opus finding 10 — only 4 kinds have a stepper):** the four transitional kinds (`creatingWorktree`/`launching`/`relaunching`/`archivedPending`) assert `PhaseSteppers.byKind[kind].verify == true`; the three non-stepper kinds assert their steady-state oracle instead — `live` → session adopted at matching epoch (no duplicate); `dead` → stays `dead`, its session not swept if `dead(.completed)`; `archivedComplete` → terminal, no re-drive, no duplicate teardown. Every cell is a named case with an explicit oracle; no cell asserts a nonexistent stepper.
- [ ] **Step 3 — Test C (adopt-don't-relaunch)** `test_daemonCrashAdoptsLiveSession` (epoch-identity match), `test_launchingAdoptsSurvivingSession` (no duplicate session/card), `test_machineRebootPath` (tmux gone: resume per capability or `dead(.rebootUnrevived)`).
- [ ] **Step 4 — Test D (missed readiness)** `test_launchingMissedHookConvergesViaLiveness` (already in Task 2 — assert here it lives in the battery + the `N×tick < sessionLaunchTimeout` inequality holds).
- [ ] **Step 5 — Test E (conclusion + idempotency)** `test_waitShortCircuitsOnPersistedTerminalPhase` (inline conclusion **and** the watch entry is unregistered — a later archive of the same child produces no duplicate); `test_batchSpawnRetryIsIdempotent` (per-item ids; partially-acked batch retried → no duplicate cards — the schema lands here, full wiring PR6a).
- [ ] **Step 6 — Run** — all green (they exercise Stages 2–4). Fix any gaps.
- [ ] **Step 7 — Commit** `test(converge): gate-soundness + stepper crash-convergence + adopt/reboot/missed-hook/conclude battery`

---

## Task 6 — Docs (4.7)

- [ ] **Step 1** Update `docs/05-command-reference.md` — the verb taxonomy (Query / Mutation / Convergence; intent-only verbs; the phaseGate policy).
- [ ] **Step 2** Update `docs/02-architecture.md#request-flow-server-side` + `#the-daemon-orchestrad` — the Convergence model (funnel + reconciler + four steppers + boot order + epoch-identity adoption + conservative recovery).
- [ ] **Step 3 — Commit** `docs(lifecycle): verb taxonomy + convergence model`

---

## Named-test traceability (04-tests.md crash/race battery + brief → home task + both-agent)

Every test named in `04-tests.md`'s crash/race battery and the brief, mapped to its task. **BA** = must run for both `claude-code` AND `codex`.

| Test | Task | BA |
|---|---|---|
| `test_stepperStepIsIdempotent`, `test_launchFlavorDerivedFromState` | 1 | — |
| `test_convergeContextTransitionAppliesMutate`, `test_spawnBaseCarrierRoundTrips` | 1 (Step 0) | — |
| `test_materialize*` (advances/failure/remoteFetch/lineageRollback/staleChildPrune/resourceEpilogue) | 1 | — |
| `test_launchStepReachesLiveOnReady`, `test_launchConsumesPendingSeed` | 1 | **BA** |
| `test_relaunchStepKillsThenEnsures`, `test_relaunchReMaterializesMissingWorktree`, `test_relaunchBranchGoneFailsSafe` | 1/4 | **BA** |
| `test_teardownFullDutyList`, `test_teardownRedriveNoDuplicateNudges` | 1/4 | — |
| `test_strandedTransitionalCardRedriven` | 2 | **BA** |
| `test_stepFailureBacksOff` | 2 | — |
| `test_launchTimeoutSurvivesCrash`, `test_launchingMissedHookConvergesViaLiveness` (asserts `N×tick < sessionLaunchTimeout`) | 2 | **BA** |
| `test_orphanSessionSwept`, `test_preKillProbeIsFresh`, `test_preKillProbeOffActor` | 2 | — |
| `test_adoptionChecksEpochIdentity` | 2 | **BA** |
| `test_startupReconcilesInFlightPhases` | 2 | **BA** |
| `test_mcpWatchSurvivesRestart` | 2 | — |
| `test_corruptTasksJsonRecovers` | 2 | — |
| `test_spawnReturnsBeforeProvisioned`, `test_spawnFailureClassified` | 3 | — |
| `test_spawnStepperCrashRestart` | 3 | **BA** |
| `test_archiveDuringMidCheckout`, `test_archiveDuringLaunching`, `test_archiveRacesLaunch_reclaimsSession` (× worktree/scratch/borrowed) | 4 | **BA** |
| `test_reArchiveIsIdempotent`, `test_archiveIsIntentOnly` | 4 | — |
| `test_reopenCrashRestart` | 4 | **BA** |
| `test_handoffSeedSurvivesCrash`, `test_restartSingleWinner` | 4 | **BA** |
| `test_illegalEdgesRejected` (tightened), `test_gatePolicyConformance` | 4/5 | — |
| `test_everyStepperConvergesFromAnyBoundary` (agent × 7 boundaries) | 5 | **BA** |
| `test_daemonCrashAdoptsLiveSession`, `test_launchingAdoptsSurvivingSession`, `test_machineRebootPath` | 5 | **BA** |
| `test_waitShortCircuitsOnPersistedTerminalPhase` (+ unregister), `test_batchSpawnRetryIsIdempotent` (schema) | 5 | — |

If, when a task is reached, a named battery test above has no concrete home, that is a plan gap to close in that task (do not silently drop it).

**Both-agent (BA) rule + exception rationale (GPT-5.5 R2 finding 4).** The doctrine is "every lifecycle test runs for both agents." **BA is REQUIRED for every test that exercises an agent-conditional code path** — anything touching launch/relaunch/readiness (`capabilities.readinessConfirmation` branches: Claude `.sessionStartHook`, Codex `.rolloutMeta`, `.relaunchLiveness`) or session bring-up: all the spawn/launch/relaunch/reopen/adoption/missed-hook/archive-race/stranded-redrive tests. **Single-agent is allowed ONLY where NO agent-conditional path is exercised**, and each such test is single-agent for a stated reason: funnel-edge/`isLegalEdge`/gate-policy tests (pure `Phase` logic, no adapter), watch-registry + corrupt-store + config persistence (no adapter), orphan-session sweep + pre-kill probe (session-name + epoch, agent-agnostic), materialize failure/backoff (git checkout is identical for both agents), teardown duty list (kill/release/nudge don't branch on agent), re-archive idempotency (funnel), batch-spawn schema. If any of these grows an agent-conditional branch during implementation, promote it to BA.

## Vault fold-back (do before the merge-request)

Fold these as-built deviations into `notes/designs/lifecycle-convergence/03-implementation.md` + `02-contract.md` "Decisions made" tables, and list them in the merge-request:
- The enabler-before-consumer task reordering (steppers → reconciler-driving → non-blocking spawn → verb flips).
- `archived` Bool stays as a companion mirror written in the same funnel patch as `.archivedPending` (the field is not fully derived — 74 readers depend on it); the Bool-bridge retired is specifically `gatedKind`'s special-case.
- `isLegalEdge` tightening removes direct `*→archivedComplete` (stepper-only via `archivedPending`).
- The exact "ownership positively re-established" trigger for clearing conservative mode.
- `SessionManaging.stampedEpoch` added to the protocol (default `nil`) for the reconciler's adoption probe.
- Any stepper-helper extraction from `launchAndConfirm`/`resume`.

## Open design questions — RESOLVED in review (round 2)

1. **Spawn's pre-checkout work split — RESOLVED (Opus finding 1/4).** Spawn keeps the synchronous must-fail-fast parts (repo allowlist resolve — security gate; scratch mkdir; base normalization), computes `cwd = worktrees.path(...)` (pure, no checkout), and persists `spawnBase: String?` on the card. The `materialize(id:)` actor callback (wrapped by `ConvergeContext.materialize`) does remote-fetch + `ensure` + lineage recording + S2-3(iii) rollback; a remote-fetch failure classifies `dead(.spawnFailed)` like a checkout failure.
2. **`cwd` before checkout — CONFIRM at impl.** The card is `.creatingWorktree` with `cwd = worktrees.path(...)` before the tree exists. Every `cwd` reader must tolerate a not-yet-materialized dir while `.creatingWorktree` (the gate denies shell/inspect on being-born phases; `pollTelemetry` skips non-live; `release`/`sweepOrphanScratch` are guarded). Verify each reader during Task 3.
3. **`recoverSessions` vs `reconcilePhasesAtBoot` — RESOLVED (Opus finding 9).** FOLD `recoverSessions`'s resumable-revival into `reconcilePhasesAtBoot` (one owner; `inFlightSteps`-guarded); delete the standalone loop.

## Self-review checklist (run before handing off)

1. **Carried requirements 1–5** each have a gating test that fails before / passes after their task.
2. **Both agents** on every stepper crash test (`test_spawnStepperCrashRestart`, `test_everyStepperConvergesFromAnyBoundary`, readiness tests).
3. **Non-blocking**: no verb awaits a subprocess before returning; `test_spawnReturnsBeforeProvisioned` + `test_preKillProbeOffActor` prove the actor stays live.
4. **Fail-safe**: no kill without a fresh epoch probe; no adopt of an old-epoch session; conservative mode removes nothing.
5. **Suite green after every task** (`swift test`), not just at the end.
6. **Supersede races** cover worktree / scratch / borrowed each.
