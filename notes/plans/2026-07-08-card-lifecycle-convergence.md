# Card Lifecycle Convergence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Orchestra's multi-variable, edge-triggered card lifecycle with one persisted `phase`, a single transition funnel, per-launch epochs, and an idempotent reconciler — killing 15 confirmed lifecycle bugs (plus the adversarial-review round's findings).

**Architecture:** State-triggered + convergent. One persisted `Phase` per card written only through a `transition()` funnel that validates edges and reports `applied`/`noop`/`rejected`; a per-launch `sessionEpoch` (stamped into sessions as `ORCH_EPOCH`, readable back) makes stale signals harmless; verbs only transition — the reconciler drives **phase-keyed steppers** (Materialize/Launch/Relaunch/Teardown) with `phaseChangedAt`-based timeouts; a `WorktreeRegistry` actor is the sole owner of git worktrees (incl. borrows, with persisted registrations); a monotonic board `rev` + client-minted ids + RPC deadlines make sync gap-detectable and manual re-issue safe.

**Tech Stack:** Swift (Swift Concurrency actors), swift-testing / XCTest (`swift test`), tmux, git worktrees, newline-JSON-RPC over UDS.

**Companion design spec:** `notes/designs/2026-07-08-card-lifecycle-convergence.md` (read it first — it is the contract this plan implements). All §/P references below point there.

## Global Constraints

- **Agent-agnostic.** No `if agentId == "claude"` in shared code. Every mechanism is gated on `adapter.capabilities.*`. Every lifecycle test runs for **both** `claude-code` and `codex` (today's provisioning tests are Claude-only — fix that).
- **Break the wire freely; no cross-version interop.** Ship the daemon + all clients together. `phase`/`sessionEpoch`/`rev` are **required** fields; client-minted `id` is **required**; `AgentStatus`/`waitReason` are **removed** (folded into `phase`). `Event`/`BoardSnapshot` may be restructured freely. The **only** compat kept is a one-time defaulting read of an existing on-disk `tasks.json` so Allen's live board survives the upgrade (seed `phase` from the old `status`, then drop `status`).
- **Single service actor.** Keep the one `OrchestraService` actor. No per-card executors. All subprocess/file IO hops off-actor via `offActor` (or lives on a dedicated actor like `WorktreeRegistry`).
- **Full test suite (~680 tests) stays green** after every task. Full run: `swift test`. Never leave a stage red.
- **Fail-safe defaults.** Never kill without a fresh epoch-stamped probe; never force-remove a dirty/shared worktree; never remove a path outside the registry's owned roots; on ambiguity, keep the card and the tree.
- **Test doctrine (from the review):** race/crash coverage comes from **deterministic stub tests** (blockable `ensure`, sleep-injecting session stubs, kill-at-step hooks — extend `Tests/OrchestraCoreTests/Stubs.swift` with `blockEnsure`/`ensureSleepMs`/`isAlive`/`removed`/`killed`/`ensureArgv` recorder seams); E2E variants are smoke, not proof (the review found an E2E "regression test" that passed on unfixed code).
- **Anchor provenance:** all `file:line` anchors below were re-verified against `main` @ `f1aa568` (2026-07-09). Symbols are stable; if a line has drifted again by execution time, search the symbol.

## How to read this plan (granularity note)

Steps follow strict TDD rhythm (write failing test → run red → implement → run green → commit). Each test step gives the **concrete test name + the assertion**. Type shapes, enum cases, and function signatures are **exact** (they come from the approved spec). For implementation *bodies* that depend on surrounding code, the step states the precise mechanism, the signature, and the key logic to write — the executor writes the body against the real file, guided by the cited `file:line` anchors. This is deliberate: fabricating line-exact bodies for a migration of this size would mislead. Where a step says "patch X to do Y", the anchor tells you exactly where.

## File structure (whole effort)

| File | Responsibility | Stage |
|---|---|---|
| `Sources/OrchestraKit/Model.swift` | Add `Phase` enum (incl. `archived(teardownComplete:)`), `RunState` (incl. `waiting(WaitReason)`), extend `DeadReason` with `.completed`/`.spawnFailed`; add `phase`/`sessionEpoch`/`phaseChangedAt`/`pendingSeed` to `Task`; **remove `status`/`waitReason`**; add `rev` to `Event`/`BoardSnapshot`; required client `id` on `SpawnInput` (+ per-item batch ids) | 1,2,4,6 |
| `Sources/OrchestraKit/CommandCatalog.swift` | Extend `CommandSchema` with `kind`/`phaseGate` (shared verb metadata; `displayState.validActions` derives from it) | 4 |
| `Sources/OrchestraCore/OrchestraService.swift` | Host the `transition()` funnel; delete the `recovering` set; off-actor sweep | 2,5 |
| `Sources/OrchestraCore/OrchestraService+Lifecycle.swift` (new) | The `transition()` funnel + `Phase` machine + epoch guard | 2 |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | Reconciler driving discipline (step transitional phases, orphan-session sweep, `phaseChangedAt` timeouts, backoff); pre-kill fresh probe; startup reconciliation w/ epoch-identity adoption | 4 |
| `Sources/OrchestraCore/PhaseStepper.swift` (new) | Stateless `PhaseStepper` protocol + `ConvergeContext`; phase-keyed steppers (Materialize/Launch/Relaunch/Teardown) | 4 |
| `Sources/OrchestraCore/WorktreeRegistry.swift` (new) | Actor: serialized `ensure`/`release`, on-demand sibling counts, materialized marker (+ fail-safe marker-less arms), one removal policy, borrow-tree lifecycle (persisted registrations), path safety | 3 |
| `Sources/OrchestraCore/WorktreeManager.swift` | Bounded git (all invocations take the Config knobs); called only by the registry | 3 |
| `Sources/OrchestraCore/Config.swift` | **New wall-clock timeout knobs** (`worktreeAddTimeout` 600s / `sessionLaunchTimeout` 30s / `controlTimeout` 15s), additive-optional decode | 3 |
| `Sources/OrchestraCore/TaskStore.swift` | Board `rev` stamping (1); corrupt-recovery + conservative mode (4); telemetry-persist debounce (5) | 1,4,5 |
| `Sources/OrchestraCore/OrchestraService+Report.swift` | Field-delta write (kill `$0 = task`); epoch-stamped signals | 1,2 |
| `Sources/OrchestraCore/CommandRegistry.swift` | Classify verbs; the `phaseGate` dispatch-time enforcement chokepoint | 4 |
| `Sources/OrchestraCore/Control/ControlServer.swift` | Stamp `rev` on notifications + snapshot; dedup client-minted id | 1,6 |
| `Sources/OrchestraCore/Inbox.swift` + new `WatchRegistryStore.swift` | Inbox `dedupKey`; persisted watch registry (reload + terminal short-circuit at boot) | 4 |
| `Sources/OrchestraKit/Control/ControlClient.swift` | Per-RPC deadline; ping keepalive; `rev` gap detection → resync | 6 |
| `Sources/OrchestraUI/BoardStore.swift` | Apply-iff-`rev` merge; `displayState`; honest toasts | 6 |
| `Sources/OrchestraKit/AgentCapabilities.swift` | (read/extend) readiness capability already exists (`resumeConfirmation`) | 2 |
| `App/Views/AgentTerminalView.swift` | Mac terminal bounded-backoff retry loop (copy iOS) | 6 |
| `Tests/OrchestraCoreTests/*`, `Tests/IntegrationTests/*` | Phase-edge, epoch, stepper-crash, adoption-identity, teardown-durability, rev-gap, idempotency, slow-repo, agent-agnostic tests | all |
| `docs/02,03,04,05,09` | SSOT updates | per stage |

---

## Stage 0 — DISSOLVED (base decision, 2026-07-09)

> **The branch is discarded; build fresh on `main`.** The original brief scoped a P0-hotfix card on `fix/spawn-hang-standalone`. Allen's decision (2026-07-09) is to **rebuild the phase model fresh on `main` and discard that branch** — so there is nothing to hotfix. The three P0 concerns are satisfied **by construction** in the fresh build:
>
> | Original P0 hotfix | Satisfied by construction in |
> |---|---|
> | Sibling/dirty guard in provision cleanup (no force-remove of dirty/shared trees) | **Stage 3** — `WorktreeRegistry.release()` is the single removal policy (sibling scan + dirty guard + idempotent-to-missing) |
> | Conclude on `spawnFailed` so a parent `wait` resolves | **Stage 2** — the funnel concludes on entering *any* terminal phase + `isConcluded ≡ terminal phase` |
> | `openShell`/`inspect` must not claim the agent session while provisioning | **Stage 4** — the verb `phaseGate` (denying `creatingWorktree`/`launching`/`relaunching`) ships in the same stage as non-blocking spawn, so the window and its gate land together |
>
> **Mine, don't merge.** The branch was mined exhaustively at finalization (2026-07-09): all 19 of its hard-won failure modes are mapped into this plan — the headline ones as named tests (`test_archiveRacesLaunch_reclaimsSession` from `28cedb5`, `test_archiveDuringMidCheckout` from `ebcd88e`, the dead-card-never-"Creating…" displayState assertion from `2d6bca9`, the stranded-message wake from its `wakeIfPending` gap, the timeout-classification tests from `469fdb4`/`a3f04f9`, the `spawnAndAwaitLive` test migration from `2830ff0`), the structural ones by construction (phase-gated liveness replaces the whole `recovering`-hold choreography; the funnel's illegal-edge rejection replaces the archived-resurrection guards). The branch and its card (`843718`) can be archived.

---

## Stage 1 — Sync `rev` + delta writes

**Deliverable:** A monotonic board `rev` on every mutation/event/snapshot, and `report()` stops clobbering with whole-object writes.

### Task 1.1: Board `rev` in `TaskStore`

**Files:** Modify `Sources/OrchestraCore/TaskStore.swift`; Test `Tests/OrchestraCoreTests/TaskStoreTests.swift` (create if absent)

**Interfaces produced:** `TaskStore.currentRev: Int` (monotonic, persisted alongside tasks); every mutation returns/stamps the new `rev`.

- [ ] **Step 1 — Failing test.** `test_everyMutationBumpsRev`: `create`, `update`, `move`, `remove` each increase `currentRev` by ≥1 and monotonically; two mutations never share a `rev`.
- [ ] **Step 2 — Run red** (`swift test --filter TaskStoreTests/test_everyMutationBumpsRev`) → FAIL (no `rev`).
- [ ] **Step 3 — Implement.** Add `private(set) var currentRev: Int` to the `TaskStore` actor; increment in the single `persist()` funnel (`TaskStore.swift:55`); persist it in the on-disk payload (wrap the bare `[Task]` array in `{rev, tasks}`). Reading a pre-upgrade bare-array `tasks.json` defaults `rev=0` — this is the on-disk migration read, the one compat we keep.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): monotonic board rev stamped by TaskStore"`

### Task 1.2: `rev` on the event envelope + `boardSnapshot`

**Files:** Modify `Sources/OrchestraKit/Model.swift` (`BoardSnapshot`), `Sources/OrchestraCore/Control/ControlServer.swift`; Test `Tests/OrchestraCoreTests/ControlServerTests.swift`

**Interfaces consumed:** `TaskStore.currentRev`. **Produced:** every `event` notification's params carry `rev: Int`; `BoardSnapshot.rev: Int`.

- [ ] **Step 1 — Failing test.** `test_eventCarriesRev` + `test_boardSnapshotCarriesRev`: the emitted `Event`/`BoardSnapshot` carries a `rev` equal to the store's rev at emit.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Add `rev: Int` to `BoardSnapshot` (`Model.swift:707-722`) and to the `Event` type (restructure it freely — no old clients to placate). Stamp `rev` from `TaskStore.currentRev` at emit.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): carry board rev on events and boardSnapshot"`

### Task 1.3: `report()` field-delta write (kill `$0 = task`)

**Files:** Modify `Sources/OrchestraCore/OrchestraService+Report.swift:133`; Test `Tests/OrchestraCoreTests/RecoveryTests.swift` or a new `ReportTests.swift`

- [ ] **Step 1 — Failing test.** `test_reportDoesNotClobberConcurrentFields`: snapshot a task in `report`, then (simulating provision's flip) mutate an unrelated field in the store, then let `report` persist; assert the concurrently-mutated field is **preserved**, not overwritten by the stale snapshot.
- [ ] **Step 2 — Run red** → FAIL (`$0 = task` clobbers).
- [ ] **Step 3 — Implement.** Replace `store.update(id) { $0 = task }` (`:133`) with a **field-delta patch** that writes only the fields `report` owns (the telemetry/status fields it computed), leaving all others as the store's current value. Keep the `guard task != before else { return }` idempotency gate. Then sweep the repo for any other whole-object `$0 = task`-style writes and convert them — the suite-wide rule after this task is **field-delta patches only** (the branch-tree `treeStat` writers at `+Tree.swift:369-384` already compute inside the closure — leave them; they comply).
- [ ] **Step 4 — Run green** → PASS. Then full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "fix(report): field-delta write so report no longer clobbers concurrent mutations"`

### Task 1.4: Docs

- [ ] **Step 1.** Update `docs/02-architecture.md#request-flow-server-side` + `#the-control-plane` to document the `rev` cursor. Commit `docs(sync): document board rev on events/snapshot`.

---

## Stage 2 — Phase enum + transition funnel + epochs

**Deliverable:** One persisted `Phase`, one `transition()` writer with edge validation + epoch guard + `TransitionResult`; the `recovering` set deleted; `AgentStatus`/`waitReason` **removed** (folded into `phase`), with a one-time on-disk migration. Spawn stays synchronous here (non-blocking lands in Stage 4).

### Task 2.1: `Phase`/`RunState` types + extended `DeadReason`

**Files:** Modify `Sources/OrchestraKit/Model.swift`; Test `Tests/OrchestraCoreTests/ModelCodableTests.swift`

**Interfaces produced:**
```
enum RunState: Codable, Equatable { case running; case waiting(WaitReason) }   // WaitReason folded in here
enum Phase: Codable, Equatable {
  case creatingWorktree, launching                 // creatingWorktree = "materialize cwd" (worktree/scratch/borrowed) — ALL spawns enter here
  case live(RunState)
  case relaunching
  case dead(DeadReason)
  case archived(teardownComplete: Bool)
}
// DeadReason gains: .completed, .spawnFailed  (keeps agentExited/sessionVanished/rebootUnrevived/resumeFailed)
// Task gains: var phase: Phase ; var sessionEpoch: Int ; var phaseChangedAt: Date ; var pendingSeed: String?
//   — and DROPS status + waitReason
```

- [ ] **Step 1 — Failing test.** `test_phaseRoundTrips`: encode/decode every case incl. associated values (`live(.waiting(.permission))`, `dead(.completed)`) via an object `{name, detail?}` encoding.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Add the types; give `Phase`/`RunState` a custom `Codable` encoding as `{name, detail?}`. Add `phase: Phase` + `sessionEpoch: Int` + `phaseChangedAt: Date` + `pendingSeed: String?` to `Task`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): add Phase/RunState(+WaitReason)/epoch to the model"`

### Task 2.2: Remove `status`/`waitReason`; one-time on-disk migration seeds `phase`

**Files:** Modify `Sources/OrchestraKit/Model.swift` (drop `AgentStatus status` + `waitReason` fields), `Sources/OrchestraCore/TaskStore.swift` (migration read); Test `ModelCodableTests.swift`, `TaskStoreTests.swift`

**Interfaces produced:** `Task.init(migratingFrom legacy: LegacyTask)` — seeds `phase` from a pre-upgrade `{status, waitReason, deadReason}` record: `running → live(.running)`, `waiting → live(.waiting(reason ?? .humanTurn))` (**nil `waitReason` is common on idle cards — never route it to the unknown bucket**), `done → dead(.completed)`, `dead → dead(deadReason ?? .agentExited)` (**preserve the persisted reason**), `archived → archived(teardownComplete: true)`.

- [ ] **Step 1 — Failing test.** `test_migratesLegacyTasksJson`: load a pre-upgrade `tasks.json` fixture (cards with `status`/`waitReason`, no `phase` — include a `waiting` card with **nil** `waitReason` and a `dead` card with `deadReason: .resumeFailed`); assert each card gets the correct `phase` per the mapping and no card is dropped. `test_statusFieldRemoved`: the `Task` schema no longer encodes `status`/`waitReason`. `test_migratesUnknownLegacyRecordToSafeTerminal`: a garbage/unknown legacy record maps to `dead(.rebootUnrevived)` — never dropped, never throws. (Marker stamping for migrated cards' worktrees lands with the registry — Task 3.3.)
- [ ] **Step 2 — Run red** → FAIL (fields still present; no migration).
- [ ] **Step 3 — Implement.** Delete `status`/`waitReason` from `Task`. In `TaskStore` load, detect a legacy record (has `status`, lacks `phase`) and run `init(migratingFrom:)` once; subsequent saves write only `phase`. Update all readers of `task.status` to compute from `phase` (or read `phase` directly).
- [ ] **Step 4 — Run green** → PASS. Full `swift test` → green (fix every `task.status` reference).
- [ ] **Step 5 — Commit.** `git commit -m "refactor(lifecycle): remove status/waitReason; migrate on-disk tasks to phase"`

### Task 2.3: The `transition()` funnel + edge validation

**Files:** Create `Sources/OrchestraCore/OrchestraService+Lifecycle.swift`; Test `Tests/OrchestraCoreTests/PhaseTransitionTests.swift`

**Interfaces produced:**
```
enum TransitionResult { case applied; case noop; case rejected(from: Phase, to: Phase) }
extension OrchestraService {
  @discardableResult
  func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil) async -> TransitionResult
  static func isLegalEdge(from: Phase, to: Phase, viaSignal: Bool) -> Bool   // pure, testable; viaSignal admits the dead→live revival edge
}
```

- [ ] **Step 1 — Failing test (property).** `test_illegalEdgesRejected`: for the full phase set, assert `isLegalEdge` returns true exactly for the edges in spec §P1's state machine and false for all others — including the finalized edges: `relaunching → relaunching` true (supersede); `dead(x) → live(y)` true **only** with `viaSignal: true` (revival — verbs can't drive it); `archived(pending) → archived(complete)` true; `relaunching → archived` true.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement `isLegalEdge`.** Encode the machine from spec §P1 as a pure function (a `Set<Edge>` lookup).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Failing test (funnel).** `test_transitionRejectsIllegalEdge`: a *verb-path* `dead → live` returns `.rejected` and leaves the phase unchanged (logged); a legal edge returns `.applied` and persists; `test_transitionNoopIsIdempotent`: transitioning to the current phase returns `.noop` (a retried archive of an archived card is success, not an error).
- [ ] **Step 6 — Implement `transition`.** The **only** writer of `phase`: validate via `isLegalEdge`; return `.applied`/`.noop`/`.rejected` (verbs map `.rejected` to a typed RPC error; async signals ignore the result); stamp `phaseChangedAt` on every applied transition; on entering any launch-bound phase (`creatingWorktree`/`launching`-direct/`relaunching`, incl. the supersede self-edge) increment `sessionEpoch` (**strictly before** any launch work begins); on a **non-terminal → terminal** transition call `concludeCard` (`+Wake.swift:61`) — the wire `Conclusion` carries `{kind, deadReason?}`; `dead → archived` does **not** re-conclude; on entering `live` run `wakeIfPending` (a message sent while the card was being born is delivered here — the single structural release point); persist via `store.update` (patching `phase`/`sessionEpoch`/`phaseChangedAt` only); emit `.taskUpserted`. **Also redefine `isConcluded` (`+Wake.swift:136-140`) as `phase ∈ {dead(*), archived(*)}`** — every terminal counts, so `wait` no longer hangs on `spawnFailed`/`sessionVanished` (the durable bug-#2 fix; a re-issued `wait` after a crash short-circuits on the persisted terminal phase — no stored ack bit) — and **`wait`'s inline short-circuit unregisters the delivered child** from the caller's watch (today it leaks and re-delivers on a later archive). Add `test_sendDuringProvisioningDeliveredOnLive`: `send` to a `creatingWorktree` **and** a `launching` card → inbox holds it; transition to `live` → wake fires. Add `test_deadToArchivedDoesNotReconclude`: a parent watching an already-dead child gets no second conclusion when the child is archived.
- [ ] **Step 7 — Run green** → PASS.
- [ ] **Step 8 — Commit.** `git commit -m "feat(lifecycle): single transition() funnel with edge validation"`

### Task 2.4: Epoch guard for stale signals

**Files:** Modify `OrchestraService+Lifecycle.swift`, `+Report.swift` (SessionEnd path), `+Recovery.swift` (liveness); Test `PhaseTransitionTests.swift`

- [ ] **Step 1 — Failing test.** `test_staleSessionEndIgnored`: card at `sessionEpoch=2`; deliver a `SessionEnd`/liveness signal stamped `observedEpoch=1`; assert `transition` is a no-op (card not killed). Then a signal with `observedEpoch=2` does apply.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** In `transition`, when `observedEpoch != nil && observedEpoch != current sessionEpoch`, drop the signal. **How signals learn their epoch:** (a) the launch env stamps `ORCH_EPOCH=<sessionEpoch>` into the tmux session (in `SessionManager.ensure`'s env plumbing — agent-agnostic, both adapters inherit it); the hook payload echoes it back and `handleHook` passes it as `observedEpoch`; the env is also **readable back** via `tmux show-environment -t <session> ORCH_EPOCH` — expose `sessions.stampedEpoch(name:)` for the reconciler's identity checks (Stage 4); (b) the liveness reconciler stamps each card's `sessionEpoch` into its observed-session snapshot at capture time and passes that as `observedEpoch` when it later acts on the snapshot. **Nil-epoch discipline:** a kill-class signal (SessionEnd/vanished) with nil epoch (pre-upgrade session) never transitions directly — it requires the fresh off-actor pre-kill probe; nil-epoch status signals pass. Thread through the `SessionEnd`/liveness call sites (`+Report.swift:24-31`, `+Recovery.swift:236-243`). Add `test_nilEpochKillSignalRequiresProbe`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): epoch guard makes stale liveness signals harmless"`

### Task 2.5: Delete `recovering`; route spawn/resume/restart through the funnel (spawn stays synchronous)

**Files:** Modify `OrchestraService.swift` (delete `recovering` at `:96`; spawn `:245-451`), `+Recovery.swift` (resume `:55`, restart `:146`, reconcile gate `:241`); Test `DaemonLifecycleTests.swift`, `RecoveryTests.swift`, new `SpawnPhaseTests.swift`

> Notes: (a) the `provisioning` flag/dict exist **only on the discarded branch** — on main there is nothing to delete but `recovering`; (b) spawn stays **synchronous** in this stage — it walks the phases inline during the RPC, so failures classify inline and the stage ships without the Stage-4 reconciler safety net. **Non-blocking spawn is delivered exactly once, in Stage 4** (delivering it here on detached-task scaffolding and rewriting it in Stage 4 is the build-twice churn the base decision rejected — and it would ship a stage where a stuck `launching` card has no driver, no timeout, and no reconciler).

- [ ] **Step 1 — Failing test.** `test_spawnDrivesPhases`: every spawn (worktree/scratch/borrowed) enters `creatingWorktree` (instant for non-worktree cwds) `→ launching → live`, with `sessionEpoch` bumped once and `phaseChangedAt` stamped per transition. `test_livenessSkipsBeingBornPhases`: a session-less card in `creatingWorktree`/`relaunching` is **not** killed by `reconcileLiveness`; a `launching` card whose (already-created, sync-spawn) session has *vanished* → `dead(.spawnFailed)`. `test_promptedSpawnLandsRunning` / `test_provisionalSpawnLandsWaiting`: readiness lands a prompted card at `live(.running)` and a no-prompt card at `live(.waiting(.humanTurn))`. `test_relaunchSupersede`: `restart` during `relaunching` applies the self-edge — epoch bumps again, the first attempt's completion signal (old epoch) is dropped. `test_deadCompletedRevivesOnSignal`: a `dead(.completed)` card with a surviving session revives to `live(.running)` on an epoch-current agent signal; no verb can drive that edge.
- [ ] **Step 2 — Run red** → FAIL / won't compile against old symbols.
- [ ] **Step 3 — Implement.** Replace every `recovering.insert/remove` with `transition(...)` calls; delete the set and `scheduleRecoveringRelease`/`releaseRecovering` (the `.superseded` waiter machinery at `+Recovery.swift:315-327` is subsumed by the supersede self-edge + epochs). Spawn (still sync): `transition(.creatingWorktree)` → materialize cwd inline → `.launching` → launch inline → readiness drives `.live` (async, via 2.6); failure at any inline step → `transition(.dead(.spawnFailed))` with classified `deadDetail` (stderr, or an explicit timeout note). Resume/restart/handoff: `→ .relaunching → .live`; **restart additionally clears `agentSessionId` in the same store patch as its transition** (so a crash mid-relaunch recovers the user's chosen flavor: sid present → resume, absent → blank launch); **handoff/seeded-wake persist `pendingSeed` in that same patch** (drained inbox content folds into it; cleared only on readiness at the current epoch — the seed never exists only in memory). Liveness (`+Recovery.swift:241`): replace the `recovering` gate with the phase rules from Step 1.
- [ ] **Step 4 — Run green.** `swift test` full suite → green (update expectations to phases; spawn is still sync so existing spawn-then-assert tests keep working — the big test migration lands with Stage 4's non-blocking spawn).
- [ ] **Step 5 — Commit.** `git commit -m "refactor(lifecycle): delete recovering set; phases via funnel (spawn still sync)"`

### Task 2.6: Readiness signal wired to `launching → live` (capability-gated, both agents)

**Files:** Modify `OrchestraService.swift:602` (`handleHook`), `+Report.swift:52-53`, `CodexAdapter.swift` tail path (`sessionId(fromRollout:):296`, parse `:94-95`); Test `Tests/IntegrationTests/` (both agents)

- [ ] **Step 1 — Failing test (both agents).** `test_launchingToLive_onReady[claude]`: a Claude `SessionStart(source:.startup)` hook drives `launching → live`. `test_launchingToLive_onReady[codex]`: a Codex rollout `session_meta` line drives `launching → live`. `test_launchingToLive_fallback`: with no readiness capability, N liveness ticks drive it. `test_codexRolloutBindingIsTimeScoped`: a Codex card in `launching` beside a live sibling in the same repo does **not** adopt the sibling's rollout, and after a simulated mass reboot a relaunching card does **not** adopt its own *stale pre-reboot* rollout — `discover(cwd:)` binds only rollouts whose mtime postdates the card's `phaseChangedAt` (newest-after-launch; on ambiguity bind nothing — the N-liveness fallback carries readiness).
- [ ] **Step 2 — Run red** → FAIL (startup hook currently dropped at `+Report.swift:52-53`).
- [ ] **Step 3 — Implement.** Consume `SessionStart(source:.startup)` as the Claude readiness trigger → `transition(.live(...))` (`.running` if the card has a prompt in flight, else `.waiting(.humanTurn)` — Task 2.5's landing rule). Wire Codex `session_meta` as the Codex trigger, with the mtime-after-`phaseChangedAt` binding gate. Add the N-liveness-tick fallback for `.relaunchLiveness`/no-capability agents. Gate strictly on `adapter.capabilities.resumeConfirmation` — no `if agentId ==`.
- [ ] **Step 4 — Run green** → PASS for both agents.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): capability-gated Ready signal drives launching->live (claude+codex)"`

### Task 2.7: Docs

- [ ] Update `docs/03-data-model.md` (phase/epoch fields; `status`/`waitReason` removed; on-disk migration) + `docs/04-cards-worktrees-sessions.md#recovery-resume-and-restart` (the funnel) + `docs/09-design-decisions.md` (new phase/epoch decision; wire-break decision). Commit `docs(lifecycle): document phase funnel + epochs`.

---

## Stage 3 — WorktreeRegistry + timeout knobs

**Deliverable:** A single actor owning worktree lifecycle (incl. borrows) with on-demand sibling counts, the materialized marker + fail-safe arms, and one removal policy; race-free ensure; every git invocation bounded by the new Config knobs.

### Task 3.1: The timeout Config knobs

**Files:** Modify `Sources/OrchestraCore/Config.swift`; Test `Tests/OrchestraCoreTests/ProcTimeoutTests.swift`

**Interfaces produced:** `Config` gains **new** wall-clock knobs (main has none — the named timeouts in older drafts were branch-only, and the earlier idle-reset/`--progress` design was cut at finalization as machinery a single-user tool doesn't need): `worktreeAddTimeout` (default **600s** — generous beats activity-aware; worst known checkout ≈9s), `sessionLaunchTimeout` (default 30s), `controlTimeout` (default 15s — tmux control verbs + fast git queries). All **additive-optional** so an old `config.json` still decodes. `Proc.run`'s existing wall-clock `timeout` is the enforcement primitive — no `Proc` changes needed.

- [ ] **Step 1 — Failing test.** `test_configTimeoutDefaults`: the knobs default as above and are overridable. `test_configForwardCompat`: a `config.json` without the new keys decodes, keeping defaults.
- [ ] **Step 2 — Run red** → FAIL (no knobs).
- [ ] **Step 3 — Implement.** Add the Config knobs.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(config): launch/checkout/control timeout knobs (additive-optional)"`

### Task 3.2: Bound every `WorktreeManager` git invocation

**Files:** Modify `Sources/OrchestraCore/WorktreeManager.swift:39,:41,:146`; Test `Tests/OrchestraCoreTests/WorktreeTests.swift`

- [ ] **Step 1 — Failing test.** `test_worktreeAddIsBounded` + `test_pruneIsBounded`: the add invocations (`:39`, `:41`) and the fallback prune (`:146`) are invoked with a timeout (no unbounded `Proc.run` remains in the file). `test_worktreeAddTimesOut`: an absurdly short timeout makes `ensure` throw rather than hang.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Pass `config.worktreeAddTimeout` to the adds, `config.controlTimeout` to the prune, `remove`, and the borrow ops.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): bound all git invocations with the Config knobs"`

### Task 3.3: `WorktreeRegistry` actor — ensure + materialized marker + persisted borrows

**Files:** Create `Sources/OrchestraCore/WorktreeRegistry.swift`; Test `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift`

**Interfaces produced:**
```
actor WorktreeRegistry {
  func ensure(repo: String, branch: String, cardId: UUID, base: String? = nil) async throws -> Worktree
                              // joins an existing tree for the same branch; marker arms below; validates path
  func release(cardId: UUID, cards: [Task], force: Bool) async throws
                              // one removal policy; sibling count COMPUTED from `cards` at decision time; idempotent to missing tree
  // borrow lifecycle (the branch-tree bare-parent borrow; delegates git to WorktreeManager.borrow)
  func ensureBorrow(repo: String, parentBranch: String, borrowerCardId: UUID) async throws -> Worktree // exactly-one-borrower
  func releaseBorrow(borrowerCardId: UUID) async throws   // removes only the borrower's registration
  func sweepOrphanBorrows(cards: [Task]) async            // liveness-guarded; runs AFTER phase reconciliation (Task 4.4 boot order)
  func stampMarkers(forMigratedPaths: [String]) async     // one-time: pre-upgrade trees are marker-less (review C1)
}
```
No stored refcount map and no `rebuildRefcounts` — sibling counts are **computed on demand** from the persisted cards at each release decision (a `dead` card holds its reference — its tree must survive for `restart`; only `archived` releases). **Borrow registrations are persisted** (`[borrowerCardId: path]`, atomic JSON beside the inbox) — in-memory registration is what lets today's boot sweep destroy a live borrower's tree after a daemon-only crash.

- [ ] **Step 1 — Failing test.** `test_concurrentSameBranchEnsureJoins`: two concurrent `ensure(sameBranch)` calls yield the same worktree and `git worktree add` runs **once** (no `branchInUse` error). `test_markerlessCleanDirRecreated`: a *clean* marker-less dir at the path is pruned + re-created. `test_markerlessDirtyDirNeverRemoved`: a **dirty** marker-less dir is left byte-intact and `ensure` throws a classified error (call site → `dead(.spawnFailed)` + "manual cleanup needed" activity) — never rm'd. `test_ensureReMaterializesMissingTree`: an `ensure` for a card whose marked tree was deleted re-creates it from the branch. `test_migrationStampsMarkers`: `stampMarkers` makes every pre-upgrade tree adoptable (pairs with Task 2.2's fixture — the upgrade must not eat Allen's board; extend that fixture to assert a **dirty pre-upgrade tree survives byte-intact**). `test_ensureRejectsPathEscape`: a branch name with `..` components (or one whose computed path escapes the worktrees root, component-wise) throws — no card can be born with an out-of-root `cwd`. `test_exactlyOneBorrower`: a second `ensureBorrow` on the same parent throws with the existing borrower named. `test_borrowRegistrationSurvivesRestart`: a fresh registry instance reading the persisted registrations still knows the borrower.
- [ ] **Step 2 — Run red** → FAIL (WorktreeManager races; adopts via bare `fileExists`; borrows in-memory).
- [ ] **Step 3 — Implement.** Actor serializes ensure per branch; writes a **materialized marker** (a sentinel file) only after a *complete* checkout; adopts only when the marker is present (replaces the bare `fileExists` at `WorktreeManager.swift:29`), else the marker arms above. The borrow registry absorbs `borrowedWorktrees` (`OrchestraService.swift:60` / `+Borrow.swift:43-52`) and persists. Delegates the actual git to `WorktreeManager` (whose `Proc.run` now executes on this actor — off the service actor by construction).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): WorktreeRegistry — marker arms, on-demand siblings, persisted borrows"`

### Task 3.4: One removal policy via `release()`

**Files:** Modify `WorktreeRegistry.swift`; Test `WorktreeRegistryTests.swift`

- [ ] **Step 1 — Failing test.** `test_releaseNeverRemovesWhileReferenced` (another non-archived card — incl. a `dead` one — references the path → dir kept); `test_releaseNeverRemovesDirtyWithoutForce` (dirty + `force:false` → kept, no throw-escalation to data loss); `test_releaseHonorsCreatedFlag` (a not-created/adopted tree is not deleted); `test_releaseIdempotentToMissingTree` (releasing an already-deleted tree is a no-op success, never throws); `test_releaseNeverRemovesOutsideOwnedRoots` (a card whose `cwd` points outside the worktrees root / `orch-borrow-*` roots — e.g. a borrowed dir — is **never** rm'd by any release path, force or not).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** `release` computes the sibling count from the passed persisted cards at decision time; removes only when `siblings==0 && (!dirty || force) && created && pathUnderOwnedRoots`; a missing tree short-circuits to success. This is the single policy — today's ad-hoc sibling scan becomes the registry's one computed check. In **conservative mode** (post-corrupt-recovery, Task 4.4) `release` performs no removals at all.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): single removal policy in release()"`

### Task 3.5: Route all teardown through `release()`

**Files:** Modify `OrchestraService.swift` (archive `:660-702`, spawn orphan-rollback `:345-351`, borrow sweep `:665-668`), `+Recovery.swift` (reopen `:211`), `+Borrow.swift` (`:43-77`); Test `DaemonLifecycleTests.swift`

- [ ] **Step 1 — Failing test.** `test_archiveWithSiblingKeepsTree` (via the computed sibling check) + `test_spawnRollbackNeverForceRemovesSharedTree`: the orphan-rollback path (a lineage-record failure after the tree was cut, `:345-351`) routes through `release(force:false)` — it can no longer destroy a tree another card references; **Compile-time guarantee (not a test):** `WorktreeManager` becomes an implementation detail of the registry (fileprivate/private to its file, or nested) so no code path outside the registry *can* call it.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Replace every direct `worktrees.ensure`/`.remove`/`.borrow`/`.pruneOrphanBorrows` with the registry equivalents. Delete the ad-hoc sibling scan (now the registry's computed check). Archive's open-borrow sweep and startup `sweepOrphanBorrows` route through the registry.
- [ ] **Step 4 — Run green.** Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "refactor(worktree): route all teardown through WorktreeRegistry.release"`

### Task 3.6: Docs

- [ ] Update `docs/04-cards-worktrees-sessions.md#worktrees` + `docs/09-design-decisions.md` (registry, marker arms, on-demand sibling counts, persisted borrows). Commit.

---

## Stage 4 — Reconciler + phase-keyed steppers + verb contract

**Deliverable:** phase-keyed steppers (Materialize/Launch/Relaunch/Teardown) driven by the reconciler's per-tick discipline; **non-blocking spawn** (delivered here, once, together with its phaseGate); startup reconciliation with epoch-identity adoption; persisted watch registry; corrupt-`tasks.json` recovery + conservative mode; the typed verb contract + matrix tests.

### Task 4.1: `PhaseStepper` protocol + `ConvergeContext`

**Files:** Create `Sources/OrchestraCore/PhaseStepper.swift`; Test `Tests/OrchestraCoreTests/StepperTests.swift`

**Interfaces produced:**
```
protocol PhaseStepper {
  static var drives: Phase.Kind { get }   // creatingWorktree | launching | relaunching | archivedPending
  func step(_ card: Task, _ ctx: ConvergeContext) async throws   // idempotent: advance one edge
  func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool
}
struct ConvergeContext { /* store, registry, sessions, adapters, transition — a plain deps bundle for stub-testing */ }
```
Steppers are **stateless** — the card arrives as an argument; there are no per-card instances (crash recovery's premise is that phase + persisted fields re-derive everything). The reconciler owns the `Phase.Kind → PhaseStepper` map; verbs never reference steppers.

- [ ] **Step 1 — Failing test.** `test_stepperStepIsIdempotent`: calling `step` twice from the same phase yields the same result as once (no double side effect).
- [ ] **Step 2 — Run red** → FAIL (no type).
- [ ] **Step 3 — Implement.** Define the protocol + context + the phase→stepper map skeleton.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): stateless PhaseStepper protocol + context"`

### Task 4.2: Materialize + Launch steppers — non-blocking spawn + the test migration

**Files:** `PhaseStepper.swift`; modify `OrchestraService.swift` spawn (`:245-451`); `Stubs.swift`; ~30 existing test files; `Tests/IntegrationTests/E2EBinaryTests.swift`; Test `StepperTests.swift`

- [ ] **Step 1 — Failing test.** `test_spawnReturnsBeforeProvisioned`: with a blocked worktree-`ensure` stub, the spawn RPC returns a card in `creatingWorktree` (cwd set) while `ensure` is still blocked; a concurrent `list()` answers promptly. `test_spawnStepperCrashRestart`: kill the daemon between `creatingWorktree`→`launching` and `launching`→`live`; on reconciler re-run, `verify` becomes true (tree materialized, session up, no duplicates). **Both agents.** `test_spawnFailureClassified`: a checkout failure lands `dead(.spawnFailed)` with the git stderr in `deadDetail`; a timeout lands an explicit "timed out after Ns" note (no generic passthrough). `test_launchFlavorDerivedFromState`: a `launching` card with `agentSessionId` + a transcript on disk relaunches via **resume** (a crashed reopen must never re-drive as a blank spawn); `initialPrompt` is submitted only if the card has never been prompted.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Spawn's sync part shrinks to: persist the card + `transition(.creatingWorktree)` + return `(card, rev)` (this supersedes Task 2.5's inline walk — the interim `launching`-session-vanished liveness rule is replaced by the stepper-owned `phaseChangedAt` timeout). **MaterializeStepper:** `registry.ensure` (marker arms) → `transition(.launching)`; failure → `dead(.spawnFailed)` classified + `release(force:false)`. **LaunchStepper:** `finishLaunch` off-actor with `ORCH_EPOCH=<sessionEpoch>` in the env (Task 2.4); the **launch-flavor rule** (sid+transcript → resume, else blank; `pendingSeed` consumed and cleared on readiness-at-current-epoch); readiness (Task 2.6) drives `→ live`. `verify` = cwd materialized + session alive at current epoch + agent-up.
- [ ] **Step 4 — Test migration (the branch proved this is required).** Add a `spawnAndAwaitLive` helper (poll the store until `phase == .live`, ~3s cap) and migrate every test that spawns-then-asserts on post-launch state (~30 files on the branch; same set here — RecoveryTests, ReopenTests, WakeMergeWatchTests, OrchestraServiceTests, …). The CLI E2E smoke test polls `sessions <id> --json` until the `:agent` window exists (~15s cap) before driving `exec`. Extend `Stubs.swift` with the blockable/recording seams (test-doctrine constraint).
- [ ] **Step 5 — Run green.** Full `swift test` → green.
- [ ] **Step 6 — Commit.** `git commit -m "feat(converge): Materialize+Launch steppers; non-blocking spawn"`

### Task 4.3: Relaunch + Teardown steppers (resume/restart/handoff/archive/reopen)

**Files:** `PhaseStepper.swift`; modify `OrchestraService.swift` (`archive:660`), `+Recovery.swift` (`reopen:204`, `resume:55`, `restart:146`), `Inbox.swift` (dedup key); Test `StepperTests.swift`

- [ ] **Step 1 — Failing test.** `test_reopenCrashRestart`: reopen enqueues intent + returns; a crash mid-checkout re-drives to `live` **as a resume** (transcript preserved — the launch-flavor rule); the actor is never blocked during the checkout. **Degraded:** `test_relaunchReMaterializesMissingWorktree` (delete the tree under a `relaunching` card → stepper `ensure`s it back + emits a "re-materialized" activity → `live`); `test_relaunchBranchGoneFailsSafe` (branch also gone → `dead(.resumeFailed)`, conclusion fires). **Supersede races (mined from the discarded branch):** `test_archiveDuringMidCheckout` (from `ebcd88e`); `test_archiveDuringLaunching` (post-worktree, pre-session); `test_archiveRacesLaunch_reclaimsSession` (archive lands in the post-session-create window → the **orphan-session sweep** kills the session within a tick; the funnel rejects the late `→ live` — from `28cedb5`) — **each run for worktree, scratch, AND borrowed spawns**. **Teardown durability:** `test_teardownFullDutyList`: archive runs, in order — **kill session (today `OrchestraService.swift:689` — one line past the old duty list's cited range; do not lose it)** → release borrow → `release()` tree → cancel treeStat/child-fanout debounces + remote watch + re-nudge timer → nudge live children **with an inbox dedup key** `(childId, "parent-archived:<branch>")` — then flips `archived(pending) → archived(complete)`. `test_teardownRedriveNoDuplicateNudges`: crash after the child nudges but before the flip → boot re-drives the duty list; children get **no second nudge** (dedup key) and no spurious wake. `test_handoffSeedSurvivesCrash`: handoff persists `pendingSeed` (incl. folded drained-inbox content) in the same patch as `transition(.relaunching)`; crash before launch → the re-driven relaunch delivers the seed; a `resumeFailed` keeps it for the next attempt.
- [ ] **Step 2 — Run red** → FAIL (reopen synchronous on-actor `:211`; archive one-shot; seed in-memory).
- [ ] **Step 3 — Implement.** Each verb's sync part: `transition` to the intent phase + return `(card, rev)` — archive → `archived(pending)`; reopen → `creatingWorktree` (its epoch++ closes the ghost-SessionEnd window during re-checkout); resume/restart/handoff → `relaunching` (restart clears `agentSessionId`, handoff/seeded-wake persist `pendingSeed`, both in the same patch). **RelaunchStepper:** kill-then-`ensure` (require `created == true` from the session layer — never adopt a dying predecessor; identity via the epoch readback), same timeout knobs as spawn. **TeardownStepper:** the ordered duty list above, each duty idempotent; `Inbox.enqueue` gains an optional `dedupKey` (skip if an undelivered message with the same key exists).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): Relaunch+Teardown steppers; durable teardown + pendingSeed"`

### Task 4.4: Reconciler driving discipline + startup reconciliation + durable registries

**Files:** Modify `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`reconcileLiveness:236`, `recoverSessions:14`), `orchestrad/main.swift:47-53` (boot order), `TaskStore.swift` (corrupt recovery), new `WatchRegistryStore.swift`; Test `RecoveryTests.swift`

- [ ] **Step 1 — Failing test.** `test_startupReconcilesInFlightPhases`: a persisted `creatingWorktree`/`launching` card in a fresh process is re-driven to `live` or, if unrecoverable, `dead(spawnFailed)` — no stuck-Creating (fixes #5). `test_preKillProbeIsFresh` (fixes #7) + `test_preKillProbeOffActor`. `test_orphanSessionSwept`: an `orchestra-<uuid>` session whose card is **archived or nonexistent** is killed within a tick (after a fresh epoch-stamped probe); a `dead(.completed)` card's surviving session is **not** killed (revival stays possible). `test_adoptionChecksEpochIdentity`: a `relaunching` card with a surviving **old-epoch** session → boot **completes the relaunch** (kill + launch — the persisted intent), never adopts; a matching-epoch session → adopt to `live`; the N-tick fallback never promotes an old-epoch session. `test_strandedTransitionalCardRedriven`: a transitional-phase card whose in-flight step "died" (no crash — simulated task death) is stepped again on the next tick. `test_launchTimeoutSurvivesCrash`: a card `launching` since before a restart is classified from its persisted `phaseChangedAt`. `test_stepFailureBacksOff`: a persistently-failing step emits an activity and degrades to capped-backoff retries — never a hot loop. `test_corruptTasksJsonRecovers`: an unparseable `tasks.json` is renamed `tasks.json.corrupt-<ISO8601>` (timestamped — a second corruption must not clobber the first backup), logged; the daemon boots empty in **conservative mode** — `release()` performs **no removals** until ownership is positively re-established. `test_mcpWatchSurvivesRestart`: an MCP `wait` watcher survives a daemon restart (registry persisted + reloaded); a watched child already terminal at reload delivers its conclusion immediately.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** **Boot order** (`main.swift:47-53` becomes): `sweepOrphanScratch → phase reconciliation → registry.sweepOrphanBorrows(cards) → watch-registry reload → rebuildRemoteWatches → rebuildMergeRequestNudges → one-shot treeStat recompute for non-terminal cards`. Phase reconciliation: adopt sessions **only on epoch-identity match** (`sessions.stampedEpoch(name:)`, Task 2.4); re-drive transitional phases via the steppers; terminal cards need nothing (conclusion derived; a re-issued `wait` short-circuits) except `archived(pending)` → Teardown re-drive. **Per tick:** batched `sessions.list()` snapshot (off-actor after 5.1); liveness only for `live` cards; **transitional cards with no in-flight step get stepped** (at most one in-flight step per card; a step re-checks phase after any resource-acquiring await — the resource epilogue); orphan-session sweep; pre-kill fresh probe; `phaseChangedAt` timeouts; per-card attempt counter + capped backoff; debounced so a many-card startup doesn't thrash. **Persist the watch registry** (`[UUID: Set<UUID>]`, atomic JSON beside the inbox — today it is in-memory at `OrchestraService.swift:63` and an earlier spec draft wrongly called it durable). **Corrupt recovery + conservative mode** in `TaskStore.load` + a flag `release()` consults.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): reconciler driving discipline; epoch-identity adoption; durable watch registry; conservative recovery"`

### Task 4.5: Typed `VerbSpec` + the gate-enforcement chokepoint

**Files:** Modify `Sources/OrchestraKit/CommandCatalog.swift` (`CommandSchema`), `Sources/OrchestraCore/CommandRegistry.swift` (dispatch); Test `Tests/OrchestraCoreTests/VerbContractTests.swift`

**Interfaces produced:** `CommandSchema` gains `kind: VerbKind` + `phaseGate: Set<Phase>` (the allow-set; deny-by-default — fail-safe for future phases). **No** `capability`/`idempotency`/`converger` fields (cut at finalization — nothing reads them; idempotency stories are doc comments). **Enforcement:** one chokepoint in the registry dispatch — verbs declare which param names their target card; the dispatcher resolves the card, checks `phaseGate`, and returns a typed error naming the phase before the handler ever runs.

- [ ] **Step 1 — Failing test.** `test_everyVerbDeclaresKind`: every registry entry has a `kind`; every Mutation/Convergence verb has a **non-empty** `phaseGate` matching the spec §6 default gate policy. `test_gateEnforcedAtDispatch`: a gated-out call never reaches its handler and returns the typed error. `test_openShellDeniedWhileLaunching`: the gate denies `shell`/`inspect` on a `creatingWorktree`/`launching`/`relaunching` card with a clear error, and the agent session name is never claimed by `/bin/sh` (bug #3 — this ships in the same stage as non-blocking spawn, so the window and its gate land together).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Extend the schema; classify **all 32 registered verbs** per the finalized spec §6 table (Query = `list/status/sessions/capture/tree/trustState/inbox`; Mutation = `move/send/trust/wait/inbox-edit/inbox-remove/inbox-reorder/set-parent/synced/shipped/merge-request/borrow/release/shell/inspect/closeShell/exec/send-keys`; Convergence = `spawn/batch-spawn/archive/reopen/resume/restart/handoff`); wire the dispatch chokepoint. `batch-spawn` = N independent spawn intents (per-item client ids land in Task 6.1).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(verbs): VerbSpec kind+phaseGate with one dispatch-time enforcement chokepoint"`

### Task 4.6: The matrix + crash-recovery test battery

**Files:** `Tests/OrchestraCoreTests/VerbContractTests.swift`, `StepperTests.swift`

- [ ] **Step 1 — Test A (gate soundness).** `test_gatePolicyConformance`: every Mutation/Convergence verb's declared allow-set matches the spec §6 default policy (+ documented exceptions); probe one denied phase per verb through the real dispatcher. (Set semantics = deny-by-default for any future phase — no "explicit declaration" ceremony; an earlier draft demanded one, which a `Set` cannot represent.)
- [ ] **Step 2 — Test B (stepper crash-convergence).** `test_everyStepperConvergesFromAnyBoundary`: for each `PhaseStepper`, drive its phase, kill at each `step` boundary, re-run the reconciler, assert `verify` becomes true — the full per-phase matrix: `creatingWorktree`, `launching`, `live`, `relaunching`, `dead`, `archived(pending)`, `archived(complete)`.
- [ ] **Step 3 — Test C (adopt-don't-relaunch).** `test_daemonCrashAdoptsLiveSession` (epoch-identity match required), `test_launchingAdoptsSurvivingSession` (no duplicate session/card), `test_machineRebootPath` (tmux gone: resume per capability or `dead(.rebootUnrevived)`).
- [ ] **Step 4 — Test D (missed readiness).** `test_launchingMissedHookConvergesViaLiveness`: a SessionStart hook that fired into the dead daemon is lost; the **N=3** liveness fallback still drives `launching → live` — and the test asserts `N × tickInterval < sessionLaunchTimeout` (the inequality the fallback depends on).
- [ ] **Step 5 — Test E (conclusion + idempotency).** `test_waitShortCircuitsOnPersistedTerminalPhase` (inline conclusion, **and** the watch entry is unregistered — a later archive of the same child produces no duplicate); `test_batchSpawnRetryIsIdempotent` (per-item ids; partially-acked batch retried → no duplicate cards; full wiring in 6.1, the schema lands here).
- [ ] **Step 6 — Run.** All green (they exercise Stages 2-4). Fix any gaps they expose.
- [ ] **Step 7 — Commit.** `git commit -m "test(converge): gate-soundness + stepper crash-convergence + adopt/reboot/missed-hook/conclude battery"`

### Task 4.7: Docs

- [ ] Update `docs/05-command-reference.md` (verb taxonomy) + `docs/02-architecture.md#request-flow-server-side` (Convergence model). Commit.

---

## Stage 5 — Actor-hygiene sweep + telemetry debounce + snapshot-from-cache

**Deliverable:** no subprocess/file IO on the service actor; telemetry persists debounced (the archived-file split was cut at finalization — the debounce alone bounds bug #13); snapshot served from cache.

### Task 5.1: Move blocking calls off-actor

**Files:** Modify `OrchestraService.swift` (exec `:795`, sweepOrphanScratch `:467/:482`, status `:641`), `+Diff.swift:18,:42`, `+Notes.swift:16`, pollTelemetry (`OrchestraService.swift:224`), `ClaudeCodeAdapter.swift:127` (prepareToLaunch → `ClaudeTrust.apply:305`/`grant:314`), `+Recovery.swift:239` (reconcileLiveness list), **branch-tree sites:** `+ParentRef.swift:13-17` (`gitRemotes`), `+Tree.swift:501-541` (local tree probes), `+Remote.swift:223-237` (redirect probes); Test `Tests/IntegrationTests/ActorHygieneTests.swift`

- [ ] **Step 1 — Failing test.** `test_actorNotBlockedByExec` / `_byDiff` / `_byPollTelemetry` / `_byTreeStatRecompute` / `_byLivenessList`: while a slow subprocess runs, a concurrent fast RPC (e.g. `list`) returns within a tight bound (actor not frozen).
- [ ] **Step 2 — Run red** → FAIL (on-actor blocking).
- [ ] **Step 3 — Implement.** Wrap each site in `offActor { ... }` (the existing hop, `+Recovery.swift:351`). Move `pollTelemetry`'s rollout enumeration (`CodexAdapter.rolloutFiles:282-284`) off-actor; move `prepareToLaunch`'s `~/.claude.json` read-merge-rewrite off-actor; move the every-2s `reconcileLiveness` `sessions.list()` (`+Recovery.swift:239`) off-actor; move `gitRemotes` + the `+Tree`/`+Remote` local git probes off-actor (cache `gitRemotes` per repo — it's on spawn's hot path *and* the report→treeStat funnel). `WorktreeManager` calls are already off the service actor via the `WorktreeRegistry` actor (Stage 3). Bound every moved call with the Task 3.1 knobs (`controlVerbTimeout`/`fastGitTimeout`).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "perf(actor): move exec/diff/notes/telemetry/prepareToLaunch off-actor"`

### Task 5.2: `boardSnapshot` from the reconciler's observed cache

**Files:** Modify `OrchestraService.swift:805-820` (`boardSnapshot`), `+Recovery.swift` (populate an observed-session cache); Test `Tests/OrchestraCoreTests/BoardSnapshotTests.swift`

- [ ] **Step 1 — Failing test.** `test_boardSnapshotDoesNotShell`: building a snapshot performs **zero** tmux subprocess calls (session state comes from the cache the reconciler already maintains).
- [ ] **Step 2 — Run red** → FAIL (serial 2×N tmux verbs `:805-820`).
- [ ] **Step 3 — Implement.** The reconciler writes each card's observed session state into an in-memory cache each tick; `boardSnapshot` reads the cache instead of shelling per card.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "perf(actor): serve boardSnapshot session state from the observed cache"`

### Task 5.3: Telemetry-persist debounce

**Files:** Modify `Sources/OrchestraCore/TaskStore.swift`; Test `TaskStoreTests.swift`

- [ ] **Step 1 — Failing test.** `test_telemetryPersistDebounced`: N rapid telemetry deltas within the debounce window cause ≤1 disk write.
- [ ] **Step 2 — Run red** → FAIL (every delta rewrites `tasks.json`, `:55-67`).
- [ ] **Step 3 — Implement.** Add a persist debounce for telemetry-origin mutations (reuse the `diffStatDebounce` pattern, `OrchestraService.swift:99`). Whole-file atomic rewrite stays — at tens-to-hundreds of KB, debounced, it is fine indefinitely (the archived-file split was cut at finalization: a second file, lazy loading, and cross-file `rev` monotonicity bought nothing the debounce doesn't). Corrupt-recovery landed in Task 4.4.
- [ ] **Step 4 — Run green.** Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "perf(store): debounce telemetry persists"`

### Task 5.4: Docs

- [ ] Update `docs/02-architecture.md#the-daemon-orchestrad` (actor hygiene + snapshot cache). Commit.

---

## Stage 6 — Idempotency + client deadlines + UI gating

**Deliverable:** idempotent spawn/batch-spawn over dropped connections; per-RPC deadlines + keepalive; one `displayState` UI contract (validActions derived from the verb phaseGates) with honest failures and terminal retry.

### Task 6.1: Client-minted ids (spawn + send)

**Files:** Modify `Sources/OrchestraKit/Model.swift` (`SpawnInput.id: UUID` — required; struct at `:726-774`), `Sources/OrchestraCore/OrchestraService.swift:254` (spawn mint), `ControlServer.swift` (dedup), `BoardStore.swift:670` (mint id client-side); Test `Tests/IntegrationTests/IdempotencyTests.swift`

- [ ] **Step 1 — Failing test.** `test_spawnWithClientIdIsIdempotent`: two spawns with the same client-minted id create **one** card (the second returns the existing card@rev **as-is, whatever its phase** — even `dead(.spawnFailed)`; honest). `test_batchSpawnRetryIsIdempotent`: a partially-acked `batch-spawn` retried with the same per-item ids creates no duplicates. (**No `send` dedup** — cut at finalization: there is no automatic retrier anywhere in this design, so a re-sent message is user intent; `InboxMessage.id` already exists if that ever changes.)
- [ ] **Step 2 — Run red** → FAIL (server always mints `:254`; retry = duplicate).
- [ ] **Step 3 — Implement.** Make `id` a required field on `SpawnInput` **and per-item on the batch-spawn wire schema**; the clients (`BoardStore.spawn:670`, the CLI, MCP) mint the `UUID`s. Server: if a card with that id exists, return it; else create with that id (delete the server-side `UUID()` mint at `:254`).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): client-minted ids make spawn/batch-spawn idempotent"`

### Task 6.2: Per-RPC deadline + ping keepalive

**Files:** Modify `Sources/OrchestraKit/Control/ControlClient.swift:152-168` (`call`), add a ping timer; Test `Tests/OrchestraCoreTests/ControlClientTests.swift` (there is **no** `Tests/OrchestraKitTests` target — OrchestraCoreTests already depends on OrchestraKit)

- [ ] **Step 1 — Failing test.** `test_callTimesOut`: a `call` against a dead-but-open transport (no EOF, no reply) throws a timeout within the deadline instead of hanging. `test_pingDetectsDeadTunnel`: the keepalive marks the connection degraded when pings stop returning.
- [ ] **Step 2 — Run red** → FAIL (unbounded `withCheckedThrowingContinuation`).
- [ ] **Step 3 — Implement.** Add a per-call deadline (cancels the continuation + fails pending on expiry). Add a periodic `version`/ping (the RPC exists — `probeVersion:117`) that flips a `connectionState` on timeout. Safe now that mutations are idempotent (Task 6.1) + reconcilable.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): per-RPC deadline + ping keepalive"`

### Task 6.3: `rev` gap detection → resync in `BoardStore`

**Files:** Modify `Sources/OrchestraUI/BoardStore.swift:587` (`apply`), `:625-632` (ring); Test `Tests/OrchestraUITests/BoardStoreTests.swift`

- [ ] **Step 1 — Failing test.** `test_staleEventDropped`: an event with `rev ≤ lastSeen` is **not** applied (fixes the last-write-wins clobber). `test_revGapTriggersResync`: a jump in `rev` (missed event) triggers a `boardSnapshot` fetch.
- [ ] **Step 2 — Run red** → FAIL (whole-record overwrite `:588`).
- [ ] **Step 3 — Implement.** Track `lastSeenRev`; apply a `taskUpserted` iff its envelope `rev > lastSeenRev`; on a gap, request a fresh snapshot and adopt its `rev`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): apply-iff-rev + gap resync in BoardStore"`

### Task 6.4: `displayState(phase, connection)` + honest toasts + action gating

**Files:** Create `Sources/OrchestraKit/DisplayState.swift`; modify `Sources/OrchestraUI/BoardStore.swift` (actions), `SpawnSheet.swift:302-321` (in-flight guard), `App/Views/RecoveryView.swift` + `App-iOS/Views/CardDetail/RecoveryView.swift` (spawnFailed copy), `Sources/OrchestraUI/Theme.swift` (phase labels/colors); Test `Tests/OrchestraUITests/DisplayStateTests.swift`

**Interfaces produced:** `func displayState(phase: Phase?, connection: ConnectionState) -> DisplayState` where `DisplayState` declares `{ label, validActions: Set<Verb>, isBusy, staleSince }`.

- [ ] **Step 1 — Failing test.** `test_displayStateActionsByPhase`: each phase declares its valid actions (data, not per-button logic — `creatingWorktree`/`launching` render a "Creating…" pill and disable shell/inspect/restart; `dead(.spawnFailed)` is dead, **never** "Creating…"). `test_archiveFailureToastIsHonest`: a failed archive does **not** toast "Archived". `test_doubleSpawnGuarded`: a second spawn while one is in-flight is a no-op.
- [ ] **Step 2 — Run red** → FAIL (fire-and-forget `_ = try? await`; unconditional toast `BoardStore.swift:704-707`; no `isSpawning` guard).
- [ ] **Step 3 — Implement.** Add `displayState`; **every surface** (mac CardView, iOS BoardCardCell, detail/inspector, `orchestra list`) renders from it — one `displayStatusKey`, no per-surface label logic (the branch shipped a board that said "Creating…" while the detail said "Waiting"). Gate every action on `validActions` + `isBusy`; inspect call results and toast honestly ("resyncing…" on unknown); add an `isSpawning` in-flight guard in `SpawnSheet`. **Both** Recovery panels explain `dead(.spawnFailed)` ("Creating the workspace failed — <deadDetail>") and offer restart (which re-materializes the tree — Task 4.3's degraded path — so the copy is honest).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(ui): displayState contract + honest toasts + in-flight gating"`

### Task 6.5: Mac terminal bounded-backoff retry loop

**Files:** Modify `App/Views/AgentTerminalView.swift:173` (`processTerminated`); Test manual + `App` snapshot (or a unit test of the retry policy extracted to `OrchestraKit`)

- [ ] **Step 1 — Failing test.** Extract the iOS retry policy (`IOSTerminalView.swift:313-348`: bounded exponential `min(8, 1<<(n-1))`, `maxReconnects` budget, dedup) into a shared `TerminalReconnectPolicy` in `OrchestraKit`; `test_reconnectPolicyBackoff` asserts the schedule + budget.
- [ ] **Step 2 — Run red** → FAIL (no shared policy; mac `processTerminated` empty).
- [ ] **Step 3 — Implement.** Add the shared policy; wire the mac `processTerminated` to it so a dead pane re-attaches when the phase is `live` (matches iOS). Only attach when `displayState` says live.
- [ ] **Step 4 — Run green** + manual check on the mac app (isolated instance per the project's UI-verify recipe).
- [ ] **Step 5 — Commit.** `git commit -m "feat(ui): mac terminal reuses the iOS bounded-backoff reconnect policy"`

### Task 6.6: Docs

- [ ] Update `docs/02-architecture.md#the-client-transport-seam-and-reconnect` + `#the-three-clients` (deadlines, keepalive, displayState). Commit.

---

## Cross-cutting: the E2E slow-repo fixture

**Files:** `Tests/IntegrationTests/Fixtures/` + `Tests/IntegrationTests/SlowRepoE2ETests.swift`

- [ ] Build (or script) a ~28k-file repo fixture giving a ~9s checkout window. Add `test_slowRepoSpawn`: exercises race-free `WorktreeRegistry.ensure` under two same-branch spawns (Stage 3), a non-frozen actor during checkout (Stages 4-5), and the `creatingWorktree → launching → live` phase walk (Stage 2). Run for **both** agents. Remember the test doctrine: this E2E is *smoke*, not the regression guard — every race it exercises must also have a deterministic stub test. Commit `test(e2e): slow-repo lifecycle fixture`.

## Self-review checklist (run before handing off each stage)

1. **Spec coverage:** every pillar P1-P6 + the verb contract maps to at least one task above (P1→Stage 2; P2→Stage 4; P3→Stage 3; P4→Stages 1,6; P5→Stage 5; P6→Stage 6; verb contract→Stage 4). ✔
2. **Placeholder scan:** no "TBD"/"handle edge cases" — every step names a concrete test + assertion + mechanism + anchor. ✔
3. **Type consistency:** `Phase`/`RunState`/`TransitionResult`/`transition(_:to:observedEpoch:)`/`PhaseStepper`/`WorktreeRegistry.ensure/release`/`VerbSpec`/`displayState` names are used identically across tasks. ✔
4. **Agent-agnostic:** readiness (2.6), stepper crash tests (4.2-4.3), and the E2E fixture all run claude **and** codex. ✔
5. **Wire break:** `phase` replaces `status`/`waitReason`; required `id`; `Event`/`BoardSnapshot` carry `rev`. The only compat is the one-time on-disk `tasks.json` migration (Task 2.2) — a fixture test asserts every legacy card maps to a correct `phase`. ✔

## Execution handoff

Plan finalized on branch `impl/lifecycle-convergence` (= `main` @ `f1aa568` + these docs). **Execution model (Allen, 2026-07-09):** an **orchestrator card** (Opus 4.8) drives the stages as **child PR cards stacked on this branch** (spawn `--base`, respecting the branch-tree lineage). Each PR card: (1) **first writes its own task-level plan with superpowers:writing-plans**, grounded in the layered-plan documents (`notes/designs/lifecycle-convergence/`) + this plan's stage; (2) implements via **superpowers:subagent-driven-development** (fresh subagent per task, review between tasks); (3) runs **superpowers:requesting-code-review** on its own diff and fixes findings **before** finishing. Each stage is independently reviewable and must leave `swift test` green (both agents where the stage touches agent behavior). After all stages, the orchestrator runs a **final whole-branch review** before handing the branch to Allen.

> **Line-number caveat:** every `file:line` anchor in this plan was re-verified against `main` @ `f1aa568` (2026-07-09). Symbols are stable; if a line drifts during execution, search the symbol.
