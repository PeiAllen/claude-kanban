# PR2 · Stage 2 — Phase enum + transition funnel + epochs — Task Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task (fresh subagent per task, review between tasks, strict TDD). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Orchestra's multi-variable card lifecycle (`status` + `waitReason` + the in-memory `recovering` set) with one persisted `Phase`, a single `transition()` funnel that validates edges and reports `applied`/`noop`/`rejected`, and a per-launch `sessionEpoch` that makes stale signals harmless — with a one-time on-disk migration so Allen's live board survives.

**Architecture:** State-triggered. `Phase` is the persisted *intent* on `Task`; `transition()` is the sole writer of `phase`, gated by the pure `isLegalEdge(from:to:viaSignal:)`, and carrying an atomic `mutate:` hook so a verb's companion field-writes land in the same store patch. Entering a launch-bound phase bumps `sessionEpoch`; signals carry an `observedEpoch` and are dropped when stale. Conclusions fire on non-terminal→terminal edges from the funnel ONLY (`isConcluded ≡ terminal phase` — the durable bug-#2 fix); entering `live` runs `wakeIfPending`. Spawn stays **synchronous** in this stage (walks phases inline); the reconciler + steppers + non-blocking spawn are Stage 4. This is a flag-day: `status`/`waitReason` (and the `AgentStatus` type on the wire) are removed across the daemon + all 3 clients in one PR; the suite gates it.

**Tech Stack:** Swift (Swift Concurrency actors), swift-testing / XCTest (`swift test`), tmux, git worktrees, newline-JSON-RPC over UDS.

**Parent documents (READ, do not re-derive):** `notes/plans/2026-07-08-card-lifecycle-convergence.md` §"Stage 2" (Tasks 2.1–2.7) + §"Global Constraints"; `notes/designs/2026-07-08-card-lifecycle-convergence.md` §P1 (the state machine `isLegalEdge` encodes); vault `notes/designs/lifecycle-convergence/{01-design,02-contract,03-implementation}.md`. This file is the task-level, code-grounded contract for **Stage 2 only**.

> **Revision note (post plan-review R1):** this plan was hardened against a dual Opus+GPT-5.5 adversarial review. The load-bearing fixes: the funnel `mutate:` hook (same-patch writes), the noop rule excluding the `relaunching→relaunching` supersede, the single-bump epoch predicate, the `report()` status-writer reroute + de-double-conclude, the `LegacyStoredBoard` migration path (no `.bak` data-loss trap), the `resumeSeedWake` synchronous atomic claim, `AgentStatus` leaving the wire (report DTO → `RunState`), and readiness covering `relaunching→live` (not just `launching→live`).

## Global Constraints (copied verbatim from the parent plan — every task obeys them)

- **Agent-agnostic.** No `if agentId == "claude"` in shared code. Every mechanism is gated on `adapter.capabilities.*`. Every lifecycle test runs for **both** `claude-code` and `codex`.
- **Break the wire freely; no cross-version interop.** `phase`/`sessionEpoch` are **required** fields; `status`/`waitReason` are **removed** (the `AgentStatus` type does not survive on the wire). The **only** compat kept is the one-time defaulting read of an existing on-disk `tasks.json` (seed `phase` from the old `status`, then drop `status`), integrated with PR1's `{rev, tasks}` `StoredBoard` envelope.
- **Single service actor.** Keep the one `OrchestraService` actor. No per-card executors.
- **Full test suite (~680 tests) stays green after every task.** Full run: `swift test`. Never leave a task red. The flag-day `status` removal (Task 2.2) is the big one — the suite gates it.
- **Fail-safe defaults.** Migration never drops a card: nil `waitReason` → `.humanTurn` (never the unknown bucket); unknown legacy record → `dead(.rebootUnrevived)`; preserve the persisted `deadReason`. Never kill without a fresh epoch-stamped probe.
- **Spawn stays SYNCHRONOUS here.** It walks phases inline during the RPC. Non-blocking spawn is Stage 4, delivered once — do NOT scaffold detached tasks here.
- **Marker stamping for migrated worktrees is DEFERRED to PR3b/Task 3.3.** Do NOT stamp markers in this PR — migrate card *records* only. (Task 2.7 corrects the vault, which currently over-states that the migration stamps markers.)
- **Anchors verified @ `f1aa568`** in the parent plan; re-verified against this worktree's base (PR1 merged, `e706ad1`) in the "Grounding" notes below. If a line drifted, search the symbol.

---

## Grounding — what the code looks like at our base (PR1 merged, `e706ad1`)

These are the real anchors this plan builds on (verified in-worktree). They matter because the flag-day reaches further than `.status`:

| Symbol | Location | Relevance |
|---|---|---|
| `AgentStatus{waiting,running,done,dead}` | `Model.swift:18` | **Removed entirely** in 2.2 (folded into `Phase`; does not survive as a derived/wire type). A UI-only label enum, if needed, gets a new non-wire name |
| `WaitReason{permission,humanTurn}` | `Model.swift:24` | **Kept** as an enum; folded into `RunState.waiting(WaitReason)` |
| `DeadReason{agentExited,sessionVanished,rebootUnrevived,resumeFailed}` | `Model.swift:30` | **Extended** with `.completed`, `.spawnFailed` (2.1) |
| `Task.status/deadReason/deadDetail/waitReason` | `Model.swift:236-239` | `status`+`waitReason` dropped; `deadReason`/`deadDetail` kept; add `phase`/`sessionEpoch`/`phaseChangedAt`/`pendingSeed` |
| `Task.archived: Bool` | `Model.swift:246` | **Kept** (orthogonal, deeply-wired Done-popover flag; archive-verb funnel routing is Stage 4). Migration maps `archived==true → phase .archived(teardownComplete: true)` |
| `SnapshotReport{…, status: AgentStatus?, waitReason: WaitReason?}` | `Model.swift:583-646` | The agent→daemon **push DTO** report() consumes. **Reshape to a `RunState?`-shaped observation** (running / waiting(reason)) so `AgentStatus` leaves the wire. (NB: `TaskStatus` at `Model.swift:420` is `{task, running}` — NOT a status DTO; no work there) |
| `StoredBoard{rev,tasks}` + bare-array fallback + `catch→.bak→[]` | `TaskStore.swift:18,27-40` | Migration integrates HERE. **The real upgrade case is a `{rev,tasks}` envelope whose `tasks` are still legacy** — must NOT hit the `.bak` trap. `peekPersistedRev()` (`:48`) also decodes `StoredBoard` — fix it to read a legacy envelope's `rev` |
| `TaskStore.load()` decode order | `TaskStore.swift:22-40` | Where `LegacyStoredBoard`/`[LegacyTask]` migration runs once |
| `recovering: Set<UUID>` | `OrchestraService.swift:101` | **Deleted** in 2.5 (grace-window role → epochs). Read at `+Recovery.swift:64,150,241,273`, `OrchestraService.swift:433`, `+Report.swift:26,157`, `+Wake.swift:100,129`. **The atomic-claim role survives as a narrow `relaunchClaimed` set (2.5)** |
| `concludeCard` / `isConcluded` / `wait` | `+Wake.swift:61,136,24` | `isConcluded`→phase-based (2.3); `wait` short-circuit must unregister the child |
| `wake` / `resumeSeedWake` | `+Wake.swift:98,123` | Gate on `!recovering.contains` + `t.status == .waiting` — both die; re-express against `phase` + the synchronous `relaunchClaimed` claim |
| `report()` status writes + direct `concludeCard` | `+Report.swift` (`status=` writes; `:158` `concludeCard(id,.exited)`, `:161` `concludeCard(id,.done)`; turnCompleted→`.done`) | 2.2 reroutes status writes to **direct `phase` field-delta writes (interim)**; 2.4 moves them through `transition()` **and deletes BOTH direct `concludeCard` calls** (funnel is the sole concluder) |
| `markDead(id,reason:,detail:,source:)` + 3 callers | `+Report.swift`/`+Recovery.swift:298` (callers `:32,:243,:268`) | Direct `status=.dead` writer → **route through the funnel** so terminal deaths conclude (bug-#2) — 2.5 |
| SessionEnd→`.dead` path | `+Report.swift:24-31` | Epoch-guarded `transition` call site (2.4) |
| `SessionStart` `default: break // startup` + `case "resume"` | `+Report.swift` (source switch) | The **drop point** 2.6 consumes for readiness (startup→launching→live; resume→relaunching→live) |
| `SessionManager.ensure(_:argv:env:)` | `SessionManager.swift:55,64` | The `env` dict is the agent-agnostic `ORCH_EPOCH` stamp point; both adapters merge through `:64` |
| `SessionManager.isAlive(_:)` | `SessionManager.swift:74` | The existing (sync, on-actor for Stage 2) pre-kill probe primitive |
| `Conclusion{cardId,ref,kind}` + `Kind{done,exited}` | `MergeWatch.swift:4-12` | Gains `deadReason: DeadReason?` (wire `{kind, deadReason?}`, 2.3) so `wait` resolves on **all** terminal reasons |
| `AgentCapabilities.resumeConfirmation{sessionStartHook,relaunchLiveness}` | `AgentCapabilities.swift:47,93` | Claude=`.sessionStartHook`, Codex=`.relaunchLiveness`. Readiness gating (2.6) — see **Open Decision D1** |
| `Telemetry{hooksPush,fileTail,ptyScrape}` | `AgentCapabilities.swift:23` | Claude=`.hooksPush`, Codex=`.fileTail` (rollout tail) |
| Codex resume writes **no** rollout | `CodexAdapter.swift:349-351` | ∴ Codex `relaunching→live` cannot use rollout readiness — it relies on the **N-liveness fallback** (drives D1) |
| `reconcileLiveness` `recovering` gate | `+Recovery.swift:241` | Replaced by phase rules (2.5) |
| resume path reads `resumeConfirmation` | `+Recovery.swift:95-116` | Existing readiness dependence — 2.6 must not make resume an accidental casualty |

### Open Decision D1 — how readiness (`launching→live` AND `relaunching→live`) is capability-gated

The parent plan wants readiness gated on `adapter.capabilities.*` with **no `if agentId ==`**, driven by: Claude `SessionStart` hook; Codex rollout `session_meta` time-scoped via mtime > `phaseChangedAt`; a universal N=3-liveness fallback. Two complications the reviews surfaced:
1. The existing `ResumeConfirmation` enum has only `{sessionStartHook, relaunchLiveness}` and Codex is `.relaunchLiveness` (reads as "fallback-only"), contradicting the `[codex]` rollout test.
2. Readiness must cover **both** `launching→live` (fresh spawn) **and** `relaunching→live` (resume/restart/handoff, per Task 2.5). But **Codex resume writes no rollout** (`CodexAdapter.swift:349-351`), so a rollout-based readiness cannot confirm a Codex *relaunch* — it must fall through to N-liveness.

**Recommendation (bake into 2.6 unless review overrides): generalize the capability to `readinessConfirmation`** (rename `resumeConfirmation`, or add a parallel `launchReadiness` axis — pick the lower-churn one at impl time) with three values:
- `.sessionStartHook` (Claude) → `SessionStart(source:.startup)` confirms `launching→live`; `SessionStart(source:.resume)` confirms `relaunching→live` (Claude already fires both — see `+Report.swift` `case "resume"`).
- `.rolloutMeta` (Codex) → rollout `session_meta` (mtime > `phaseChangedAt`) confirms `launching→live`; **relaunch has no rollout → the fallback carries it.**
- **Universal N=3-liveness fallback for ANY value**, applied to BOTH `launching` and `relaunching` cards whose specific signal hasn't arrived within N ticks (so `.relaunchLiveness` stubs and Codex relaunches converge). `N × tickInterval < sessionLaunchTimeout` (knob is Stage 3; N=3 ≈6s ≪ 30s).

This keeps readiness on one capability axis, no `if agentId ==`. **Record it as an explicit spec amendment** in `docs/09` + the vault "Decisions made" tables (2.7). Alternative considered: gate Codex on `telemetry == .fileTail` — rejected (mixes telemetry-transport with readiness semantics), though it is textually closer to the spec's current wording.

---

## File structure (Stage 2)

| File | Change | Task |
|---|---|---|
| `Sources/OrchestraKit/Model.swift` | Add `Phase`/`RunState` (+ reuse `WaitReason`); extend `DeadReason` (`.completed`,`.spawnFailed`); add `phase`/`sessionEpoch`/`phaseChangedAt`/`pendingSeed` to `Task`; **drop** `status`/`waitReason`; **remove `AgentStatus` from the wire** (reshape `SnapshotReport.status/waitReason` → a `RunState?` observation); custom `{name,detail?}` Codable; `Phase.Kind` helper; `LegacyTask` DTO + `Task.init(migratingFrom:)` | 2.1, 2.2 |
| `Sources/OrchestraCore/TaskStore.swift` | Migration read: `LegacyStoredBoard{rev,tasks:[LegacyTask]}` + bare `[LegacyTask]`, record-by-record, preserve `rev`, never `.bak`-trap; fix `peekPersistedRev()` | 2.2 |
| `Sources/OrchestraCore/OrchestraService+Lifecycle.swift` (**new**) | `TransitionResult`; `isLegalEdge`; `transition(_:to:observedEpoch:mutate:)` funnel; epoch bump; conclusions; `wakeIfPending`; epoch guard + nil-epoch discipline | 2.3, 2.4 |
| `Sources/OrchestraCore/OrchestraService+Wake.swift` | Redefine `isConcluded` (phase-based); `wait` short-circuit unregisters; re-express `wake`/`resumeSeedWake` against `phase` + the synchronous `relaunchClaimed` claim | 2.3, 2.5 |
| `Sources/OrchestraCore/MergeWatch.swift` | `Conclusion` gains `deadReason: DeadReason?` | 2.3 |
| `Sources/OrchestraCore/OrchestraService.swift` | Delete `recovering` (`:101`); add narrow `relaunchClaimed: Set<UUID>`; spawn (`:245-451`) walks phases via `transition()` (still sync) | 2.5 |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | Delete `recovering` + `scheduleRecoveringRelease`/`releaseRecovering` + the grace-window release (epochs replace them); **RENAME** the confirmation machinery (`awaitResume`→`awaitReadiness`, `resolveResume`→`resolveReadiness`, `ResumeOutcome`→`ReadinessOutcome`, `pendingResumeConfirmations`→`pendingReadiness`, `resumeWaiters`→`readinessWaiters`; keep the `.superseded` waiter-displacement `:320`); route resume/restart/reopen/`markDead` through the funnel + `mutate:` (restart replicates its `:185-193` persist block; reopen uses the `creatingWorktree` path; markDead concludes); liveness + `recoverSessions` phase filters; N=3 launching/relaunching tick counter | 2.5, 2.6 |
| `Sources/OrchestraCore/OrchestraService+Report.swift` | Status writes → interim direct-`phase` (2.2) → `transition(…, observedEpoch:, mutate:)` (2.4); **delete direct `concludeCard`/turnCompletion conclude calls** (2.4); consume `SessionStart(startup/resume)` for readiness (2.6) | 2.2, 2.4, 2.6 |
| `Sources/OrchestraCore/SessionManager.swift` | `ORCH_EPOCH` in launch env; `stampedEpoch(name:)` readback (`tmux show-environment`) | 2.4 |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | (per D1) `readinessConfirmation: .rolloutMeta`; wire `session_meta` readiness w/ mtime binding | 2.6 |
| `Sources/OrchestraKit/AgentCapabilities.swift` | (per D1) generalize to `readinessConfirmation` + add `.rolloutMeta` | 2.6 |
| **Flag-day reader sweep** (2.2), sources+clients: `Model.swift`, `Push.swift`, `+Wake.swift`, `OrchestraService.swift`, `+Recovery.swift`, `CommandRegistry.swift`, `Theme.swift`, `+Report.swift`, `ClaudeCodeAdapter.swift`, `NeedsYouQueue.swift`, `App/OrchestraApp.swift`, `App/Views/{InspectorView,RecoveryView,CardView}.swift`, `Launcher.swift`(note-file `.status` = false positive, skip), `CLIRunner.swift`, `App-iOS/Views/{NeedsYouTab,BoardCardCell,AgentTakeoverView}.swift`, `App-iOS/Views/CardDetail/{AgentTab,RecoveryView,CardDetailHeader,NotesPage}.swift`, `BoardStore.swift` | every `task.status`/`.waitReason` reader recomputes from `phase` (via the derived helpers below) | 2.2 |
| **Flag-day TEST + Stubs sweep** (2.2): ~28 test files under `Tests/` + `Tests/OrchestraCoreTests/Stubs.swift` (~198 refs) | every `Task(status:…, waitReason:…)` **constructor** → `Task(phase:…)` (the `init` drops those params; derived getters do NOT fix constructors). Orthogonal to Stage-4's `spawnAndAwaitLive` timing migration | 2.2 |
| `Tests/OrchestraCoreTests/{ModelCodableTests,TaskStoreTests,PhaseTransitionTests(new)}.swift`, `Tests/IntegrationTests/*` | all Stage-2 tests | all |
| `docs/03-data-model.md`, `docs/04-cards-worktrees-sessions.md#recovery-resume-and-restart`, `docs/09-design-decisions.md`; vault `02-contract.md`+`03-implementation.md` (marker-stamping correction) | SSOT + deviations | 2.7 |

**Derived-helper decision (DRY, honest-label — resolves the 6→4 projection concern):** the flag-day touches 74 read sites. Add to `Task` in OrchestraKit **one non-wire computed helper** — `var phaseDisplay: PhaseDisplayKey` — where `PhaseDisplayKey` is a **new UI-only enum, NOT `Codable`, NOT on any wire type** (it never persists, never crosses RPC). Define its mapping honestly, including the being-born phases the old 4-bucket `AgentStatus` could not represent:
- `.live(.running)` → `.running` · `.live(.waiting(.permission))` → `.needsPermission` · `.live(.waiting(.humanTurn))` → `.idle`
- `.creatingWorktree` → `.starting` · `.launching` → `.launching` · `.relaunching` → `.relaunching`
- `.dead(.completed)` → `.done` · `.dead(other)` → `.dead` · `.archived(*)` → `.done`
Also add `var waitReason: WaitReason? { if case .live(.waiting(let r)) = phase { r } else { nil } }` (derived). Label sites read `phaseDisplay`; gating/Recovery read `phase` directly. This keeps client↔daemon labels from drifting and foreshadows Stage 6's `displayState` (which supersedes `phaseDisplay`). `AgentStatus` is **deleted** — it does not survive as a mirror.

---

## Task 2.1 — `Phase`/`RunState` types + extended `DeadReason` + `Task` fields

**Files:** Modify `Sources/OrchestraKit/Model.swift`; Test `Tests/OrchestraCoreTests/ModelCodableTests.swift`

**Interfaces — Produces:**
```swift
public enum WaitReason: String, Codable, Sendable { case permission, humanTurn }   // unchanged
public enum RunState: Codable, Equatable, Sendable { case running; case waiting(WaitReason) }
public enum DeadReason: String, Codable, Sendable {
    case agentExited, sessionVanished, rebootUnrevived, resumeFailed   // kept
    case completed, spawnFailed                                         // NEW
}
public enum Phase: Codable, Equatable, Sendable {
    case creatingWorktree, launching       // creatingWorktree = "materialize cwd" — ALL spawns enter here
    case live(RunState)
    case relaunching
    case dead(DeadReason)
    case archived(teardownComplete: Bool)
    public enum Kind: String, Sendable { case creatingWorktree, launching, live, relaunching, dead, archivedPending, archivedComplete }
    public var kind: Kind { get }          // for stepper dispatch (Stage 4) + terminal/bump checks
    public var isTerminal: Bool { get }    // dead(*) || archived(*)
}
// Task gains: var phase: Phase ; var sessionEpoch: Int ; var phaseChangedAt: Date ; var pendingSeed: String?
```
`Phase`/`RunState` encode as an object `{ "name": <case>, "detail": <associated value> }` (detail present only for cases with a payload — `live`, `dead`, `archived`). E.g. `live(.waiting(.permission))` → `{"name":"live","detail":{"name":"waiting","detail":"permission"}}`; `dead(.completed)` → `{"name":"dead","detail":"completed"}`; `archived(teardownComplete:true)` → `{"name":"archived","detail":true}`.

- [ ] **Step 1 — Failing test.** `ModelCodableTests.test_phaseRoundTrips`: every `Phase` case incl. associated values — `.creatingWorktree`, `.launching`, `.live(.running)`, `.live(.waiting(.permission))`, `.live(.waiting(.humanTurn))`, `.relaunching`, `.dead(.completed)`, `.dead(.spawnFailed)`, `.dead(.agentExited)`, `.archived(teardownComplete:false)`, `.archived(teardownComplete:true)` — encode with `OrchestraJSON.encoder`, decode with `OrchestraJSON.decoder`, assert round-trip equality. Add `test_taskCarriesPhaseFields`: a `Task` round-trips with the four new fields preserved.
- [ ] **Step 2 — Run red.** `swift test --filter ModelCodableTests/test_phaseRoundTrips` → FAIL (no `Phase`).
- [ ] **Step 3 — Implement.** Add `RunState`, extend `DeadReason`, add `Phase` (+ `Kind`/`isTerminal`) with custom `Codable` (`{name,detail?}`). Add the four fields to `Task` + its `init` (defaults: `phase: Phase = .live(.running)`, `sessionEpoch: Int = 0`, `phaseChangedAt: Date = Date()`, `pendingSeed: String? = nil`). Keep `deadReason`/`deadDetail`. Do **not** touch `status`/`waitReason`/`AgentStatus` yet (that is 2.2 — one change at a time).
- [ ] **Step 4 — Run green.** `swift test --filter ModelCodableTests` → PASS. Full `swift test` → green (new optional-with-default fields don't break existing construction).
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): add Phase/RunState(+WaitReason)/epoch to the model"`

---

## Task 2.2 — Remove `status`/`waitReason` (+ `AgentStatus` off the wire); one-time on-disk migration seeds `phase`

**Files:** Modify `Model.swift` (drop `status`/`waitReason`; delete `AgentStatus`; reshape `SnapshotReport`; add `LegacyTask` + `Task.init(migratingFrom:)` + `phaseDisplay`/`waitReason` helpers), `TaskStore.swift` (migration read + `peekPersistedRev`), `+Report.swift` (interim direct-`phase` status writes), the flag-day source+client+test sweeps above; Test `ModelCodableTests.swift`, `TaskStoreTests.swift`

**Interfaces — Produces:**
```swift
// LegacyTask is a BEST-EFFORT (lossy) decoder: `id` is the ONLY required field; EVERY other field is
// optional so a partial/garbage record still decodes. status/waitReason are String? (NOT the deleted
// AgentStatus) so a garbage status never aborts the record. init(migratingFrom:) synthesizes safe
// defaults for any absent field (title "(recovered)", repo/branch/cwd best-effort or "", origin default…).
struct LegacyTask: Decodable {
    let id: UUID                       // the sole truly-required field — its absence is the ONLY drop case
    let status: String?; let waitReason: String?; let deadReason: DeadReason?; let archived: Bool?
    let title: String?; let repo: String?; let branch: String?; let cwd: String?; let origin: CardOrigin?
    let updatedAt: Date?               // + every other Task field, all optional/best-effort
}
struct LegacyStoredBoard: Decodable {          // the {rev,tasks}-with-legacy-records envelope
    let rev: Int; let tasks: [MigratedRecord]  // custom init(from:) decodes `tasks` ELEMENT-BY-ELEMENT (see below)
}
enum MigratedRecord { case ok(Task); case unparseable }   // .unparseable ONLY when id is absent; never throws the board
extension Task { init(migratingFrom legacy: LegacyTask) }   // seeds phase + fills defaults; never throws; drops only id-less
extension Task { var phaseDisplay: PhaseDisplayKey }        // non-wire UI label (mapping above)
extension Task { var waitReason: WaitReason? }              // derived from phase
public enum PhaseDisplayKey { case starting, launching, relaunching, running, idle, needsPermission, dead, done }  // NOT Codable
// SnapshotReport: `status: AgentStatus?` + `waitReason: WaitReason?` → `run: RunState?` (a running/waiting(reason) observation)
```
**Migration mapping** (`init(migratingFrom:)`), precedence top-to-bottom (matching the **lenient `String?`** `legacy.status`):
- `legacy.archived == true` → `.archived(teardownComplete: true)`
- `legacy.status == "running"` → `.live(.running)`
- `legacy.status == "waiting"` → `.live(.waiting(WaitReason(rawValue: legacy.waitReason ?? "") ?? .humanTurn))`  ← **nil/unknown waitReason is common on idle cards; never route to unknown**
- `legacy.status == "done"` → `.dead(.completed)`
- `legacy.status == "dead"` → `.dead(legacy.deadReason ?? .agentExited)`  ← **preserve the persisted reason**
- `legacy.status` nil or an **unrecognized** string → `.dead(.rebootUnrevived)` (never throws — the lenient `String?` typing means a garbage status still decodes the record).

`sessionEpoch` seeds `0`, `phaseChangedAt` seeds `legacy.updatedAt ?? Date()`, `pendingSeed` `nil`.

**Only a record missing its `id` (or otherwise undecodable at the element level) is `MigratedRecord.unparseable`** — the sole true "drop" case. `test_migratesUnknownLegacyRecordToSafeTerminal`'s fixture record MUST still carry an `id` (it asserts the card is *kept* as `.dead(.rebootUnrevived)`, not dropped); an id-less record is a genuinely unrecoverable card, logged and skipped without `.bak`-ing the board.

- [ ] **Step 1 — Failing tests.**
  - `TaskStoreTests.test_migratesLegacyTasksJson`: write a pre-upgrade `tasks.json` in **both** shapes and assert both migrate: (a) a **bare `[Task]` legacy array**, and (b) a **`{rev: 7, tasks:[…legacy…]}` envelope** (the real upgrade case). Records: `running`; `waiting` with **nil** `waitReason`; `waiting` with `.permission`; `done`; `dead` with `deadReason: .resumeFailed`; `archived: true`. After `TaskStore.load()`: each card's `phase` per the mapping (nil waitReason → `.live(.waiting(.humanTurn))`; dead preserves `.resumeFailed`; archived → `.archived(teardownComplete:true)`); **no card dropped** (count preserved); and for the envelope, **`currentRev == 7` preserved** (bare array → 0, per PR1).
  - `ModelCodableTests.test_statusFieldRemoved`: encode a fresh `Task`; decode to a `[String:JSONValue]`; assert keys exclude `status` and `waitReason`. Assert `AgentStatus` no longer exists as a type used by `Task` or `SnapshotReport` (compile-level).
  - `TaskStoreTests.test_migratesUnknownLegacyRecordToSafeTerminal`: a `tasks.json` whose one record is missing required legacy fields / has a garbage `status` string → that card loads as `.dead(.rebootUnrevived)`; `load()` does not throw; the card count is preserved; **the file is NOT moved to `.bak`** (the board is not wiped by one bad record).
- [ ] **Step 2 — Run red.** `swift test --filter TaskStoreTests/test_migratesLegacyTasksJson` → FAIL.
- [ ] **Step 3 — Implement.**
  1. Delete `status`/`waitReason` stored fields from `Task` (+ `init`). **Delete `AgentStatus`.** Add `PhaseDisplayKey` (non-Codable) + the `phaseDisplay`/`waitReason` derived helpers.
  2. Reshape `SnapshotReport` (`Model.swift:583-646`): replace `status: AgentStatus?` + `waitReason: WaitReason?` with `run: RunState?` (the agent's observed running/waiting(reason)). Update `report()`'s consumption accordingly (it will map `run` → a `.live(runState)` phase write — interim direct in this task, funnel-routed in 2.4).
  3. Add `LegacyTask` (best-effort: `id` required, **all other fields optional**, `String?` status/waitReason) + `Task.init(migratingFrom:)` (**synthesizes safe defaults for every absent field** — title `"(recovered)"`, repo/branch/cwd best-effort-or-`""`, origin default — so a record that has an `id` but is missing other fields is **kept** as a `.dead(.rebootUnrevived)` card, never dropped) + `LegacyStoredBoard` **with a custom `init(from:)`** that decodes `tasks` **element-by-element into `[MigratedRecord]`**: for each element try `LegacyTask` → `.ok(Task(migratingFrom:))`; the **only** per-element failure is a missing/undecodable `id` → `.unparseable` (logged + skipped). One bad element never throws the whole board. `load()` keeps the `.ok` tasks. (A typed `[LegacyTask]` array would decode atomically — one bad element throws everything → `.bak` wipe; the custom element-wise `init(from:)` + best-effort `LegacyTask` is what prevents that.)
  4. **`TaskStore.load()` (`:22-40`) decode order — avoid the `.bak` data-loss trap:** `Task` uses **synthesized** `Codable` (the custom `init(from:)` at `Model.swift:789` is `SpawnInput`, not `Task`), so a legacy record missing the `phase` key throws `keyNotFound` and the `StoredBoard` decode fails cleanly. Order: try `StoredBoard` (post-upgrade `{rev,tasks:[Task]}`); on failure try **`LegacyStoredBoard`** (element-wise migrate, **preserve `rev`**); then bare `[Task]`; then bare `[LegacyTask]` (element-wise migrate, `rev=0`); only a genuinely unparseable *file* (not a bad record) falls to the existing `catch → .bak → []`. **A legacy board must never reach that catch.** Detection is **structural** (which decode succeeds) — NOT "inspect a decoded record for a missing `phase`" (a missing non-optional field throws during decode; you never get the record to inspect).
  5. Fix `peekPersistedRev()` (`:48`) to also read a `LegacyStoredBoard`'s `rev` (else first boot desyncs `lastRev` to 0 on a real upgrade).
  6. **Marker stamping is DEFERRED (PR3b/3.3) — do not stamp here.**
  7. **Flag-day source+client sweep:** replace every `task.status` reader with `task.phaseDisplay` (label sites) or a direct `phase` read (gating/Recovery), and every `task.waitReason` reader with the derived helper, across the ~22 real files above (skip `Launcher.swift`'s note-file `.status` false positive). For `+Report.swift`/`+Wake.swift`, this task only makes them **compile against `phase`** by rerouting `report()`'s status writes to **direct `phase` field-delta writes** (`store.update` patching `phase`) — the funnel reroute + de-double-conclude is 2.4; the `isConcluded`/`resumeSeedWake` phase rewrites are 2.3/2.5.
  8. **Flag-day TEST + Stubs sweep:** rewrite every `Task(status:…, waitReason:…)` **constructor** across ~28 test files + `Stubs.swift` to `Task(phase:…)`. (Derived getters fix readers, not constructors.)
- [ ] **Step 4 — Run green.** `swift test --filter TaskStoreTests` + `--filter ModelCodableTests` → PASS. Then **full `swift test` → green** (the flag-day; fix every reader + constructor until the whole suite + all 3 client targets compile and pass).
- [ ] **Step 5 — Commit.** `git commit -m "refactor(lifecycle): remove status/waitReason; migrate on-disk tasks to phase"`

---

## Task 2.3 — The `transition()` funnel + `isLegalEdge` + conclusions + wake-on-live

**Files:** Create `Sources/OrchestraCore/OrchestraService+Lifecycle.swift`; modify `+Wake.swift` (`isConcluded`, `wait`), `MergeWatch.swift` (`Conclusion.deadReason`); Test `Tests/OrchestraCoreTests/PhaseTransitionTests.swift` (new)

**Interfaces — Produces:**
```swift
enum TransitionResult: Equatable { case applied; case noop; case rejected(from: Phase, to: Phase) }
extension OrchestraService {
  @discardableResult
  func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil,
                  mutate: @Sendable (inout Task) -> Void = { _ in }) async -> TransitionResult
  static func isLegalEdge(from: Phase, to: Phase, viaSignal: Bool) -> Bool   // pure; viaSignal admits dead→live revival
}
// MergeWatch.Conclusion gains: public let deadReason: DeadReason?
```
The `mutate:` hook applies companion field-writes **in the same `store.update` patch** as the `phase`/`sessionEpoch`/`phaseChangedAt` write (restart clears `agentSessionId`, handoff sets `pendingSeed`, spawn-fail sets `deadDetail` — all atomic with the phase change; consumed in 2.4/2.5).

**The edge set (`isLegalEdge`) — from spec §P1 / 01-design's stateDiagram, encode EXACTLY:**
- `creatingWorktree → launching` · `creatingWorktree → dead` · `creatingWorktree → archived`
- `launching → live` · `launching → dead` · `launching → archived`
- `live → live` (status hook running↔waiting) · `live → relaunching` · `live → dead` · `live → archived`
- `relaunching → relaunching` (**supersede**) · `relaunching → live` · `relaunching → dead` · `relaunching → archived`
- `dead → relaunching` (restart) · `dead → archived` · `dead → live` **iff `viaSignal == true`** (REVIVAL — no verb may drive it)
- `archived → archived` (teardown pending→complete: `false→true` only) · `archived → creatingWorktree` (reopen)
- Everything else → `false`.

- [ ] **Step 1 — Failing test (pure edges).** `PhaseTransitionTests.test_illegalEdgesRejected`: enumerate representative pairings across every `Phase.Kind`; assert `isLegalEdge` is `true` exactly for the edges above, `false` otherwise. Explicit asserts: `isLegalEdge(.relaunching, .relaunching, viaSignal:false) == true`; `isLegalEdge(.dead(.completed), .live(.running), viaSignal:true) == true` and `… viaSignal:false) == false`; `isLegalEdge(.archived(false), .archived(true), …) == true`; `isLegalEdge(.archived(true), .archived(false), …) == false`; `isLegalEdge(.relaunching, .archived(false), …) == true`; `isLegalEdge(.dead(.spawnFailed), .relaunching, …) == true`.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement `isLegalEdge`.** Pure function over `(from.kind, to.kind)` + the `viaSignal` gate on `dead→live` + the `archived false→true` direction check. No I/O, no actor state.
- [ ] **Step 4 — Run green** → PASS.
- [ ] **Step 5 — Failing test (funnel).**
  - `test_transitionRejectsIllegalEdge`: seed `.dead(.completed)`; `transition(id, to:.live(.running))` (verb-path, `observedEpoch:nil`) → `.rejected(from:.dead(.completed), to:.live(.running))`, stored `phase` unchanged.
  - `test_transitionNoopIsIdempotent`: seed `.archived(teardownComplete:true)`; `transition(id, to:.archived(teardownComplete:true))` → `.noop`; unchanged; no event/conclusion. **AND** `test_relaunchSupersedeIsNotNoop`: seed `.relaunching`; `transition(id, to:.relaunching)` → `.applied` (NOT `.noop`) and `sessionEpoch` **bumps** (the supersede edge must survive the idempotency rule).
  - `test_sendDuringProvisioningDeliveredOnLive`: seed `.creatingWorktree`; enqueue a message (parks in inbox); `transition(→.launching)` (no wake); `transition(→.live(.running))` → `wakeIfPending` fires, message delivered. Repeat starting from `.launching`.
  - `test_deadToArchivedDoesNotReconclude`: parent watches child C; drive C `→.dead(.agentExited)` (conclusion #1 fires); then `transition(C, →.archived(teardownComplete:false))` → **no second conclusion**.
- [ ] **Step 6 — Implement `transition`.** In `OrchestraService+Lifecycle.swift`:
  1. Load the card; `from = card.phase`. **Noop rule (must not swallow the supersede):** if `to == from` **AND `from.kind != .relaunching`** → return `.noop` (no persist, no event, no conclusion). The `relaunching→relaunching` self-edge falls through to apply.
  2. Epoch guard (finished in 2.4): `viaSignal := (observedEpoch != nil)`; if `observedEpoch != nil && observedEpoch != card.sessionEpoch` → `.noop` (drop stale).
  3. `guard isLegalEdge(from:from, to:to, viaSignal:viaSignal) else { log; return .rejected(from:from, to:to) }`.
  4. **Field-delta patch (one `store.update`):** stamp `phaseChangedAt = Date()`; set `phase = to`; **epoch bump predicate — `if to.kind == .creatingWorktree || to.kind == .relaunching { sessionEpoch += 1 }`** (spawn bumps once at `creatingWorktree`, NOT again at `launching`; every `relaunching` entry incl. the supersede self-edge bumps; reopen's `creatingWorktree` bumps). **Note:** `launching` is intentionally omitted because the machine only ever enters it from `creatingWorktree` (already bumped); if a future direct-entry-to-`launching` edge is ever added, revisit this predicate so it doesn't silently skip a bump. Then apply `mutate(&task)` **inside the same closure** (companion writes atomic with the phase change).
  5. **Conclusions (funnel is the sole concluder):** if `!from.isTerminal && to.isTerminal` → `await concludeCard(id, kind, deadReason:)` where `kind`/`deadReason` derive from `to` (2.3a). Never on `dead→archived` (guarded by `!from.isTerminal`).
  6. **Wake-on-live:** if `to.kind == .live` → `await wakeIfPending(id)` (if the inbox has undelivered messages and the card is now `.live(.waiting)`, run the existing wake). The single structural release point.
  7. Emit `.taskUpserted`. Return `.applied`.
- [ ] **Step 6a — `isConcluded` redefinition + `Conclusion.deadReason`.** In `+Wake.swift`:
  ```swift
  func isConcluded(_ t: Task) -> Conclusion.Kind? {
      if case .archived = t.phase { return .done }
      if t.archived { return .done }                 // archive-verb funnel routing is Stage 4; keep the Bool bridge
      if case .dead(let r) = t.phase { return r == .completed ? .done : .exited }
      return nil
  }
  ```
  Add `deadReason: DeadReason?` to `Conclusion` (nil for archived/done); thread it through `concludeCard`/`firstConcluded`/the fan-out notice. `wait` now resolves on **every** terminal reason (the durable bug-#2 fix). Update existing `isConcluded` callers + `Conclusion(...)` constructors.
- [ ] **Step 6b — `wait`/`watch` short-circuit unregisters.** In `wait` (`+Wake.swift:24`) **and `watch` (`:15-19`, which also short-circuits via `firstConcluded`)**, when a settled child is returned, **unregister it** from `watchRegistry[watcher]` (mirror `concludeCard`'s `remove(id)` + empty-set cleanup) before returning — else a revival→re-death re-notifies. Add `test_waitShortCircuitUnregistersChild`: watch C; C already `.dead`; `wait(watcher,[C])` returns C's conclusion; then `transition(C → archived)` → watcher gets **no** second notice.
- [ ] **Step 7 — Run green** → PASS. Full `swift test` → green.
- [ ] **Step 8 — Commit.** `git commit -m "feat(lifecycle): single transition() funnel with edge validation"`

---

## Task 2.4 — Epoch guard for stale signals + route report's status/exit writes through the funnel

**Files:** Modify `OrchestraService+Lifecycle.swift` (finish the guard), `SessionManager.swift` (`ORCH_EPOCH` env + `stampedEpoch`), `+Report.swift` (status writes → `transition`; delete direct `concludeCard`), the launch call sites (stamp epoch), `Stubs.swift` (isAlive seam); Test `PhaseTransitionTests.swift`, `SessionManagerTests` (or inline)

**Interfaces — Produces:**
```swift
extension SessionManager { func stampedEpoch(name: String) throws -> Int? }   // tmux show-environment -t <name> ORCH_EPOCH
// launch env gains ORCH_EPOCH=<task.sessionEpoch>, merged in SessionManager.ensure(_:argv:env:)
```

- [ ] **Step 1 — Failing tests.**
  - `test_staleSessionEndIgnored`: card `sessionEpoch=2`; deliver a `SessionEnd` (via the report path) stamped `observedEpoch=1` → the `→.dead` transition is a no-op (card NOT killed). Same signal `observedEpoch=2` → applies.
  - `test_nilEpochKillSignalRequiresProbe`: a kill-class signal (`SessionEnd`) with `observedEpoch=nil` (pre-upgrade session) does **not** transition directly — the existing `isAlive` probe must confirm the session is gone first (probe stub "alive" → not killed; "gone" → killed). A nil-epoch **status** signal (running↔waiting) **does** pass (nil-epoch discipline is kill-class only).
  - `test_reportStatusWritesGoThroughFunnel`: a running→waiting report drives `transition(→.live(.waiting(...)))` (phase updated, one `.taskUpserted`). `test_turnCompletionConcludesReadOnlyOnly`: a `turnCompleted` report on a **read-only freeform/scratch** card (shouldConcludeOnTurnCompletion=true) drives `transition(→.dead(.completed))` and fires **exactly one** conclusion; a `turnCompleted` report on a **worktree** card drives `transition(→.live(.waiting(.humanTurn)))` (NOT terminal, no conclusion).
  - `test_stampedEpochParses`: `stampedEpoch` parses `ORCH_EPOCH=3` → `3`; absent/unset → `nil`.
- [ ] **Step 2 — Run red** → FAIL.
- [ ] **Step 3 — Implement.**
  1. Finalize the epoch guard from 2.3 step 2; add **nil-epoch discipline**: a kill-class target (`to.kind == .dead`) with `observedEpoch == nil` applies only after the existing (Stage-2: sync, on-actor) `SessionManager.isAlive` probe confirms the session is gone (reuse the `+Report.swift` `staleSessionEnd` machinery + `isAlive`). Status-class nil-epoch signals pass unchanged. Add the `isAlive`/`removed` recorder seam to `Stubs.swift` (test-doctrine).
  2. **Reroute `report()`'s status/exit writes** (the interim direct-`phase` writes from 2.2) through `transition(id, to:…, observedEpoch:, mutate:{ $0.deadDetail = … })`. **Preserve the existing turn-completion gate:** a `turnCompleted` report maps to `.dead(.completed)` **only when `shouldConcludeOnTurnCompletion(task)` is true** (`+Report.swift:116-120,183-184` — non-worktree read-only cards); otherwise a completed turn maps to `.live(.waiting(.humanTurn))` (worktree cards stay long-lived, NOT terminal). Running↔waiting reports map to `.live(.running)`/`.live(.waiting(r))`. **Delete BOTH of report's direct conclude calls (`:158` `concludeCard(id,.exited)` and `:161` `concludeCard(id,.done)`)** — conclusions now come only from the funnel (prevents double-conclude).
  3. **Stamp:** add `ORCH_EPOCH=\(task.sessionEpoch)` to the `env` dict passed to `SessionManager.ensure` (agent-agnostic — both adapters merge `:64`). The hook payload echoes it → `handleHook` passes it as `observedEpoch`.
  4. **Readback:** add `SessionManager.stampedEpoch(name:) throws -> Int?` wrapping `tmux show-environment -t <name> ORCH_EPOCH`. (Consumer is Stage 4; the parse test above keeps it live.)
  5. Thread `observedEpoch` through the SessionEnd/liveness transition call sites (`+Report.swift:24-31`; the liveness caller passes the card's own `sessionEpoch`).
- [ ] **Step 4 — Run green** → PASS. Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): epoch guard makes stale liveness signals harmless"`

---

## Task 2.5 — Delete `recovering`; route spawn/resume/restart/handoff through the funnel (spawn stays synchronous)

**Files:** Modify `OrchestraService.swift` (delete `recovering` `:101`; add `relaunchClaimed: Set<UUID>`; spawn `:245-451`), `+Recovery.swift` (resume `:55`, restart `:146`, reconcile gate `:241`, delete `scheduleRecoveringRelease`/`releaseRecovering`/`.superseded` waiter `:315-327`), `+Wake.swift` (`wake`/`resumeSeedWake`), `+Report.swift` (`:26,157` recovering reads — already epoch-guarded in 2.4); Test `DaemonLifecycleTests.swift`, `RecoveryTests.swift`, new `SpawnPhaseTests.swift`

> **Notes:** the `provisioning` flag/dict do NOT exist on this base — only `recovering` is deleted. `recovering` played **two** roles: (a) a grace-window against stale SessionEnds — now covered by **epochs** (2.4); (b) a **synchronous atomic claim** so a concurrent wake/relaunch defers — this role survives as a narrow `relaunchClaimed: Set<UUID>` (inserted synchronously on the service actor before any `await`, cleared on completion).
>
> **Synchrony model (Stage 2): spawn AND resume/restart/reopen stay SYNCHRONOUS** — each walks its phases inline during the RPC, *including an inline readiness wait*, and returns a `live` (or `dead`-on-failure) card, so today's spawn/resume/restart-then-assert tests keep passing. Non-blocking + reconciler-driven readiness is Stage 4. Do NOT scaffold detached tasks.
>
> **Fate of the resume-confirmation machinery:** it is **RETAINED and generalized**, not deleted. `awaitResume`→`awaitReadiness`, `resolveResume`→`resolveReadiness`, `ResumeOutcome`→`ReadinessOutcome{confirmed,timedOut,superseded}`, `pendingResumeConfirmations`→`pendingReadiness`, `resumeWaiters`→`readinessWaiters` (`+Recovery.swift:306-347`). It is the **inline readiness-wait primitive** for the synchronous launch — used by spawn (`launching→live`), resume/restart (`relaunching→live`), and reopen (`launching→live`). The 2.6 readiness signal (`SessionStart`/rollout/N-liveness) calls `resolveReadiness(id)` to unblock the inline waiter; the verb then does `transition(→.live)`. The `.superseded` waiter-displacement logic (`:320`) STAYS (a newer relaunch supersedes the inline waiter). What IS deleted: `scheduleRecoveringRelease`/`releaseRecovering` + the grace-window release (epochs replace the stale-SessionEnd guard). Keep `awaitReadiness`'s "consume `pendingReadiness` synchronously before registering" invariant (`:308-312`).

- [ ] **Step 1 — Failing tests (new `SpawnPhaseTests.swift` + additions).**
  - `test_spawnDrivesPhases`: every spawn (worktree/scratch/borrowed) walks `.creatingWorktree` (instant for non-worktree cwds) `→.launching →.live`, `sessionEpoch` **exactly `1`** at every step (set at creation, NOT bumped again at `launching`), `phaseChangedAt` stamped on each transition. `test_spawnInitialRecordIsCreatingWorktree`: the record persisted by `store.create` (before any transition) is `.creatingWorktree` with `sessionEpoch == 1`.
  - `test_livenessSkipsBeingBornPhases`: a session-less card in `.creatingWorktree`/`.relaunching` is **not** killed by `reconcileLiveness`; a `.launching` card whose (already-created, sync-spawn) session **vanished** → `.dead(.spawnFailed)`.
  - `test_promptedSpawnLandsRunning` / `test_provisionalSpawnLandsWaiting`: a prompted spawn lands `.live(.running)`; a no-prompt spawn lands `.live(.waiting(.humanTurn))` (via the sync-spawn readiness stub; full readiness is 2.6).
  - `test_relaunchSupersede`: card `.relaunching`; `restart` applies the supersede self-edge, `sessionEpoch` bumps again, the first attempt's old-epoch completion signal is dropped.
  - `test_deadCompletedRevivesOnSignal`: a `.dead(.completed)` card with a surviving session revives to `.live(.running)` on an epoch-current **agent signal** (`viaSignal:true`); **no verb** drives that edge.
  - `test_concurrentWakeDoesNotDoubleResume`: two concurrent `wake`s on an idle `.live(.waiting)` card resume **once** (the `relaunchClaimed` guard makes the second defer). Guards the idle-Claude double-resume race the old `recovering` claim protected.
  - `test_reopenDrivesCreatingWorktreePath`: reopen of an `.archived` card walks `archived → creatingWorktree → launching → live` (NOT `→relaunching`), re-materializes the cwd, and lands live with the transcript resumed when resumable. `test_reopenBlankWhenTranscriptGone`: reopen of an archived card whose transcript is gone lands live via a blank launch (still through `creatingWorktree→launching`).
- [ ] **Step 2 — Run red** → FAIL / won't compile against `recovering`.
- [ ] **Step 3 — Implement.**
  1. **Delete `recovering`** (`:101`) + its machinery in `+Recovery.swift` (`scheduleRecoveringRelease`, `releaseRecovering`, the `.superseded` waiter `:315-327`). Add `var relaunchClaimed: Set<UUID> = []` on the service actor.
  2. **`wake`/`resumeSeedWake` (`+Wake.swift:98-131`):** re-express against `phase`. `wake` guard `!t.archived, !recovering.contains(id)` → `guard case .live = t.phase, !relaunchClaimed.contains(id)`. `resumeSeedWake` guard `t.status == .waiting` → `guard case .live(.waiting) = t.phase`. **Atomic claim:** synchronously (no `await` before it) `relaunchClaimed.insert(t.id)`, THEN launch the detached resume; clear it (`relaunchClaimed.remove`) when the resume settles. This preserves the pre-`await` atomicity the old synchronous `recovering.insert` gave. Do NOT use `transition(→.relaunching)` as the claim — it `await`s (hops to `TaskStore`) and the `relaunching→relaunching` supersede edge is *legal*, so two wakes would both pass and both resume.
  3. **`+Report.swift:26,157`:** the `!recovering.contains(id)` guards are already replaced by the epoch guard (2.4).
  4. **Spawn (`:245-451`, still sync) — the card is CREATED in `.creatingWorktree`, not transitioned into it.** `transition` loads an existing card and there is no `*→creatingWorktree` edge except reopen's `archived→creatingWorktree`; a fresh spawn has no prior card. So at `OrchestraService.swift:415-425` build the initial `Task(phase: .creatingWorktree, sessionEpoch: 1, phaseChangedAt: <now>, …)` (replace the old `status: provisional ? .waiting : .running`) and `store.create` it — **creation sets epoch=1 by construction (this IS spawn's single bump; do NOT also `transition(→.creatingWorktree)`)**. Then: materialize cwd inline → `transition(→.launching)` (no bump) → launch inline (stamping `ORCH_EPOCH=1`) → inline readiness wait (`awaitReadiness`, 2.6) → `transition(→.live(...))`. Failure at any inline step → `transition(→.dead(.spawnFailed), mutate:{ $0.deadDetail = <git stderr | "timed out after Ns"> })`.
  5. **Resume/restart/handoff (`+Recovery.swift:55,146` + `+Wake.swift` handoff engine):** `transition(→.relaunching, mutate:)` → kill+ensure inline → inline `awaitReadiness` → `transition(→.live(.waiting), observedEpoch: newEpoch)`. **Restart's `mutate:` must replicate the REAL persist block (`+Recovery.swift:185-193`), not hardcode nil:** `$0.agentSessionId = freshId` (`freshId = adapter.newSessionId()` for `.seeded`, `nil` for `.discovered`), `$0.priorSessionIds = prior` (old id appended), `$0.titleProvisional = true`, `$0.deadReason = nil`, `$0.deadDetail = nil`, `$0.desc = ""` — all inside the transition closure (was a separate `store.update` at `:185`). **Handoff/seeded-wake** persist `pendingSeed` via `mutate:` (`$0.pendingSeed = <folded drained inbox + summary>`); cleared only on readiness at the current epoch. Resume's `mutate:` clears `deadReason`/`deadDetail` (was `:120-122`).
  6. **Reopen (`+Recovery.swift:204-230`) — legal phase path `archived → creatingWorktree → launching → live`** (spec §P1 has NO `archived→relaunching` edge). Rewrite: `transition(→.creatingWorktree)` (legal from archived; epoch bumps; also clears the `archived: Bool` + dead metadata via `mutate:`) → ensure cwd (the existing `worktrees.ensure`/mkdir per origin) → `transition(→.launching)` → launch with the **resume flavor** (`isResumable` → resume the transcript, else blank) via the shared inline-launch helper → `awaitReadiness` → `transition(→.live)`. Do **NOT** call `resume()`/`restart()` (they enter via `→.relaunching`, illegal from `creatingWorktree`); factor the launch+confirm step so it is callable from the `launching` phase (a small `launchAndConfirm(id, flavor:)` helper shared by spawn/reopen), reusing resume/restart's flavor logic.
  7. **`markDead` (`:298-304`) MUST route through the funnel** so a non-terminal→terminal death fires `concludeCard` (the bug-#2 fix — today it writes `status=.dead` directly and never concludes, so a suspended `wait` hangs on a crash/reboot/resume-fail death). Rewrite `markDead(id, reason:, detail:, source:)` to call `transition(id, to:.dead(reason), mutate:{ $0.deadDetail = detail })` then `emitActivity(.dead, …)`. Its 3 callers (`recoverSessions:32` reboot-unrevived, `reconcileLiveness:243` sessionVanished, `failResume:268` resumeFailed) are **deliberate classifications that have already established death** (aliveNames miss / probe / definitive resume failure) — they transition with `observedEpoch: nil` and are NOT subject to the nil-epoch-kill probe gate (that gate lives at the inbound-SessionEnd signal site, 2.4). Add `test_waitResolvesOnCrashDeath`: a parent `wait`s a child; the child's session vanishes (liveness → `markDead(.sessionVanished)`) → the parent's `wait` resolves with a `.exited`/`deadReason:.sessionVanished` conclusion (not just clean `.agentExited`).
  8. **Liveness (`+Recovery.swift:241`):** replace `if recovering.contains(t.id){continue}` with the phase rules from Step 1 (skip `.creatingWorktree`/`.relaunching`; `.launching` + vanished session → `.dead(.spawnFailed)`; only `.live` cards get liveness-killed after a fresh probe, via the funnel-routed `markDead`). Also update `recoverSessions:15` (`filter { $0.status != .dead }`) to a phase filter (`!$0.phase.isTerminal`).
- [ ] **Step 4 — Run green.** Full `swift test` → green (spawn still sync, so spawn-then-assert tests survive; update any expectation referencing `status`/`recovering` to phases).
- [ ] **Step 5 — Commit.** `git commit -m "refactor(lifecycle): delete recovering set; phases via funnel (spawn still sync)"`

---

## Task 2.6 — Readiness signal `launching→live` AND `relaunching→live` (capability-gated, both agents)

**Files:** Modify `OrchestraService.swift` `handleHook`, `+Report.swift` (SessionStart `startup`→launching, `resume`→relaunching), `+Recovery.swift` (N=3 tick counter), `CodexAdapter.swift` (rollout `session_meta` readiness + mtime binding), `AgentCapabilities.swift` (per **D1**: generalize to `readinessConfirmation`, add `.rolloutMeta`, set Codex); Test `Tests/IntegrationTests/` (both agents)

> Resolve **Open Decision D1** in plan review first. Steps assume the recommended resolution (rename to `readinessConfirmation`; values `{sessionStartHook, rolloutMeta, relaunchLiveness}`; universal N=3 fallback covering launching AND relaunching).

- [ ] **Step 1 — Failing tests (both agents, both transitions).**
  - `test_launchingToLive_onReady[claude]`: `.launching` + Claude; `SessionStart(source:.startup)` → `transition(→.live(...))` (`.running` if a prompt is in flight, else `.waiting(.humanTurn)`).
  - `test_launchingToLive_onReady[codex]`: `.launching` + Codex; a rollout `session_meta` line with mtime > `phaseChangedAt` → `transition(→.live(...))`.
  - `test_relaunchingToLive_onReady[claude]`: `.relaunching` + Claude; `SessionStart(source:.resume)` → `transition(→.live(...))`.
  - `test_relaunchingToLive_fallback[codex]`: `.relaunching` + Codex (**resume writes no rollout**); N=3 liveness ticks drive `→.live`.
  - `test_launchingToLive_fallback`: an agent with no readiness-specific signal (or a lost one); N=3 liveness ticks drive `.launching→.live`. Assert `N × tickInterval < sessionLaunchTimeout` (N=3 ≈6s ≪ 30s).
  - `test_codexRolloutBindingIsTimeScoped`: a Codex `.launching` card beside a live sibling in the same repo does **not** adopt the sibling's rollout; after a simulated mass reboot a `.relaunching` card does **not** adopt its own **stale pre-reboot** rollout — `discover(cwd:)` binds only rollouts with mtime > `phaseChangedAt` (newest-after-launch; on ambiguity bind nothing — fallback carries readiness).
- [ ] **Step 2 — Run red** → FAIL (startup hook dropped at `+Report.swift` `default: break`).
- [ ] **Step 3 — Implement.**
  The readiness signal's job is to **`resolveReadiness(id)`** — unblock the verb's inline `awaitReadiness` (2.5's sync model); the verb then does `transition(→.live(...))` per the landing rule. (The landing `.running` vs `.waiting(.humanTurn)` is decided by the verb: prompt-in-flight → running.)
  1. **Generalize the capability (D1):** rename `resumeConfirmation` → `readinessConfirmation` (or add a parallel axis — lower-churn wins); values `{sessionStartHook, rolloutMeta, relaunchLiveness}`. Claude = `.sessionStartHook`; Codex = `.rolloutMeta`.
  2. **Claude (`.sessionStartHook`):** in the `SessionStart` source switch (`+Report.swift`), consume `source == "startup"` (today `default: break`) → `resolveReadiness(id)` for a `.launching` card (spawn's inline waiter). Keep `source == "resume"` → `resolveReadiness(id)` for a `.relaunching` card (rename of today's `resolveResume` at `:51/:330`). Both `launching` and `relaunching` are covered by the one hook capability.
  3. **Codex (`.rolloutMeta`):** the resume-path capability switch (`+Recovery.swift:96`) must handle all three values — `.sessionStartHook` → `awaitReadiness`; `.rolloutMeta` → **always `awaitReadiness`** (for a **launching** card the rollout tail observer calls `resolveReadiness` on the `session_meta` line; for a **relaunching** card `codex resume` writes no rollout (`CodexAdapter.swift:349-351`), so **the N=3 `launchReadyTicks` fallback resolves the waiter** — do NOT return immediately, which would leave no pending waiter and bypass the readiness gate); **only `.relaunchLiveness` → immediate ensure-is-confirmation** (its capability literally means "successful `ensure` IS the confirmation"). Wire the rollout `session_meta` observation (`CodexAdapter.sessionId(fromRollout:)`/parse) with the **mtime-after-`phaseChangedAt`** binding in `discover(cwd:)` (newest rollout whose mtime > `phaseChangedAt`; ambiguity → bind nothing). This keeps `.rolloutMeta` relaunch on the readiness gate (D1: "relaunch has no rollout → the fallback carries it"), not off it.
  4. **Universal N=3 fallback (safety net within the grace window):** in `reconcileLiveness`, keep a small in-memory `launchReadyTicks: [UUID: Int]` counter; for a `.launching` **or** `.relaunching` card with a live session and a still-pending inline waiter, increment per tick and at N=3 call `resolveReadiness(id)` (before `awaitReadiness`'s grace timeout would fail the verb). Applies to any capability value (covers `.relaunchLiveness`, Codex relaunch, missed hooks). `N × tickInterval < sessionLaunchTimeout` (N=3 ≈6s ≪ 30s). Reset the counter when the card leaves the being-born phase.
  5. Strictly capability-gated — **no `if agentId ==`**.
- [ ] **Step 4 — Run green** → PASS for both agents. Full `swift test` → green.
- [ ] **Step 5 — Commit.** `git commit -m "feat(lifecycle): capability-gated Ready signal drives launching/relaunching->live (claude+codex)"`

---

## Task 2.7 — Docs + vault sync

**Files:** `docs/03-data-model.md`, `docs/04-cards-worktrees-sessions.md#recovery-resume-and-restart`, `docs/09-design-decisions.md`; vault `notes/designs/lifecycle-convergence/{02-contract,03-implementation}.md`

- [ ] **Step 1.** `docs/03-data-model.md`: the `Phase` enum + `RunState`/extended `DeadReason`, the four new `Task` fields; **`status`/`waitReason` removed, `AgentStatus` off the wire (`SnapshotReport` → `RunState`)**; the `{name,detail?}` Codable; the one-time on-disk migration (mapping table + fail-safe rules + the `LegacyStoredBoard`/bare-array paths + `rev` preservation) integrated with PR1's envelope.
- [ ] **Step 2.** `docs/04…#recovery-resume-and-restart`: the `transition()` funnel (incl. the `mutate:` same-patch hook), the phase machine / `isLegalEdge` edge list, the noop-excludes-supersede + single-bump epoch rules, epochs + `ORCH_EPOCH` stamp/readback + stale-signal drop + nil-epoch probe discipline, `isConcluded ≡ terminal phase` + funnel-only conclusions, wake-on-live, the `relaunchClaimed` atomic claim. Note spawn is still synchronous (reconciler/steppers are Stage 4).
- [ ] **Step 3.** `docs/09-design-decisions.md`: the phase/epoch decision; the wire-break (status→phase, `AgentStatus` off the wire, only-compat = on-disk migration); the **D1 resolution** (`readinessConfirmation` generalization covering launching+relaunching, universal fallback) recorded as a **spec amendment**; `Conclusion` gains `deadReason`.
- [ ] **Step 4 — Fold deviations into the vault** (`02-contract.md` + `03-implementation.md` "Decisions made" tables): the `mutate:` hook, the noop/bump rules, the `relaunchClaimed` split of `recovering`'s two roles, the `SnapshotReport`→`RunState` reshape, the D1 `readinessConfirmation` amendment, the `archived: Bool`-bridge in `isConcluded`. **AND correct the marker-stamping claim:** `02-contract.md:45-46,87-95` and `03-implementation.md:23-25` currently say the migration stamps materialized markers — update them to say **PR2 migrates card records only; PR3b/Task 3.3 stamps markers** (so implementers don't pull Stage 3 work forward). Commit `docs(lifecycle): document phase funnel + epochs`.

---

## Self-review (run before requesting plan review)

1. **Spec coverage:** 2.1 types · 2.2 removal(+AgentStatus off wire)+migration · 2.3 funnel+edges+conclusions+wake+mutate hook · 2.4 epochs+report reroute+de-double-conclude · 2.5 recovering-delete(+relaunchClaimed)+funnel routing(sync spawn) · 2.6 readiness(launching+relaunching, both agents) · 2.7 docs+vault. Every parent Stage-2 sub-task maps. ✔
2. **Named tests present (all 21 parent-mandated + additions):** `test_phaseRoundTrips`, `test_migratesLegacyTasksJson`, `test_statusFieldRemoved`, `test_migratesUnknownLegacyRecordToSafeTerminal`, `test_illegalEdgesRejected`, `test_transitionRejectsIllegalEdge`, `test_transitionNoopIsIdempotent`, `test_deadToArchivedDoesNotReconclude`, `test_sendDuringProvisioningDeliveredOnLive`, `test_staleSessionEndIgnored`, `test_nilEpochKillSignalRequiresProbe`, `test_spawnDrivesPhases`, `test_livenessSkipsBeingBornPhases`, `test_promptedSpawnLandsRunning`, `test_provisionalSpawnLandsWaiting`, `test_relaunchSupersede`, `test_deadCompletedRevivesOnSignal`, `test_launchingToLive_onReady[claude]`, `test_launchingToLive_onReady[codex]`, `test_launchingToLive_fallback`, `test_codexRolloutBindingIsTimeScoped`. Additions: `test_taskCarriesPhaseFields`, `test_relaunchSupersedeIsNotNoop`, `test_waitShortCircuitUnregistersChild`, `test_reportStatusWritesGoThroughFunnel`, `test_stampedEpochParses`, `test_concurrentWakeDoesNotDoubleResume`, `test_relaunchingToLive_onReady[claude]`, `test_relaunchingToLive_fallback[codex]`, `test_waitResolvesOnCrashDeath` (markDead concludes — bug-#2), `test_reopenDrivesCreatingWorktreePath`, `test_reopenBlankWhenTranscriptGone`, `test_spawnInitialRecordIsCreatingWorktree` (created at `.creatingWorktree`, epoch=1), `test_turnCompletionConcludesReadOnlyOnly` (worktree turnCompleted stays live). ✔
3. **Type consistency:** `Phase`/`RunState`/`Phase.Kind`/`PhaseDisplayKey`/`TransitionResult`/`transition(_:to:observedEpoch:mutate:)`/`isLegalEdge(from:to:viaSignal:)`/`Conclusion.deadReason`/`stampedEpoch(name:)`/`readinessConfirmation`/`awaitReadiness`/`resolveReadiness`/`ReadinessOutcome`/`launchAndConfirm`/`relaunchClaimed` used identically across tasks. ✔
4. **Agent-agnostic:** readiness (2.6) gated on `readinessConfirmation`; launching+relaunching tests run claude **and** codex; no `if agentId ==`. ✔
5. **Flag-day green:** `status`/`waitReason`/`AgentStatus` removed in 2.2 with the source+client sweep (~22 files) AND the test-constructor+Stubs sweep (~28 files); full `swift test` green after every task; spawn stays sync so spawn-then-assert tests survive. ✔
6. **Fail-safe:** migration never drops a card (nil waitReason→humanTurn, unknown→dead(.rebootUnrevived), preserve deadReason); the real `{rev,tasks}`-legacy-envelope path never hits `.bak`; nil-epoch kill needs a probe. ✔
7. **No double-work / no scope creep:** funnel is the sole concluder (report's direct conclude deleted); marker stamping, reconciler, steppers, non-blocking spawn, WorktreeRegistry, verb phaseGate all deferred. ✔

## Open decisions (resolve in plan review)

- **D1 — readiness capability** (see Grounding §D1). Recommendation: generalize `resumeConfirmation`→`readinessConfirmation` with `{sessionStartHook, rolloutMeta, relaunchLiveness}`, universal N=3 fallback covering launching AND relaunching (Codex resume writes no rollout → fallback). **Decide before Task 2.6.**
- **D2 — `archived: Bool` coexistence.** Kept this stage (archive-verb funnel routing = Stage 4); `isConcluded` bridges via both `phase == .archived` and `t.archived`. Confirm acceptable (routing `archive` through the funnel now would pull Stage-4 Teardown scope forward — not recommended).
- **D3 — `SnapshotReport` reshape.** Resolved: replace `status: AgentStatus?`/`waitReason: WaitReason?` with `run: RunState?` (a running/waiting(reason) observation) so `AgentStatus` leaves the wire; `report()` maps `run` → `.live(runState)` via the funnel. (NB: `TaskStatus` at `Model.swift:420` is `{task,running}` — not a status DTO; no work there.) Confirm the `run`-shaped wire is acceptable vs. a bespoke observation enum.
