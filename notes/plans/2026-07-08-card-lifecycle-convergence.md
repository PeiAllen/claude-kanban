# Card Lifecycle Convergence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Orchestra's 4-variable, edge-triggered card lifecycle with one persisted `phase`, a single transition funnel, per-launch epochs, and an idempotent reconciler — killing 15 confirmed lifecycle bugs.

**Architecture:** State-triggered + convergent. One persisted `Phase` per card written only through a `transition()` funnel that validates edges; a per-launch `sessionEpoch` makes stale signals harmless; slow verbs persist intent that an idempotent reconciler drives to completion; a `WorktreeRegistry` actor is the sole owner of git worktrees; a monotonic board `rev` + client-minted ids + RPC deadlines make sync gap-detectable and retries idempotent.

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
| `Sources/OrchestraKit/Model.swift` | Add `Phase` enum, `RunState` (incl. `waiting(WaitReason)`), extend `DeadReason` with `.completed`/`.spawnFailed`; add `phase`/`sessionEpoch` to `Task`; **remove `status`/`waitReason`**; add `rev` to `Event`/`BoardSnapshot`; required client `id` on `SpawnInput` | 1,2,4,6 |
| `Sources/OrchestraKit/CommandCatalog.swift` | Extend `CommandSchema` with `kind`/`phaseGate`/`idempotency`/`capability` (wire-visible verb metadata) | 4 |
| `Sources/OrchestraCore/OrchestraService.swift` | Host the `transition()` funnel; delete the `recovering` set; off-actor sweep | 2,5 |
| `Sources/OrchestraCore/OrchestraService+Lifecycle.swift` (new) | The `transition()` funnel + `Phase` machine + epoch guard | 2 |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | Reconciler → Convergers; pre-kill fresh probe; startup phase reconciliation | 4 |
| `Sources/OrchestraCore/Converger.swift` (new) | `Converger` protocol + `ConvergeContext`; per-verb Convergers (spawn/archive/reopen/resume/restart/handoff) | 4 |
| `Sources/OrchestraCore/WorktreeRegistry.swift` (new) | Actor: serialized `ensure`/`release`, refcount, materialized marker, one removal policy, borrow-tree lifecycle, path safety | 3 |
| `Sources/OrchestraCore/WorktreeManager.swift` | `--progress`; bounded prune; called only by the registry | 3 |
| `Sources/OrchestraCore/Proc.swift` | Idle-reset (activity-aware) watchdog | 3 |
| `Sources/OrchestraCore/Config.swift` | **New timeout knobs** (`worktreeAddTimeout`/`sessionLaunchTimeout`/`controlVerbTimeout`/`fastGitTimeout`), additive-optional decode | 3 |
| `Sources/OrchestraCore/TaskStore.swift` | Board `rev` stamping; archived split to append-only file; telemetry-persist debounce | 1,5 |
| `Sources/OrchestraCore/OrchestraService+Report.swift` | Field-delta write (kill `$0 = task`); epoch-stamped signals | 1,2 |
| `Sources/OrchestraCore/CommandRegistry.swift` | Extend `Command` with optional `converger`; classify verbs | 4 |
| `Sources/OrchestraCore/Control/ControlServer.swift` | Stamp `rev` on notifications + snapshot; dedup client-minted id; fold non-registry switch into QueryVerbs | 1,4,6 |
| `Sources/OrchestraKit/Control/ControlClient.swift` | Per-RPC deadline; ping keepalive; `rev` gap detection → resync | 6 |
| `Sources/OrchestraUI/BoardStore.swift` | Apply-iff-`rev` merge; `displayState`; honest toasts | 6 |
| `Sources/OrchestraKit/AgentCapabilities.swift` | (read/extend) readiness capability already exists (`resumeConfirmation`) | 2 |
| `App/Views/AgentTerminalView.swift` | Mac terminal bounded-backoff retry loop (copy iOS) | 6 |
| `Tests/OrchestraCoreTests/*`, `Tests/IntegrationTests/*` | Phase-edge, epoch, converger-crash, rev-gap, idempotency, slow-repo, agent-agnostic tests | all |
| `docs/02,03,04,05,09` | SSOT updates | per stage |

---

## Stage 0 — DISSOLVED (base decision, 2026-07-09)

> **The branch is discarded; build fresh on `main`.** The original brief scoped a P0-hotfix card on `fix/spawn-hang-standalone`. Allen's decision (2026-07-09) is to **rebuild the phase model fresh on `main` and discard that branch** — so there is nothing to hotfix. The three P0 concerns are satisfied **by construction** in the fresh build:
>
> | Original P0 hotfix | Satisfied by construction in |
> |---|---|
> | Sibling/dirty guard in provision cleanup (no force-remove of dirty/shared trees) | **Stage 3** — `WorktreeRegistry.release()` is the single removal policy (refcount + dirty guard + idempotent-to-missing) |
> | Conclude on `spawnFailed` so a parent `wait` resolves | **Stage 2** — the funnel concludes on entering *any* terminal phase + `isConcluded ≡ terminal phase` |
> | `openShell`/`inspect` must not claim the agent session while provisioning | **Stage 2/6** — `openShell` is phase-gated (`launching`/`creatingWorktree` deny it via the verb `phaseGate`) |
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

**Deliverable:** One persisted `Phase`, one `transition()` writer with edge validation + epoch guard; `recovering` set and `provisioning` variables deleted; `AgentStatus`/`waitReason` **removed** (folded into `phase`), with a one-time on-disk migration.

### Task 2.1: `Phase`/`RunState` types + extended `DeadReason`

**Files:** Modify `Sources/OrchestraKit/Model.swift`; Test `Tests/OrchestraCoreTests/ModelCodableTests.swift`

**Interfaces produced:**
```
enum RunState: Codable, Equatable { case running; case waiting(WaitReason) }   // WaitReason folded in here
enum Phase: Codable, Equatable {
  case creatingWorktree, launching
  case live(RunState)
  case relaunching
  case dead(DeadReason)
  case archived
}
// DeadReason gains: .completed, .spawnFailed  (keeps agentExited/sessionVanished/rebootUnrevived/resumeFailed)
// Task gains: var phase: Phase ; var sessionEpoch: Int  — and DROPS status + waitReason
```

- [ ] **Step 1 — Failing test.** `test_phaseRoundTrips`: encode/decode every case incl. associated values (`live(.waiting(.permission))`, `dead(.completed)`) via an object `{name, detail?}` encoding.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Add the types; give `Phase`/`RunState` a custom `Codable` encoding as `{name, detail?}`. Add `phase: Phase` + `sessionEpoch: Int` to `Task`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): add Phase/RunState(+WaitReason)/epoch to the model"`

### Task 2.2: Remove `status`/`waitReason`; one-time on-disk migration seeds `phase`

**Files:** Modify `Sources/OrchestraKit/Model.swift` (drop `AgentStatus status` + `waitReason` fields), `Sources/OrchestraCore/TaskStore.swift` (migration read); Test `ModelCodableTests.swift`, `TaskStoreTests.swift`

**Interfaces produced:** `Task.init(migratingFrom legacy: LegacyTask)` — seeds `phase` from a pre-upgrade `{status, waitReason}` record: `running → live(.running)`, `waiting → live(.waiting(reason))`, `done → dead(.completed)`, `dead → dead(.agentExited)`, `archived → archived`.

- [ ] **Step 1 — Failing test.** `test_migratesLegacyTasksJson`: load a pre-upgrade `tasks.json` fixture (cards with `status`/`waitReason`, no `phase`); assert each card gets the correct `phase` per the mapping and no card is dropped. `test_statusFieldRemoved`: the `Task` schema no longer encodes `status`/`waitReason`. `test_migratesUnknownLegacyRecordToSafeTerminal`: a garbage/unknown legacy record maps to `dead(.rebootUnrevived)` — never dropped, never throws.
- [ ] **Step 2 — Run red** → FAIL (fields still present; no migration).
- [ ] **Step 3 — Implement.** Delete `status`/`waitReason` from `Task`. In `TaskStore` load, detect a legacy record (has `status`, lacks `phase`) and run `init(migratingFrom:)` once; subsequent saves write only `phase`. Update all readers of `task.status` to compute from `phase` (or read `phase` directly).
- [ ] **Step 4 — Run green** → PASS. Full `swift test` → green (fix every `task.status` reference).
- [ ] **Step 5 — Commit.** `git commit -m "refactor(lifecycle): remove status/waitReason; migrate on-disk tasks to phase"`

### Task 2.3: The `transition()` funnel + edge validation

**Files:** Create `Sources/OrchestraCore/OrchestraService+Lifecycle.swift`; Test `Tests/OrchestraCoreTests/PhaseTransitionTests.swift`

**Interfaces produced:**
```
extension OrchestraService {
  func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil) async
  static func isLegalEdge(from: Phase, to: Phase) -> Bool   // pure, testable
}
```

- [ ] **Step 1 — Failing test (property).** `test_illegalEdgesRejected`: for the full phase set, assert `isLegalEdge` returns true exactly for the edges in spec §P1's state machine and false for all others (e.g. `dead(x) → live(y)` is false; `dead(x) → relaunching` is true).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement `isLegalEdge`.** Encode the machine from spec §P1 as a pure function (a `Set<Edge>` lookup).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Failing test (funnel).** `test_transitionRejectsIllegalEdge`: attempting `dead → live` via `transition` leaves the phase unchanged and logs; a legal edge applies and persists.
- [ ] **Step 6 — Implement `transition`.** The **only** writer of `phase`: validate via `isLegalEdge`; drop+log illegal; on entering `launching`/`relaunching` increment `sessionEpoch` (**strictly before** any launch work begins); on entering any terminal phase (`dead`/`archived`) call `concludeCard` (`+Wake.swift:61`) to notify live waiters — the wire `Conclusion` carries the `DeadReason` so watchers distinguish completed/failed; on entering `live` run `wakeIfPending` (a message sent while the card was being born is delivered here — the single structural release point); persist via `store.update` (patching `phase`/`sessionEpoch` only); emit `.taskUpserted`. **Also redefine `isConcluded` (`+Wake.swift:136-140`) as `phase ∈ {dead(*), archived}`** — every terminal counts, so `wait` no longer hangs on `spawnFailed`/`sessionVanished` (the durable bug-#2 fix; a re-issued `wait` after a crash short-circuits on the persisted terminal phase — no stored ack bit). Add `test_sendDuringLaunchingDeliveredOnLive`: `send` to a `launching` card → inbox holds it; transition to `live` → wake fires.
- [ ] **Step 7 — Run green** → PASS.
- [ ] **Step 8 — Commit.** `git commit -m "feat(lifecycle): single transition() funnel with edge validation"`

### Task 2.4: Epoch guard for stale signals

**Files:** Modify `OrchestraService+Lifecycle.swift`, `+Report.swift` (SessionEnd path), `+Recovery.swift` (liveness); Test `PhaseTransitionTests.swift`

- [ ] **Step 1 — Failing test.** `test_staleSessionEndIgnored`: card at `sessionEpoch=2`; deliver a `SessionEnd`/liveness signal stamped `observedEpoch=1`; assert `transition` is a no-op (card not killed). Then a signal with `observedEpoch=2` does apply.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** In `transition`, when `observedEpoch != nil && observedEpoch != current sessionEpoch`, drop the signal. **How signals learn their epoch:** (a) the launch env stamps `ORCH_EPOCH=<sessionEpoch>` into the tmux session (in `SessionManager.ensure`'s env plumbing — agent-agnostic, both adapters inherit it); the hook payload echoes it back and `handleHook` passes it as `observedEpoch`; (b) the liveness reconciler stamps each card's `sessionEpoch` into its observed-session snapshot at capture time and passes that as `observedEpoch` when it later acts on the snapshot. Thread through the `SessionEnd`/liveness call sites (`+Report.swift:24-31`, `+Recovery.swift:236-243`).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): epoch guard makes stale liveness signals harmless"`

### Task 2.5: Delete `recovering`; route spawn/resume/restart through the funnel; non-blocking spawn

**Files:** Modify `OrchestraService.swift` (delete `recovering` at `:96`; spawn `:245-451`), `+Recovery.swift` (resume `:55`, restart `:146`, reconcile gate `:241`); Test `DaemonLifecycleTests.swift`, `RecoveryTests.swift`, new `SpawnPhaseTests.swift`

> Note: the `provisioning` flag/dict exist **only on the discarded branch** — on main there is nothing to delete but `recovering`. This task also **delivers non-blocking spawn** (the branch's headline feature, rebuilt on phases).

- [ ] **Step 1 — Failing test.** `test_spawnDrivesPhases`: a `.worktree` spawn moves `creatingWorktree → launching → live`; a scratch/borrowed spawn starts at `launching`. `test_spawnReturnsBeforeProvisioned`: with a blocked worktree `ensure` stub, the spawn RPC returns a card in `creatingWorktree` (cwd already set) while `ensure` is still blocked; a concurrent `list()` answers promptly. `test_livenessSkipsNonLivePhases`: a session-less card in `creatingWorktree`/`launching`/`relaunching` is **not** killed by `reconcileLiveness` (liveness is phase-gated to `live`). `test_promptedSpawnLandsRunning` / `test_provisionalSpawnLandsWaiting`: readiness lands a prompted card at `live(.running)` and a no-prompt card at `live(.waiting(.humanTurn))`.
- [ ] **Step 2 — Run red** → FAIL / won't compile against old symbols.
- [ ] **Step 3 — Implement.** Replace every `recovering.insert/remove` with `transition(...)` calls; delete the set and `scheduleRecoveringRelease`/`releaseRecovering`. Spawn: persist the card at `transition(.creatingWorktree)` (worktree) or `.launching` (scratch/borrowed) and **return immediately**; the checkout + launch continue off-actor (Stage 4 formalizes this as the SpawnConverger — here a detached task is acceptable scaffolding); worktree ready → `.launching`; readiness → `.live`. Resume/restart: `→ .relaunching → .live`; **restart additionally clears `agentSessionId` in the same store patch as its transition** (so a crash mid-relaunch recovers the user's chosen flavor: sid present → resume, absent → blank launch). Liveness (`+Recovery.swift:241`): replace the `recovering` gate with the phase gate (`guard task.phase.isLive`).
- [ ] **Step 4 — Test migration (the branch proved this is required).** Add a `spawnAndAwaitLive` helper (poll the store until `phase == .live`, ~3s cap) and migrate every existing test that spawns-then-asserts on post-launch state (~30 files did this on the branch; same set here — RecoveryTests, ReopenTests, WakeMergeWatchTests, OrchestraServiceTests, …). The CLI E2E smoke test polls `sessions <id> --json` until the `:agent` window exists (~15s cap) before driving `exec`. Extend `Stubs.swift` with the blockable/recording seams (test-doctrine constraint above).
- [ ] **Step 5 — Run green.** `swift test` full suite → green (update expectations to phases).
- [ ] **Step 6 — Commit.** `git commit -m "refactor(lifecycle): delete recovering set; non-blocking spawn drives phases via funnel"`

### Task 2.6: Readiness signal wired to `launching → live` (capability-gated, both agents)

**Files:** Modify `OrchestraService.swift:602` (`handleHook`), `+Report.swift:52-53`, `CodexAdapter.swift` tail path (`sessionId(fromRollout:):296`, parse `:94-95`); Test `Tests/IntegrationTests/` (both agents)

- [ ] **Step 1 — Failing test (both agents).** `test_launchingToLive_onReady[claude]`: a Claude `SessionStart(source:.startup)` hook drives `launching → live`. `test_launchingToLive_onReady[codex]`: a Codex rollout `session_meta` line drives `launching → live`. `test_launchingToLive_fallback`: with no readiness capability, N liveness ticks drive it. `test_codexRolloutBindingIsPhaseScoped`: a Codex card in `launching` beside a live sibling in the same repo does **not** adopt the sibling's rollout — telemetry `discover(cwd:)` binds a rollout only to a card at `launching`+current-epoch or `live` (the review's mis-binding variant of bug #6).
- [ ] **Step 2 — Run red** → FAIL (startup hook currently dropped at `+Report.swift:52-53`).
- [ ] **Step 3 — Implement.** Consume `SessionStart(source:.startup)` as the Claude readiness trigger → `transition(.live(...))` (`.running` if the card has a prompt in flight, else `.waiting(.humanTurn)` — Task 2.5's landing rule). Wire Codex `session_meta` as the Codex trigger, with the phase/epoch-scoped binding gate. Add the N-liveness-tick fallback for `.relaunchLiveness`/no-capability agents. Gate strictly on `adapter.capabilities.resumeConfirmation` — no `if agentId ==`.
- [ ] **Step 4 — Run green** → PASS for both agents.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): capability-gated Ready signal drives launching->live (claude+codex)"`

### Task 2.7: Docs

- [ ] Update `docs/03-data-model.md` (phase/epoch fields; `status`/`waitReason` removed; on-disk migration) + `docs/04-cards-worktrees-sessions.md#recovery-resume-and-restart` (the funnel) + `docs/09-design-decisions.md` (new phase/epoch decision; wire-break decision). Commit `docs(lifecycle): document phase funnel + epochs`.

---

## Stage 3 — WorktreeRegistry + `--progress` + idle-reset Proc

**Deliverable:** A single actor owning worktree lifecycle with refcount, materialized marker, and one removal policy; race-free ensure; activity-aware checkout timeout.

### Task 3.1: Idle-reset watchdog in `Proc` + the timeout Config knobs

**Files:** Modify `Sources/OrchestraCore/Proc.swift`, `Sources/OrchestraCore/Config.swift`; Test `Tests/OrchestraCoreTests/ProcTimeoutTests.swift`

**Interfaces produced:** `Proc.run(..., idleTimeout: Duration?)` — resets the deadline whenever bytes flow on stdout/stderr (the `readabilityHandler`, `Proc.swift:51`), rather than a fixed wall-clock deadline. `Config` gains **new** knobs (main has none — the named timeouts in older drafts were branch-only): `worktreeAddTimeout` (default 180s, applied as *idle* timeout), `sessionLaunchTimeout` (default 30s), `controlVerbTimeout` (default 15s), `fastGitTimeout` (default 10s). All **additive-optional** so an old `config.json` still decodes.

- [ ] **Step 1 — Failing test.** `test_idleTimeoutResetsOnOutput`: a child that emits a byte every 200ms for 3s under `idleTimeout: .milliseconds(500)` **completes** (not killed); a child silent for > idleTimeout is killed. `test_configTimeoutDefaults`: the knobs default as above and are overridable. `test_configForwardCompat`: a `config.json` without the new keys decodes, keeping defaults.
- [ ] **Step 2 — Run red** → FAIL (only wall-clock timeout exists; no knobs).
- [ ] **Step 3 — Implement.** Add `idleTimeout`; in the `readabilityHandler` (`:51`) reset a monotonic "last activity" deadline; the waiter kills only after `idleTimeout` of silence. Keep the existing wall-clock `timeout` as an optional absolute cap. Add the Config knobs.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(proc): activity-aware idle-reset watchdog + launch/checkout timeout knobs"`

### Task 3.2: `--progress` + bounded prune in `WorktreeManager`

**Files:** Modify `Sources/OrchestraCore/WorktreeManager.swift:39,:41,:146`; Test `Tests/OrchestraCoreTests/WorktreeTests.swift`

- [ ] **Step 1 — Failing test.** `test_worktreeAddUsesProgress`: the `git worktree add` argv includes `--progress`. `test_pruneIsBounded`: the fallback prune (`:146`) is invoked with a timeout (no unbounded `Proc.run`). `test_worktreeAddTimesOut`: an absurdly short timeout makes `ensure` throw rather than hang.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Add `--progress` to both add invocations (`:39`, `:41`); pass `config.fastGitTimeout` to the prune (`:146`). Use `idleTimeout: config.worktreeAddTimeout` (Task 3.1) for the add so a huge-repo checkout that is *making progress* isn't killed. Also bound `remove` and the borrow ops with the same knobs.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): --progress on add; bounded prune"`

### Task 3.3: `WorktreeRegistry` actor — ensure + refcount + materialized marker

**Files:** Create `Sources/OrchestraCore/WorktreeRegistry.swift`; Test `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift`

**Interfaces produced:**
```
actor WorktreeRegistry {
  func ensure(repo: String, branch: String, cardId: UUID, base: String? = nil) async throws -> Worktree
                                          // joins refcount if same branch; re-materializes if marker absent; validates path
  func release(cardId: UUID, force: Bool) async throws                              // one removal policy; idempotent to missing tree
  func refcount(branch: String) async -> Int
  func rebuildRefcounts(from cards: [Task]) async                                   // startup: derive counts from persisted card refs
  // borrow lifecycle (the branch-tree bare-parent borrow; delegates git to WorktreeManager.borrow)
  func ensureBorrow(repo: String, parentBranch: String, borrowerCardId: UUID) async throws -> Worktree // exactly-one-borrower
  func releaseBorrow(borrowerCardId: UUID) async throws                             // removes only the borrower's registration
  func sweepOrphanBorrows() async                                                    // startup reconciler job
}
```

- [ ] **Step 1 — Failing test.** `test_concurrentSameBranchEnsureJoinsRefcount`: two concurrent `ensure(sameBranch)` calls yield the same worktree, `refcount == 2`, and `git worktree add` runs **once** (no `branchInUse` error). `test_halfCutDirNotAdopted`: a bare dir at the path without the materialized marker is re-created, not adopted. `test_ensureReMaterializesMissingTree`: an `ensure` for a card whose marked tree was deleted re-creates it from the branch. `test_refcountRebuiltFromCards`: `rebuildRefcounts` derives the correct per-branch counts from a set of persisted cards (survives a simulated restart). `test_ensureRejectsPathEscape`: a branch name with `..` components (or one whose computed path escapes the worktrees root, component-wise) throws — no card can be born with an out-of-root `cwd`. `test_exactlyOneBorrower`: a second `ensureBorrow` on the same parent throws with the existing borrower named.
- [ ] **Step 2 — Run red** → FAIL (WorktreeManager races; adopts via bare `fileExists`; no rebuild).
- [ ] **Step 3 — Implement.** Actor serializes ensure per branch; maintains `[branch: refcount]` + `[cardId: branch]` + the borrow registry (absorbing `borrowedWorktrees` from `OrchestraService.swift:60` / `+Borrow.swift:43-52`); writes a **materialized marker** (a sentinel file / registry record) only after a *complete* checkout; adopts only when the marker is present (replaces the bare `fileExists` at `WorktreeManager.swift:29`), else re-materializes. `rebuildRefcounts` is called once at daemon start from the persisted non-archived cards — the count is **derived, never persisted**. Delegates the actual git to `WorktreeManager` (whose `Proc.run` now executes on this actor — off the service actor by construction).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): WorktreeRegistry actor with refcount + materialized marker"`

### Task 3.4: One removal policy via `release()`

**Files:** Modify `WorktreeRegistry.swift`; Test `WorktreeRegistryTests.swift`

- [ ] **Step 1 — Failing test.** `test_releaseNeverRemovesWhileReferenced` (refcount>0 → dir kept); `test_releaseNeverRemovesDirtyWithoutForce` (dirty + `force:false` → kept, no throw-escalation to data loss); `test_releaseHonorsCreatedFlag` (a not-created/adopted tree is not deleted); `test_releaseIdempotentToMissingTree` (releasing an already-deleted tree is a no-op success, never throws); `test_releaseNeverRemovesOutsideOwnedRoots` (a card whose `cwd` points outside the worktrees root / `orch-borrow-*` roots — e.g. a borrowed dir — is **never** rm'd by any release path, force or not).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** `release` decrements refcount; removes only when `refcount==0 && (!dirty || force) && created && pathUnderOwnedRoots`; a missing tree short-circuits to success. This is the single policy — sibling logic becomes the refcount.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(worktree): single removal policy in release()"`

### Task 3.5: Route all teardown through `release()`

**Files:** Modify `OrchestraService.swift` (archive `:660-702`, spawn orphan-rollback `:345-351`, borrow sweep `:665-668`), `+Recovery.swift` (reopen `:211`), `+Borrow.swift` (`:43-77`); Test `DaemonLifecycleTests.swift`

- [ ] **Step 1 — Failing test.** `test_archiveWithSiblingKeepsTree` (now via refcount) + `test_spawnRollbackNeverForceRemovesSharedTree`: the orphan-rollback path (a lineage-record failure after the tree was cut, `:345-351`) routes through `release(force:false)` — it can no longer destroy a tree another card references; `test_noDirectWorktreeManagerCalls`: no code path outside the registry calls `WorktreeManager` directly (grep-style/compile-visibility assertion — make `WorktreeManager` `internal` to the registry's file or wrap it).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Replace every direct `worktrees.ensure`/`.remove`/`.borrow`/`.pruneOrphanBorrows` with the registry equivalents. Delete the ad-hoc sibling scan (now the refcount). Archive's open-borrow sweep and startup `sweepOrphanBorrows` route through the registry.
- [ ] **Step 4 — Run green.** Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "refactor(worktree): route all teardown through WorktreeRegistry.release"`

### Task 3.6: Docs

- [ ] Update `docs/04-cards-worktrees-sessions.md#worktrees` + `docs/09-design-decisions.md#11-worktree-card-ownership` (refcount model). Commit.

---

## Stage 4 — Reconciler jobs + Converger contract + startup reconciliation

**Deliverable:** slow verbs (spawn/archive/reopen/resume/restart/handoff) become Convergers driven by the reconciler; startup reconciles persisted phases; the typed verb contract + matrix tests.

### Task 4.1: `Converger` protocol + `ConvergeContext`

**Files:** Create `Sources/OrchestraCore/Converger.swift`; Test `Tests/OrchestraCoreTests/ConvergerTests.swift`

**Interfaces produced:**
```
protocol Converger { var cardId: UUID { get }
  func step(_ ctx: ConvergeContext) async throws   // idempotent
  func verify(_ ctx: ConvergeContext) async -> Bool }
struct ConvergeContext { /* store, registry, sessions, adapters, transition */ }
```

- [ ] **Step 1 — Failing test.** `test_convergerStepIsIdempotent`: calling `step` twice from the same phase yields the same result as once (no double side effect).
- [ ] **Step 2 — Run red** → FAIL (no type).
- [ ] **Step 3 — Implement.** Define the protocol + context.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): Converger protocol + context"`

### Task 4.2: SpawnConverger (creatingWorktree → launching → live)

**Files:** `Converger.swift` (add `SpawnConverger`); modify `OrchestraService.swift` spawn; Test `ConvergerTests.swift`

- [ ] **Step 1 — Failing test.** `test_spawnConvergerCrashRestart`: kill the daemon between `creatingWorktree` and `launching` (and between `launching` and `live`); on reconciler re-run, `verify` becomes true (worktree materialized, session up). Both agents. `test_spawnFailureClassified`: a checkout failure lands `dead(.spawnFailed)` with the git stderr in `deadDetail`; a timeout lands `dead(.spawnFailed)` with an explicit "timed out after Ns" note (no generic passthrough).
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** `SpawnConverger.step` advances one edge idempotently: if `creatingWorktree` → `registry.ensure` then `transition(.launching)`; if `launching` → `finishLaunch` (off-actor; the launch env carries `ORCH_EPOCH=<sessionEpoch>` per Task 2.4) + await readiness → `transition(.live)`. `verify` = worktree materialized + session alive + agent-up. Failure at any step → `transition(.dead(.spawnFailed))` with classified `deadDetail`; teardown via `release(force:false)`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): SpawnConverger (idempotent, crash-safe)"`

### Task 4.3: Archive/Reopen/Resume/Restart/Handoff Convergers

**Files:** `Converger.swift`; modify `OrchestraService.swift` (`archive:660`), `+Recovery.swift` (`reopen:204`, `resume:55`, `restart:146`); Test `ConvergerTests.swift`

- [ ] **Step 1 — Failing test.** One crash-restart test per Converger: `test_reopenConvergerCrashRestart` (no actor freeze — reopen enqueues intent, reconciler materializes off-actor), `test_archiveConvergerReleasesTree`, `test_resume/restartConvergerCrashRestart`. All assert `verify` converges from any step; reopen asserts the actor is **not** blocked during checkout. **Degraded cases:** `test_relaunchReMaterializesMissingWorktree` (delete the tree under a `relaunching` card → Converger `ensure`s it back from the branch + emits a "re-materialized" activity, then reaches `live`); `test_relaunchBranchGoneFailsSafe` (branch also gone → `dead(.resumeFailed)`, `concludeCard` fires). **Supersede races (mined from the discarded branch, Stage 0):** `test_archiveDuringMidCheckout` (archive during the worktree checkout window — from `ebcd88e`); `test_archiveRacesLaunch_reclaimsSession` (archive lands in the narrow post-session-create window → the reconciler's next pass sees `archived` + a live session and kills it + releases the tree **within a tick**; no resurrection by the late success flip — the funnel rejects `archived → live` — from `28cedb5`); **run the supersede tests for worktree, scratch, AND borrowed spawns** (the branch's scratch/borrowed path lost this reclaim once). `test_archiveKeepsFullDutyList`: archive on a branch-tree card cancels its treeStat/child-fanout debounces, stops its remote watch, cancels its merge-request re-nudge timer, sweeps an open borrow, and nudges live children — all still happen via the Converger (today's behaviors at `OrchestraService.swift:665-688`).
- [ ] **Step 2 — Run red** → FAIL (reopen synchronous on-actor `:211`; others not convergers).
- [ ] **Step 3 — Implement.** Each verb's sync part: `transition` to the intent phase + return `(card, rev)`; the reconciler runs the paired Converger off-actor. Reopen: `archived → creatingWorktree`, reconciler re-materializes. Resume/restart: `→ relaunching → live` with the **same knobs** as spawn (`config.sessionLaunchTimeout`/`worktreeAddTimeout` from Task 3.1 — main currently launches unbounded). Restart clears `agentSessionId` in the same patch as its transition (Task 2.5) so the RelaunchConverger derives resume-vs-blank from persisted state alone. The ArchiveConverger's `step()` carries the full duty list above, idempotently.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): archive/reopen/resume/restart/handoff as Convergers"`

### Task 4.4: Reconciler drives Convergers + pre-kill fresh probe + startup reconciliation

**Files:** Modify `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`reconcileLiveness:236`, `recoverSessions:14`), `orchestrad/main.swift:47-53` (boot order); Test `RecoveryTests.swift`

- [ ] **Step 1 — Failing test.** `test_startupReconcilesInFlightPhases`: a persisted `creatingWorktree`/`launching` card whose in-memory job "died" (fresh process) is re-driven to `live` or, if unrecoverable, `dead(spawnFailed)` — no stuck-Creating (fixes #5). `test_preKillProbeIsFresh`: a card the batched snapshot thinks is gone but a fresh per-card probe finds alive is **not** killed (fixes #7). `test_preKillProbeOffActor`: the probe does not run on the actor.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** On startup, slotting into the existing boot order (`main.swift:47-53` becomes: `sweepOrphanScratch → registry.sweepOrphanBorrows → registry.rebuildRefcounts → phase reconciliation (replaces recoverSessions) → rebuildRemoteWatches → rebuildMergeRequestNudges`): (a) rebuild refcounts from the persisted cards; (b) for each `live`/`launching`/`relaunching` card whose tmux session is **still alive**, **adopt** it at the persisted epoch — do **not** relaunch (a daemon crash left the agent running); relaunch only when the session is genuinely gone; (c) for each remaining non-terminal phase instantiate the matching Converger and `step` it (Convergers `ensure` a missing worktree back before launching — Task 4.3); (d) nothing to re-drive for terminal cards — conclusion is derived from the persisted phase, and a blocked parent re-issues `wait` on reconnect and short-circuits on it (Task 2.3's `isConcluded`); `archived` cards get one idempotent `release()` re-attempt (a crash mid-teardown heals). Per tick: keep the cheap batched `sessions.list()` snapshot (off-actor after Task 5.1); liveness applies **only to `live`-phase cards** (Task 2.5's gate); **before any `markDead`/kill**, do a fresh **off-actor** per-card has-session probe stamped with the epoch, and only kill if it confirms absence (spec §P2 tension resolution). Debounce so a many-card startup doesn't thrash.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(converge): reconciler drives Convergers; startup reconciliation; fresh pre-kill probe"`

### Task 4.5: Typed `VerbSpec` on `CommandSchema`/`Command`

**Files:** Modify `Sources/OrchestraKit/CommandCatalog.swift` (`CommandSchema`), `Sources/OrchestraCore/CommandRegistry.swift` (`Command`); Test `Tests/OrchestraCoreTests/VerbContractTests.swift`

**Interfaces produced:** `CommandSchema` gains `kind: VerbKind`, `phaseGate: Set<Phase>`, `idempotency: IdempotencyStory`, `capability: CapabilityRequirement?`; `Command` gains `converger: Converger.Type?`.

- [ ] **Step 1 — Failing test.** `test_everyVerbDeclaresKind`: every registry entry has a `kind`; convergence verbs have a `converger`; mutation verbs have a non-empty `phaseGate`.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.** Extend the structs with the new fields. Classify **all 32 registered verbs** per the finalized spec §6 table: Query = `list/status/sessions/capture/tree/trustState/inbox`; Mutation = `move/send/trust/wait/inbox-edit/inbox-remove/inbox-reorder/set-parent/synced/shipped/merge-request/borrow/release/shell/inspect/closeShell/exec/send-keys`; Convergence = `spawn/batch-spawn/archive/reopen/resume/restart/handoff`. (`rename` stays a status-hook projection per resolved decision §12.3.) `shell`/`inspect` get a real `phaseGate` denying `creatingWorktree/launching/relaunching` — that declaration **is** the bug-#3 fix; add `test_openShellDeniedWhileLaunching` asserting the gate returns a clear error and the agent session name is never claimed by `/bin/sh`.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(verbs): typed VerbSpec (kind/phaseGate/idempotency/capability/converger)"`

### Task 4.6: The two matrix tests

**Files:** `Tests/OrchestraCoreTests/VerbContractTests.swift`

- [ ] **Step 1 — Test A (phase-gate completeness).** `test_everyVerbGatesEveryPhase`: iterate every verb × every `Phase` case; assert the gate decision is explicitly declared (a verb must list allow/deny for each phase — not defaulted). Adding a phase later fails this until every verb decides.
- [ ] **Step 2 — Test B (converger crash-convergence, per phase).** `test_everyConvergerConvergesFromAnyStep`: for each `Converger`, drive it, kill at each `step` boundary, re-run the reconciler, assert `verify` becomes true. Cover the full per-phase restart matrix (spec §P2 crash-recovery): `creatingWorktree`, `launching`, `live`, `relaunching`, `dead`, `archived`.
- [ ] **Step 3 — Test C (adopt-don't-relaunch).** `test_daemonCrashAdoptsLiveSession`: a `live` card whose tmux session is still alive after a daemon restart stays `live` at its **persisted epoch** and the agent is **not** relaunched; `test_launchingAdoptsSurvivingSession` (no duplicate session/card). `test_machineRebootPath`: with tmux gone, a `live` card resumes per capability or → `dead(.rebootUnrevived)`.
- [ ] **Step 4 — Test D (missed readiness).** `test_launchingMissedHookConvergesViaLiveness`: a SessionStart hook that fired while the daemon was down is lost; the N-liveness fallback still drives `launching → live`.
- [ ] **Step 5 — Test E (conclusion derived; wait re-issue).** `test_waitShortCircuitsOnPersistedTerminalPhase`: a card is `dead(.spawnFailed)`; a freshly-issued `wait` on it returns concluded **inline** (no hang) — proves `isConcluded` covers every terminal reason and survives a restart with no stored flag. `test_archivedTeardownReattempted`: a crash mid-archive-teardown heals via idempotent `release()` on boot.
- [ ] **Step 6 — Run.** All green (they exercise Stages 2-4). Fix any gaps they expose.
- [ ] **Step 7 — Commit.** `git commit -m "test(converge): phase-gate + per-phase crash-recovery matrices (adopt/reboot/missed-hook/conclude)"`

### Task 4.7: Docs

- [ ] Update `docs/05-command-reference.md` (verb taxonomy) + `docs/02-architecture.md#request-flow-server-side` (Convergence model). Commit.

---

## Stage 5 — Actor-hygiene sweep + TaskStore split + snapshot-from-cache

**Deliverable:** no subprocess/file IO on the service actor; archived split off; snapshot served from cache.

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

### Task 5.3: TaskStore archived split + telemetry-persist debounce

**Files:** Modify `Sources/OrchestraCore/TaskStore.swift`; Test `TaskStoreTests.swift`

- [ ] **Step 1 — Failing test.** `test_archivedInSeparateFile`: archiving writes to an append-only archive file; a live-card mutation does **not** rewrite archived cards. `test_telemetryPersistDebounced`: N rapid telemetry deltas within the debounce window cause ≤1 disk write. `test_corruptTasksJsonRecovers`: an unparseable `tasks.json` is backed up to `tasks.json.corrupt-<rev>`, logged, and the daemon starts (from the archive file / empty) instead of crash-looping.
- [ ] **Step 2 — Run red** → FAIL (whole-file rewrite incl. archived, `:55-67`; no debounce).
- [ ] **Step 3 — Implement.** Split archived cards to an append-only file loaded lazily; `persist()` writes only live cards. Add a persist debounce for telemetry-origin mutations (reuse the `diffStatDebounce` pattern, `OrchestraService.swift:70`). Keep `rev` monotonic across both files. **On load, wrap the parse:** an unparseable `tasks.json` is renamed to `tasks.json.corrupt-<rev>`, logged, and the store starts from the archive file / empty — never a crash-loop.
- [ ] **Step 4 — Run green.** Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "perf(store): split archived to append-only file; debounce telemetry persists"`

### Task 5.4: Docs

- [ ] Update `docs/02-architecture.md#the-daemon-orchestrad` (actor hygiene + snapshot cache). Commit.

---

## Stage 6 — Idempotency + client deadlines + UI gating

**Deliverable:** idempotent spawn/send over dropped connections; per-RPC deadlines + keepalive; one `displayState` UI contract with honest failures and terminal retry.

### Task 6.1: Client-minted ids (spawn + send)

**Files:** Modify `Sources/OrchestraKit/Model.swift` (`SpawnInput.id: UUID` — required; struct at `:726-774`), `Sources/OrchestraCore/OrchestraService.swift:254` (spawn mint), `ControlServer.swift` (dedup), `BoardStore.swift:670` (mint id client-side); Test `Tests/IntegrationTests/IdempotencyTests.swift`

- [ ] **Step 1 — Failing test.** `test_spawnWithClientIdIsIdempotent`: two spawns with the same client-minted id create **one** card (second returns the existing card@rev). `test_sendWithMessageIdIsIdempotent`: a resent message dedups on the inbox.
- [ ] **Step 2 — Run red** → FAIL (server always mints `:221`; retry = duplicate).
- [ ] **Step 3 — Implement.** Make `id` a required field on `SpawnInput`; the clients (`BoardStore.spawn:670`, the CLI, MCP) mint the `UUID`. Server: if a card with that id exists, return it; else create with that id (delete the server-side `UUID()` mint at `:254`). Same for `send` message ids (dedup on the inbox).
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Commit.** `git commit -m "feat(sync): client-minted ids make spawn/send idempotent"`

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

- [ ] Build (or script) a ~28k-file repo fixture giving a ~9s checkout window. Add `test_slowRepoSpawn`: exercises `--progress` + `Proc` idle-reset (Stage 3), race-free `WorktreeRegistry.ensure` under two same-branch spawns, a non-frozen actor during checkout (Stage 5), and the `creatingWorktree → launching → live` phase walk (Stage 2). Run for **both** agents. Remember the test doctrine: this E2E is *smoke*, not the regression guard — every race it exercises must also have a deterministic stub test. Commit `test(e2e): slow-repo lifecycle fixture`.

## Self-review checklist (run before handing off each stage)

1. **Spec coverage:** every pillar P1-P6 + the verb contract maps to at least one task above (P1→Stage 2; P2→Stage 4; P3→Stage 3; P4→Stages 1,6; P5→Stage 5; P6→Stage 6; verb contract→Stage 4). ✔
2. **Placeholder scan:** no "TBD"/"handle edge cases" — every step names a concrete test + assertion + mechanism + anchor. ✔
3. **Type consistency:** `Phase`/`RunState`/`transition(_:to:observedEpoch:)`/`Converger`/`WorktreeRegistry.ensure/release`/`VerbSpec`/`displayState` names are used identically across tasks. ✔
4. **Agent-agnostic:** readiness (2.6), converger crash tests (4.2-4.3), and the E2E fixture all run claude **and** codex. ✔
5. **Wire break:** `phase` replaces `status`/`waitReason`; required `id`; `Event`/`BoardSnapshot` carry `rev`. The only compat is the one-time on-disk `tasks.json` migration (Task 2.2) — a fixture test asserts every legacy card maps to a correct `phase`. ✔

## Execution handoff

Plan finalized on branch `impl/lifecycle-convergence` (= `main` @ `f1aa568` + these docs). **Execution model (Allen, 2026-07-09):** an **orchestrator card** (Opus 4.8) drives the stages as **child PR cards stacked on this branch** (spawn `--base`, respecting the branch-tree lineage). Each PR card: (1) **first writes its own task-level plan with superpowers:writing-plans**, grounded in the layered-plan documents (`notes/designs/lifecycle-convergence/`) + this plan's stage; (2) implements via **superpowers:subagent-driven-development** (fresh subagent per task, review between tasks); (3) runs **superpowers:requesting-code-review** on its own diff and fixes findings **before** finishing. Each stage is independently reviewable and must leave `swift test` green (both agents where the stage touches agent behavior). After all stages, the orchestrator runs a **final whole-branch review** before handing the branch to Allen.

> **Line-number caveat:** every `file:line` anchor in this plan was re-verified against `main` @ `f1aa568` (2026-07-09). Symbols are stable; if a line drifts during execution, search the symbol.
