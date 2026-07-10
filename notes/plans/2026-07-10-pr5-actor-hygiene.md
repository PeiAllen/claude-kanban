# PR5 — Actor Hygiene + Telemetry Debounce + Snapshot-from-Cache — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage 5 of card-lifecycle-convergence — a **pure perf/hygiene pass** (no behavior change): move every remaining blocking subprocess/file-IO call off the `OrchestraService` actor, serve `boardSnapshot`'s per-card session state from a reconciler-maintained cache, and debounce telemetry-origin disk writes.

**Architecture:** The one `OrchestraService` actor must never freeze on subprocess/file IO. Wrap each blocking site in the existing `offActor { … }` hop (`OrchestraService+Recovery.swift:305`), bounding each moved call with the PR3a Config knobs (`controlTimeout` / `sessionLaunchTimeout`, already the enforcement primitive at each site's `Proc.run`/`timeout`). `boardSnapshot` stops shelling per card: the reconcile tick writes each card's observed tmux window state into an in-memory `observedSessions` cache (off-actor), and `boardSnapshot` reads it. Telemetry (`report()`) mutations still bump `rev` + update memory synchronously, but their `tasks.json` disk write is coalesced through a debounce twin of `diffStatDebounce`.

**Tech Stack:** Swift (Swift Concurrency actors), swift-testing / XCTest (`swift test`), tmux, git, `Proc.run` (wall-clock-bounded subprocess), newline-JSON-RPC over UDS.

**Companion design vault:** `notes/designs/lifecycle-convergence/` (index + 01-design + 02-contract + 03-implementation §9 actor-hygiene list). **Stage plan:** `notes/plans/2026-07-08-card-lifecycle-convergence.md`, Stage 5 (Tasks 5.1–5.4). All §/P references point there. I am **PR5** — perf-only, running **in parallel with PR6a** (`lc/6a-idempotency-deadlines`, wire-level).

## Global Constraints

- **No *observable* behavior change.** Pure hygiene/perf. Every moved call preserves semantics, ordering, error-handling, and the wire/event stream. Where a mechanism has an unavoidable micro-effect (telemetry write coalescing → bounded cross-restart `rev` regression; `gitRemotes` memo; snapshot session-state staleness), it is (a) bounded, (b) self-healing or reconstructable, and (c) recorded as an explicit Decision. **Reviewers verify equivalence per site.**
- **Cross-PR `rev` contract — an EXPLICIT NEW requirement PR5 hands PR6a (do not overclaim).** PR5's telemetry debounce means the **on-disk `rev` can lag in-memory `rev`**, so after a **hard crash** `TaskStore.load()` may restore a `rev` *lower* than one a connected client already saw. Today this is harmless: `BoardStore.refresh` (`BoardStore.swift:475`) adopts a reconnect snapshot **wholesale with no `rev` cursor**, so a reconnect already resets to snapshot ground truth. The hazard appears **only when PR6a adds `lastSeenRev`**: the vault contract (`02-contract.md:139`) says clients "apply iff `rev > lastSeen`" — a *naive* cursor kept across reconnect would then **drop** post-restart events at `rev ≤ lastSeen`. So PR5 must hand PR6a a **new, explicit** requirement (NOT "already required" — that was an overclaim): **on reconnect, adopt `boardSnapshot.rev` as ground truth and reset `lastSeenRev` to it even if lower than the prior in-process cursor; do not drop subsequent events by the stale cursor.** PR5 surfaces this in the merge-request; PR6a owns the client-side change (out of PR5's scope). Until PR6a lands its cursor, PR5's debounce is already safe (wholesale reconnect). PR5 bounds the exposure three ways (below). **In-lifetime `rev` stays strictly monotonic** (`boardSnapshot` serves the in-memory `currentRev`), so there is no intra-run regression.
- **Every moved `Proc.run` stays bounded.** `offActor` changes *where* a call runs, not *whether* it is bounded. The `+Tree`/`+ParentRef`/`+Remote` git leaves are **currently unbounded** (`Proc.run` with no `timeout`); once made `nonisolated` they gain an explicit `timeout: Duration` parameter fed from `config.controlTimeout` captured **on-actor before the hop** (a `nonisolated` func cannot read the actor's `config`). Adding the bound is a fail-safe improvement aligned with pillar P5 — recorded as a Decision.
- **Agent-agnostic.** No `if agentId == …`. Every mechanism is capability/adapter-neutral (adapters are already `Sendable`).
- **Stay in my sites.** Do **not** touch PR6a's wire-level surface (client-minted ids on `SpawnInput`, RPC deadlines in `ControlClient`, `rev`-gap resync in `BoardStore`). Keep the parallel merge clean — I own `OrchestraService.swift` blocking sites, `+Diff`/`+Notes`/`+Tree`/`+ParentRef`/`+Remote`/`+Converge`/`+Recovery` git+session probes, the reconcile cache, `TaskStore` persist debounce, and a small SIGTERM flush hook in `orchestrad/main.swift`.
- **`swift test` green after every task.** Authoritative gate: `swift test --no-parallel` (815+ tests). The default parallel run shows sporadic real-tmux/UDS/PTY-exhaustion flakes under load — re-run any such failure in isolation to confirm it is environmental, not mine.
- **Fold deviations into the vault** (`03-implementation.md` "Decisions made — PR5 (Stage 5) as-built") and mention them in the merge-request.
- **Anchors** verified against the current worktree tip (post-PR4b). Symbols are the fallback if a line drifted; every anchor below was re-read live while writing/revising this plan.

## Review Round 1 — resolutions (Opus + GPT-5.5, folded in)

Both plan reviewers converged. Their blockers/highs are resolved in-plan as follows (each is applied in the task cited):

| Finding | Resolution | Task |
|---|---|---|
| **B1** telemetry debounce regresses persisted `rev` on crash; Self-Review #5 false | Keep persist-layer debounce (memory + `rev` + emit stay **synchronous**; only the *file write* coalesces, so the wire is unchanged). Bound the exposure: (1) an **immediate mutation force-flushes** pending telemetry (rollback ≤ a pure-telemetry burst since the last non-telemetry write — reconstructable); (2) a **max-deferral cap** checkpoints an always-active card; (3) a **SIGTERM flush** makes clean restarts lossless (launchd sends SIGTERM before SIGKILL). Document the reconnect-cursor-reset contract (Global Constraints) + surface to PR6a. Write failures are **logged + keep the dirty bit** (a later mutation retries), not silently swallowed. Self-Review #5 corrected. | 5.3 |
| **B2** snapshot cache staleness + every-tick N `windows()` + archived cards populated | Populate **non-archived, session-alive** cards only (dead → empty without shelling; bounds idle-daemon cost to live-card count). Cache carries `observedAt`; **miss OR entry older than `card.phaseChangedAt` → live-shell fallback**; **evict on teardown and on shell open/close/inspect** so user-driven changes are never hidden. Reword the deliverable (bounded self-healing staleness; cost shifts on-connect→every-tick-off-actor — a trade, not strictly-better). Add content/miss/eviction/freshness tests. | 5.2 |
| **Tests race** (`list()` may beat the slow op → false-pass on unfixed code; tight 1.0s bound) | **Entered-gate** pattern everywhere: the slow op signals it has **entered** its blocking section, the test waits for that, asserts the fast RPC completes **before** releasing the gate. `exec` uses a **marker-file entry signal** (`touch $MARKER; sleep 5`); diff/telemetry/treeStat use the `NSCondition` gate's `entered` flag. Widen the concurrent-RPC bound to `< 2.0s`. | 5.1.1–5.1.5 |
| **`treeProbeHook` reintroduces actor-state read in `nonisolated` compute + data race** | Make the probe a **call-scoped parameter** — `computeTreeStat(repo:link:timeout:probe:)` takes `probe: (@Sendable () -> Void)? = nil`; the actor captures it (from a `Sendable`-locked test holder) **before** the `offActor` hop and passes it in. `computeTreeStat` stays argument-only. | 5.1.4 |
| **Unbounded git leaves** violate "bound each call" | Thread `timeout: Duration` (from `config.controlTimeout`) into the `nonisolated` leaves. | 5.1.4, 5.1.6 |
| **`gitRemotes` memo staleness** (misclassify after mid-run remote add) | Key the memo by **`.git/config` mtime** — invalidate on change. Cheap `stat`; makes it truly no-behavior-change. | 5.1.4 |
| **`reconcileLiveness()` still shells on-actor** (test-retained legacy; named §9 site) | Wrap its `sessions.list()` in `offActor` too (one line). | 5.1.5 |
| **Missed on-actor sites:** `spawnBranches` (5s freeze), `spawnRepos`, `emitShells`, `isResumable` | Add to the cleanup sweep — these are actor-hygiene (pillar P5), not PR6a's wire surface. `spawnBranches`'s 5s `for-each-ref` freeze is the most compelling. Recorded as a Decision (extended past the orchestrator's literal list to honestly satisfy "no on-actor blocking"). | 5.1.6 |
| **`assertAllowed` dropped in the diff/notes hop snippets** | Keep the allowlist security gate **on-actor before** the hop (it is the security check, not error plumbing). | 5.1.2, 5.1.6 |

## Review Round 2 — resolutions (Opus APPROVABLE; GPT-5.5 3 items — all folded in)

Round-2 re-review verified every Round-1 fix holds (SIGTERM pattern sound, `phaseChangedAt` freshness sound, timeout threading coherent, call-scoped probe clean). Remaining items, all applied:

| Finding | Resolution | Task |
|---|---|---|
| **`emitShells` cache-evict ≠ off-actor hop** (both reviewers) — eviction only affects a future `boardSnapshot`; it does not send the live `shellsChanged`, and does not move the subprocess off-actor. All callers are already `async`. | **Do BOTH:** make `emitShells` `async`, hop `sessions.windows()` off-actor, **and** evict `observedSessions`. Not either/or. | 5.1.6 |
| **`boardSnapshot` cache-hit skips nil-`sessionInfo` cards** (Opus) — an early-life card (session id unbound) has nil `sessionInfo`, so the hit-branch guard failed and it live-shelled every snapshot, defeating the cache. | Serve the same fallback `AgentSessionInfo` `sessions()` builds (`:810-812`) on nil, keeping the card on the cache-hit branch. Test helper includes a nil-`sessionInfo` card so it's exercised, not masked. | 5.2 |
| **Reconnect-cursor-reset was overclaimed as "already required"** (GPT-5.5) — `02-contract.md:139` actually says "apply iff `rev > lastSeen`"; `BoardStore` has no cursor yet. | Reframed as an **explicit NEW requirement** handed to PR6a (adopt `snapshot.rev` as ground truth on reconnect, even if lower), with the note that PR5's debounce is already safe until PR6a's cursor lands. | Global Constraints |
| **`gitRemotes` mtime memo breaks for a linked worktree** (`.git` is a file) (GPT-5.5) | `gitConfigMtime(repo:)` resolves the real config path (dir → `.git/config`; file → parse `gitdir:` → common-dir config) + a linked-worktree invalidation test. Moot for real callers (`task.repo == realRepo`), but keeps the claim unconditional. | 5.1.4 |
| **RED-test compile/hang mechanics** (both) | Seam-before-RED ordering + bounded gate park (self-releases so RED fails cleanly, not a timeout hang) — added as a shared Stage-5.1 test-harness note. | Stage 5.1 |
| **Missing reload-after-flush / SIGTERM-flush tests; stale as-built note** (GPT-5.5) | Added `test_reloadAfterFlushSeesCurrentRev` + `test_flushBeforeShutdownPersists`; corrected the as-built note (mtime memo IS observed). | 5.3, 5.4 |
| **Purity: `resolvedParentRef` on-actor before the diff/notes hop** (Opus) | Fold it **inside** the hop once `nonisolated` (5.1.4). | 5.1.2, 5.1.4 |

## File structure (this PR)

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraCore/OrchestraService.swift` | `exec` / `status` / `sweepOrphanScratch` / `pollTelemetry` off-actor; `boardSnapshot` reads cache; add `observedSessions` cache + `gitRemotesCache` stored props | 5.1.1, 5.1.3, 5.1.5, 5.1.6, 5.2 |
| `Sources/OrchestraCore/OrchestraService+Diff.swift` | `diffText` / `recomputeDiffStat` git off-actor | 5.1.2 |
| `Sources/OrchestraCore/OrchestraService+Notes.swift` | `changedNotes` off-actor | 5.1.2 |
| `Sources/OrchestraCore/OrchestraService+Tree.swift` | mark git-leaf probes `nonisolated`; `recomputeTreeStat`'s compute off-actor; verb-path git off-actor | 5.1.4, 5.1.6 |
| `Sources/OrchestraCore/OrchestraService+ParentRef.swift` | `gitRemotes` per-repo cache; `nonisolated` seam | 5.1.4 |
| `Sources/OrchestraCore/OrchestraService+Remote.swift` | redirect git probes off-actor | 5.1.6 |
| `Sources/OrchestraCore/OrchestraService+Converge.swift` | `prepareToLaunch` off-actor in `finishLaunch` | 5.1.6 |
| `Sources/OrchestraCore/OrchestraService+Reconcile.swift` | populate `observedSessions` cache each tick (off-actor) | 5.2 |
| `Sources/OrchestraCore/TaskStore.swift` | split file-write out of `persist()`; debounced telemetry flush | 5.3 |
| `Sources/OrchestraCore/GitRemotesCache.swift` (new) | tiny lock-guarded per-repo remotes cache (`Sendable`, callable from `nonisolated`) | 5.1.4 |
| `Tests/OrchestraCoreTests/Stubs.swift` | add `windowsCount` recorder + `listSleepMs`/`windowsSleepMs` seams to `StubSessions` | 5.1.5, 5.2 |
| `Tests/IntegrationTests/ActorHygieneTests.swift` (new) | `test_actorNotBlockedBy{Exec,Diff,PollTelemetry,TreeStatRecompute,LivenessList}` | 5.1.* |
| `Tests/OrchestraCoreTests/BoardSnapshotTests.swift` (new) | `test_boardSnapshotDoesNotShell` | 5.2 |
| `Tests/OrchestraCoreTests/TaskStoreTests.swift` | `test_telemetryPersistDebounced` | 5.3 |
| `docs/02-architecture.md#the-daemon-orchestrad` | actor hygiene + snapshot cache | 5.4 |

## Key facts established while writing this plan (read before implementing)

- **The `offActor` hop** (`OrchestraService+Recovery.swift:305`): `nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T` — dispatches `work` on `DispatchQueue.global()` and resumes via a continuation. Non-throwing variant: callers use `try? await offActor { try? … }`. **This is the sole hop; reuse it everywhere.**
- **Already off-actor (PR4b):** the reconcile tick's `sessions.list()` (`+Reconcile.swift:48`, `:221`), `stampedEpoch` probes (`:77`, `:229`), orphan-sweep `isAlive`/`kill` (`:180`, `:185`), `finishLaunch`'s `sessions.kill`/`ensure` (`+Converge.swift:160`), `materialize`'s `branch -D` (`+Converge.swift:95`). So `test_actorNotBlockedByLivenessList` mostly **locks an existing invariant** (Task 5.1.5), and `prepareToLaunch` is the *only* remaining on-actor blocker inside `finishLaunch`.
- **`Sendable` facts (verified):** `GitDiffProvider` (empty struct), `Launcher`, `Adapter`, `AdapterContext`, `AgentRegistry` are all `Sendable`. `TmuxTarget`, `SessionInfo`, `CardSessions`, `AgentSessionInfo` are `Sendable`. So each blocking closure captures only `Sendable` values.
- **`recomputeTreeStat`** (`+Tree.swift:364`) calls the synchronous `computeTreeStat` (`:466`) which fans into `gitRemotes` + `treeTip` + `treeBehind` + `treeBaseIsAncestor` + `resolvableRef` — **all sync `Proc.run` on the actor.** These leaf probes touch **no** actor mutable state (args + `Proc.run` + `RemoteParentRef.parse` only), so they are safe to make `nonisolated` and run inside one `offActor` hop.
- **`report()`'s telemetry write** is the field-delta `store.update(id) { $0.applyReportFields(from: task) }` (`+Report.swift:153`). The phase write goes through `transition()` (`:162`) separately and must **not** be debounced. Only the field-delta half is telemetry-origin.
- **`TaskStore.persist()`** (`TaskStore.swift:129`) both bumps `currentRev` and writes the file. The rev-binding contract (each event carries the rev of its mutation) requires `currentRev` to keep bumping **synchronously**; only the **file write** may be debounced.
- **`boardSnapshot`** (`OrchestraService.swift:779`) calls `sessions(card.id)` (`:802`) per active card → `sessions.windows(name)` (tmux) + `adapter.sessionInfo` (fs). The tmux `windows()` is the shelling the cache eliminates.

---

## Stage 5.1 — Move blocking calls off-actor

**Deliverable:** no subprocess/file IO on the service actor. Six bite-sized tasks: one per gate test (`_byExec`/`_byDiff`/`_byPollTelemetry`/`_byTreeStatRecompute`/`_byLivenessList`) plus a final cleanup sweep for the listed-but-untested sites.

**Test-harness mechanics (apply to every `_by*` task).** Two ordering/robustness rules the entered-gate tests depend on:
- **Seam-before-RED.** Each injection seam (`_setDiffProviderForTest`, `_setTreeProbeForTest`, the `BlockingTelemetryAdapter` registration, the `StubSessions.listSleepMs` field) must be **added to the source in the same step that writes the RED test** (a sub-step *before* running RED), or Step 2 won't compile. The seam existing ≠ the fix existing: the seam is inert until the production call is hopped, so RED still fails on unfixed code.
- **Bounded gate park.** The `Gate.blockUntilOpen()` must **time out** (e.g. park ≤ 10s, then release) so that on **unfixed** code — where the blocking op holds the actor and the concurrent `list()` would otherwise deadlock until the XCTest timeout — the RED test fails **cleanly** via the `< 2.0s` assertion (the gate self-releases, `list()` returns late, assertion fails) instead of hanging. `Gate` = `NSCondition` with `entered: Bool`, `markEntered()`, `waitUntilEntered()`, `blockUntilOpen(timeout:)`, `open()`.

### Task 5.1.1: `exec` off-actor

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:764-772` (`exec`)
- Create: `Tests/IntegrationTests/ActorHygieneTests.swift`

**Interfaces:**
- Consumes: `offActor` (`+Recovery.swift:305`), `list()` (`OrchestraService.swift:666`).
- Produces: nothing new (behavior identical; only the thread the `Proc.run` runs on changes).

- [ ] **Step 1: Write the failing test.** Create `ActorHygieneTests.swift`. Use `IntegrationSupport` to build a real `OrchestraService`. Spawn a live card (helper `spawnAndAwaitLive` if present; else create a card + `seedPhase(.live(...))`). The test is a **deterministic entered-gate order assertion**: the `exec` command writes a marker file (proving the subprocess **entered**), then sleeps; the test waits for the marker, THEN asserts a concurrent `list()` completes while the exec is still sleeping. A false-pass on unfixed code is impossible because we only assert *after* the blocking subprocess has demonstrably started.

```swift
import XCTest
@testable import OrchestraCore
import OrchestraKit

final class ActorHygieneTests: XCTestCase {
  func test_actorNotBlockedByExec() async throws {
    let (service, cardId, cwd) = try await ActorHygieneSupport.liveCardWorktree()
    let marker = "\(cwd)/.exec-entered"
    let slow = Task { try await service.exec(cardId, "touch '\(marker)'; sleep 5") }
    // Wait until the subprocess has ENTERED (marker exists) — up to 3s, polling.
    try await ActorHygieneSupport.waitForFile(marker, timeout: 3.0)
    let start = Date()
    _ = await service.list()                         // must return while `sleep 5` is still running
    XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor exec")
    _ = try await slow.value                          // drain
  }
}
```

Add `ActorHygieneSupport` helpers in the same file: `liveCard(adapter:)` / `liveCardWorktree()` (build a service via `IntegrationSupport`, return a `.live` card + its cwd), `waitForFile(_:timeout:)` (poll `FileManager.fileExists` on a short loop), and a `Gate` (`NSCondition`-backed, with an `entered` flag + `waitUntilEntered()` / `open()`) used by the diff/telemetry/treeStat tests below.

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByExec`
Expected: FAIL — with the on-actor `Proc.run`, `list()` waits behind `sleep 5` (latency ≥ 5s ≥ 2.0).

- [ ] **Step 3: Wrap `exec`'s `Proc.run` in `offActor`.** In `OrchestraService.swift:769`:

```swift
let r = try await offActor {
    try Proc.run(["sh", "-c", cmd], cwd: t.cwd, timeout: timeout ?? .seconds(120))
}
```

`cmd`, `t.cwd`, `timeout` are `Sendable`; the timeout bound is preserved verbatim.

- [ ] **Step 4: Run test to verify it passes.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByExec`
Expected: PASS — `list()` returns well under 1s while `sleep 3` runs off-actor.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/IntegrationTests/ActorHygieneTests.swift
git commit -m "perf(actor): run exec's subprocess off the service actor"
```

### Task 5.1.2: `diffText` / `recomputeDiffStat` / `changedNotes` off-actor

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Diff.swift:18-19` (`diffText`), `:42` (`recomputeDiffStat`); `Sources/OrchestraCore/OrchestraService+Notes.swift:16` (`changedNotes`)
- Modify: `Tests/IntegrationTests/ActorHygieneTests.swift`

**Interfaces:**
- Consumes: `offActor`; `GitDiffProvider` (`Sendable`), `Launcher` (`Sendable`), `resolvedParentRef` (String result, `Sendable`).
- Produces: identical returns; git runs off-actor.

- [ ] **Step 1: Write the failing test.** Add to `ActorHygieneTests.swift`. Inject a blocking `DiffProvider` (deterministic, no real slow git). `recomputeDiffStat` currently hardcodes `GitDiffProvider()` (`+Diff.swift:42`); `protocol DiffProvider: Sendable` already exists (`Diff/DiffProvider.swift`) and `GitDiffProvider` conforms. Add a minimal seam: a stored `var diffProvider: any DiffProvider = GitDiffProvider()` on the actor (default unchanged), used at `:18` and `:42`, plus a `@testable`-only `_setDiffProviderForTest`. The blocking stub (`@unchecked Sendable`, holds the `Gate`) sets `entered` then parks:

```swift
func test_actorNotBlockedByDiff() async throws {
  let (service, cardId, _) = try await ActorHygieneSupport.liveCardWorktree()
  let gate = ActorHygieneSupport.Gate()
  await service._setDiffProviderForTest(BlockingDiffProvider(gate: gate))
  let slow = Task { _ = await service.recomputeDiffStat(cardId) }
  gate.waitUntilEntered()                              // provider is now parked inside the hop
  let start = Date()
  _ = await service.list()
  XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "list() blocked behind on-actor diff")
  gate.open(); _ = await slow.value
}
```

`BlockingDiffProvider.stat/render` call `gate.markEntered()` then `gate.blockUntilOpen()`.

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByDiff`
Expected: FAIL — `list()` blocks until `gate.open()` (latency ≥ 2.0).

- [ ] **Step 3: Wrap the git renders in `offActor`, keeping `assertAllowed` ON-actor.** The allowlist check is a **security gate** — it must run on-actor before the hop, not inside it.

`diffText` (`+Diff.swift:14-19`):
```swift
guard t.origin == .worktree else { return "" }
try resolver.assertAllowed(t.cwd)                       // SECURITY GATE — stays on-actor
let provider = diffProvider, ref = resolvedParentRef(t), cwd = t.cwd
let text = (try? await offActor { try provider.render(worktree: cwd, base: base, parentBranch: ref) }) ?? ""
```
`recomputeDiffStat` (`+Diff.swift:39-45`) — keep `try resolver.assertAllowed(t.cwd)` (`:41`) on-actor inside the `do`, then hop only the git:
```swift
try resolver.assertAllowed(t.cwd)                       // stays on-actor
let provider = diffProvider
newStat = try await offActor { try provider.stat(worktree: t.cwd, base: effective, parentBranch: ref) }
```
(keep the surrounding `do/catch { newStat = nil }`.) `changedNotes` (`+Notes.swift:12-16`) — keep `assertAllowed` (`:15`) on-actor:
```swift
try resolver.assertAllowed(t.cwd)                       // stays on-actor
let l = launcher, ref = resolvedParentRef(t), cwd = t.cwd
return try await offActor { l.changedNoteFiles(worktree: cwd, parentRef: ref) }
```
(`resolvedParentRef` becomes `nonisolated` in Task 5.1.4; until then it runs on-actor before the hop — its first-call `git remote` cost per repo is the residual noted in Global Constraints.)

- [ ] **Step 4: Run test to verify it passes.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByDiff`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OrchestraCore/OrchestraService+Diff.swift Sources/OrchestraCore/OrchestraService+Notes.swift Sources/OrchestraCore/OrchestraService.swift Tests/IntegrationTests/ActorHygieneTests.swift
git commit -m "perf(actor): run diff/notes git off the service actor (injectable DiffProvider seam)"
```

### Task 5.1.3: `pollTelemetry` rollout enumeration off-actor

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:293-317` (`pollTelemetry`)
- Modify: `Tests/IntegrationTests/ActorHygieneTests.swift`

**Interfaces:**
- Consumes: `offActor`; `adapter` (`Adapter: Sendable`), `AdapterContext` (`Sendable`).
- Produces: identical telemetry behavior; the rollout-file enumeration + `fileExists` run off-actor.

The blocking work is `adapter.sessionInfo(ctx, …)` (`:308`, which for Codex enumerates `CodexAdapter.rolloutFiles():295`) + `FileManager.default.fileExists` (`:310`). `tailer.newLines` (`:311`) is already an `await`ed actor call. Move the `sessionInfo` + `fileExists` into one hop per card.

- [ ] **Step 1: Write the failing test.** Add `test_actorNotBlockedByPollTelemetry`. Use a stub adapter whose `sessionInfo` blocks on a gate (register it in the `AgentRegistry` for the card's `agentId`, capability `telemetry == .fileTail`). Start `Task { await service.pollTelemetry() }`, then assert a concurrent `list()` returns < 1.0s while the adapter blocks; open the gate; drain.

```swift
func test_actorNotBlockedByPollTelemetry() async throws {
  let gate = ActorHygieneSupport.Gate()
  let (service, _) = try await ActorHygieneSupport.liveCard(adapter: BlockingTelemetryAdapter(gate: gate))
  let slow = Task { await service.pollTelemetry() }
  gate.waitUntilEntered()                              // adapter.sessionInfo is now parked inside the hop
  let start = Date()
  _ = await service.list()
  XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
  gate.open(); await slow.value
}
```
(`BlockingTelemetryAdapter.sessionInfo` calls `gate.markEntered()` then `gate.blockUntilOpen()`; capability `telemetry == .fileTail`.)

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByPollTelemetry`
Expected: FAIL — `list()` blocks behind the on-actor `sessionInfo`.

- [ ] **Step 3: Move the per-card rollout resolution off-actor.** In the `pollTelemetry` loop (`:308-310`) capture `Sendable` inputs and hop:

```swift
let a = adapter
let resolved: (path: String, exists: Bool)? = try? await offActor {
    guard let info = a.sessionInfo(ctx, current: t.agentSessionId, prior: t.priorSessionIds),
          let p = info.transcriptPath else { return nil }
    return (p, FileManager.default.fileExists(atPath: p))
}
guard let resolved, resolved.exists else { continue }
for line in await tailer.newLines(cardId: t.id, path: resolved.path) { … }   // unchanged
```

`ctx`, `t.agentSessionId`, `t.priorSessionIds` are `Sendable`; `a` (the adapter) is `Sendable`.

- [ ] **Step 4: Run test to verify it passes.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByPollTelemetry`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/IntegrationTests/ActorHygieneTests.swift
git commit -m "perf(actor): resolve pollTelemetry rollout paths off the service actor"
```

### Task 5.1.4: `recomputeTreeStat` compute off-actor + `nonisolated` git leaves + `gitRemotes` cache

**Files:**
- Create: `Sources/OrchestraCore/GitRemotesCache.swift`
- Modify: `Sources/OrchestraCore/OrchestraService+ParentRef.swift` (`gitRemotes` cache; `nonisolated` on `gitRemotes`/`resolvableRef`/`resolvedParentRef`)
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`nonisolated` on `computeTreeStat`/`treeTip`/`treeBehind`/`treeBehindStrict`/`treeBaseIsAncestor`/`defaultBranch`; `offActor` the compute in `recomputeTreeStat:369`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `gitRemotesCache` stored prop)
- Modify: `Tests/IntegrationTests/ActorHygieneTests.swift`

**Interfaces:**
- Produces: `final class GitRemotesCache: @unchecked Sendable { func remotes(repo: String, configMtime: Date?, compute: () -> [String]) -> [String] }` — `NSLock`-guarded `[String: (mtime: Date?, value: [String])]`; recomputes when the repo's `.git/config` mtime changed.
- Produces: `nonisolated func computeTreeStat(repo: String, link: ParentLink, timeout: Duration, probe: (@Sendable () -> Void)?) -> TreeStat` — probe + timeout are **arguments**, so the function reads no actor state.
- Consumes: `offActor`.

`computeTreeStat` + the git leaves touch no actor mutable state (both reviewers confirmed), so marking them `nonisolated` is safe and lets the whole compute run in one hop. Two corrections from review: (a) the probe is a **call-scoped parameter**, not an actor-stored hook (a stored hook read inside `nonisolated computeTreeStat` would be an actor-state read + data race); (b) the leaves gain an explicit `timeout` (currently unbounded — see Global Constraints); (c) the `gitRemotes` memo is keyed by `.git/config` mtime so a mid-run remote change is observed (truly no-behavior-change).

- [ ] **Step 1: Write the failing test.** Add `test_actorNotBlockedByTreeStatRecompute`. Inject a blocking probe via a **`Sendable`-locked holder** the actor reads on-actor and passes into the hop:

```swift
func test_actorNotBlockedByTreeStatRecompute() async throws {
  let gate = ActorHygieneSupport.Gate()
  let (service, cardId) = try await ActorHygieneSupport.liveCardWorktreeWithParent()
  await service._setTreeProbeForTest { gate.markEntered(); gate.blockUntilOpen() }
  let slow = Task { await service.recomputeTreeStat(cardId) }
  gate.waitUntilEntered()                              // compute is now parked inside the offActor hop
  let start = Date()
  _ = await service.list()
  XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
  gate.open(); await slow.value
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByTreeStatRecompute`
Expected: FAIL — `computeTreeStat` runs on-actor; `list()` blocks on `gate`.

- [ ] **Step 3: Implement.**

`GitRemotesCache.swift`:
```swift
import Foundation
/// Per-repo memo of `git remote` output, keyed by the repo's `.git/config` mtime so a mid-run
/// `git remote add/remove` invalidates it (no-behavior-change). Callable from `nonisolated` git-probe
/// code, so it owns its own lock rather than relying on actor isolation.
final class GitRemotesCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cache: [String: (mtime: Date?, value: [String])] = [:]
  func remotes(repo: String, configMtime: Date?, compute: () -> [String]) -> [String] {
    lock.lock()
    if let hit = cache[repo], hit.mtime == configMtime { lock.unlock(); return hit.value }
    lock.unlock()
    let v = compute()
    lock.lock(); cache[repo] = (configMtime, v); lock.unlock()
    return v
  }
}
```
Add `let gitRemotesCache = GitRemotesCache()` to `OrchestraService` stored props, plus a `Sendable`-locked test probe holder + `_setTreeProbeForTest(_:)` (a `final class` with an `NSLock`-guarded `(@Sendable () -> Void)?`, read on-actor). Rewrite `gitRemotes` (`+ParentRef.swift:13`) `nonisolated` + mtime-keyed:
```swift
nonisolated func gitRemotes(repo: String) -> [String] {
  return gitRemotesCache.remotes(repo: repo, configMtime: gitConfigMtime(repo: repo)) {
    guard let r = try? Proc.run(["git", "-C", repo, "remote"]), r.ok else { return [] }
    return r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
```
where `gitConfigMtime(repo:)` is a `nonisolated` helper that resolves the **real** config path so the memo invalidates even for a linked worktree (whose `.git` is a *file*, not a dir):
```swift
nonisolated func gitConfigMtime(repo: String) -> Date? {
  let dotGit = "\(repo)/.git"
  var isDir: ObjCBool = false
  guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
  let configPath: String
  if isDir.boolValue {
    configPath = "\(dotGit)/config"                                   // normal repo
  } else if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),  // worktree: `gitdir: <path>`
            let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
    let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    // the worktree's remotes live in the COMMON dir's config (…/.git, parent of worktrees/<name>)
    let commonDir = URL(fileURLWithPath: gitdir).deletingLastPathComponent().deletingLastPathComponent()
    configPath = commonDir.appendingPathComponent("config").path
  } else { return nil }
  return (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
}
```
(In the real call graph `task.repo == realRepo` — the **main** repo (verified: `spawn` sets `repo: realRepo`, `OrchestraService.swift:428`) — so `.git` is a dir and this is the simple path; the file branch is defense-in-depth so the "no behavior change" claim holds unconditionally. A `nil` mtime still memoizes but can't invalidate — acceptable only because it's unreachable for real callers.) Add `test_gitRemotesInvalidatesOnConfigChange` (main repo) and `test_gitRemotesInvalidatesInLinkedWorktree` (a linked worktree: change the common-dir config, assert `gitRemotes` re-reads). Mark `resolvableRef`, `resolvedParentRef` (`+ParentRef.swift:21,:27`) `nonisolated`. Give the git leaves an explicit `timeout: Duration`: `treeTip` (`:508`), `treeBehind` (`:516`), `treeBehindStrict` (`:523`), `treeBaseIsAncestor` (`:531`), `mergeBaseOID` (`:539`), `revParseOID` (`:129`) each gain `timeout: Duration` and pass it to `Proc.run(…, timeout: timeout)`; mark them `nonisolated`. `computeTreeStat` (`:466`) gains `timeout: Duration, probe: (@Sendable () -> Void)? = nil`, calls `probe?()` first, threads `timeout` into each leaf, and is `nonisolated`. `defaultBranch` (`:495`) `nonisolated` + `timeout`. In `recomputeTreeStat` (`:369`) capture the timeout + probe on-actor, then hop:
```swift
let to = Duration.seconds(config.controlTimeout)
let probe = treeProbeHolder.get()                       // Sendable-locked; nil in prod
let new: TreeStat? = try? await offActor { link.map { computeTreeStat(repo: t.repo, link: $0, timeout: to, probe: probe) } } ?? nil
```
(`new` is `TreeStat?` after the `try?…?? nil` flatten — matches `:369`'s original `link.map { … }` result type.) Verb callers of these leaves (`setParent`/`synced`/`shipped`, on-actor) pass `Duration.seconds(config.controlTimeout)` too — their off-actor hop lands in Task 5.1.6. **Purity fold-back:** now that `resolvedParentRef` is `nonisolated`, move it **inside** the `offActor` hops in `diffText`/`recomputeDiffStat`/`changedNotes` (from Task 5.1.2, where it ran on-actor before the hop) so the residual on-actor `.git/config` stat + first-call `git remote` also move off-actor — full purity. (`assertAllowed` still stays on-actor.)

- [ ] **Step 4: Run test to verify it passes.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByTreeStatRecompute`
Expected: PASS. Then run the tree/remote/parent suites specifically (the single biggest no-behavior-change exposure): `swift test --filter OrchestraCoreTests` → green.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OrchestraCore/GitRemotesCache.swift Sources/OrchestraCore/OrchestraService+ParentRef.swift Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraCore/OrchestraService.swift Tests/IntegrationTests/ActorHygieneTests.swift
git commit -m "perf(actor): treeStat compute off-actor (bounded); nonisolated git leaves; mtime-keyed gitRemotes cache"
```

### Task 5.1.5: Lock the liveness-list off-actor invariant

**Files:**
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (add `listSleepMs` to `StubSessions`)
- Modify: `Tests/IntegrationTests/ActorHygieneTests.swift`

`reconcile()`'s `sessions.list()` is **already** off-actor (`+Reconcile.swift:48`), so the reconcile test locks an invariant. But the **test-retained legacy `reconcileLiveness()`** (`+Recovery.swift:166`) still calls `sessions.list()` **on-actor** (`:168`) — the stage plan names it as a §9 site and tests still drive it (SpawnPhase/Recovery/WakeMergeWatch). Wrap its list off-actor too.

- [ ] **Step 1: Add the `listSleepMs` seam.** In `StubSessions` (`Stubs.swift:185`):
```swift
var listSleepMs: UInt32 = 0
private(set) var listCount = 0
func list() throws -> [SessionInfo] {
  lock.lock(); listCount += 1; let ms = listSleepMs; let out = alive.map { SessionInfo(name: $0, running: true) }; lock.unlock()
  if ms > 0 { usleep(ms * 1000) }
  return out
}
```

- [ ] **Step 2: Write the test.** `test_actorNotBlockedByLivenessList`: build a service with the stub; `stub.listSleepMs = 4000`; `Task { await service.reconcile() }`; assert a concurrent `list()` RPC returns < 2.0s. (Order is safe here: `reconcile()`'s first `await` is the off-actor list, so a fast `list()` RPC that returns while the stub sleeps proves the reconcile list did not hold the actor.)

- [ ] **Step 3: Run — reconcile path.**

Run: `swift test --filter ActorHygieneTests/test_actorNotBlockedByLivenessList`
Expected: PASS (already off-actor). If it FAILS, a regression exists — wrap the reconcile list in `offActor`.

- [ ] **Step 4: Wrap `reconcileLiveness()`'s list.** `+Recovery.swift:168`:
```swift
let s = sessions
let aliveNames = Set((try? await offActor { try? s.list() })??.map(\.name) ?? [])
```
(mirrors `reconcile()`'s hop exactly.) Add `test_reconcileLivenessNotBlockedByList` (same shape, driving `reconcileLiveness()`) so this legacy path is covered too.

- [ ] **Step 5: Run + full green.**

Run: `swift test --filter ActorHygieneTests` then `swift test --no-parallel`
Expected: green (the SpawnPhase/Recovery/WakeMergeWatch tests that drive `reconcileLiveness()` still pass — the hop is semantics-preserving).

- [ ] **Step 6: Commit.**

```bash
git add Tests/OrchestraCoreTests/Stubs.swift Tests/IntegrationTests/ActorHygieneTests.swift Sources/OrchestraCore/OrchestraService+Recovery.swift
git commit -m "perf(actor): reconcileLiveness list off-actor; lock the reconcile-list invariant"
```

### Task 5.1.6: Cleanup sweep — remaining listed + reviewer-found sites off-actor

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`status:660-663`, `sweepOrphanScratch:473-500`, `emitShells:723-729`, `spawnRepos:963-`, `spawnBranches:983-`)
- Modify: `Sources/OrchestraCore/OrchestraService+Converge.swift` (`prepareToLaunch` at `:144`, `:156`; `.resume` `sessionInfo`/`fileExists` at `:151`)
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`isResumable:223-231` — `adapter.sessionInfo` + `fileExists`)
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (verb-path git in `setParent`/`synced`/`shipped`)
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift` (`privateRefOID:224`, `localBranchOID:230`, `isAncestor:236`)

These are §9-listed **plus the four on-actor blockers both reviewers surfaced** (`spawnBranches`'s `for-each-ref` can freeze the actor up to 5s on a routine Spawn-sheet open; `spawnRepos`/`emitShells`/`isResumable`). Extending past the orchestrator's literal list is deliberate — it is the honest way to satisfy the Stage-5 deliverable "no subprocess/file IO on the service actor" (still pillar P5, not PR6a's wire surface). Not individually gate-tested (no test names in the stage); the gate is **`swift test --no-parallel` green** + per-site review. Keep each diff mechanical.

- [ ] **Step 1: `status` off-actor.** `+660`:
```swift
let name = sessions.sessionName(id), s = sessions
let running = (try? await offActor { try s.isAlive(name) }) ?? false
```

- [ ] **Step 2: `sweepOrphanScratch` off-actor.** Move `sessions.list()` (`:488`) and the FS enumeration/`removeItem` loop (`:476`, `:498`) into `offActor` hops. Keep the `store.all()` guard (`:480-481`) on-actor. One hop reads the dir + computes the delete-set (preserving grace-window + live-session/live-dir skips) and removes — semantics identical.

- [ ] **Step 3: `prepareToLaunch` off-actor** in `finishLaunch` (`+Converge.swift:144`, `:156`) — the only on-actor blocker there (`kill`/`ensure` already hop at `:161`). `adapter` + `ctx` are `Sendable`:
```swift
let a = adapter, c = ctx
try? await offActor { try? a.prepareToLaunch(c) }
```
For the `.resume` path (`:150-155`), move `adapter.sessionInfo` + `FileManager.fileExists` into a hop before the `.timedOut` decision (5.1.3 pattern).

- [ ] **Step 4: `emitShells` / `spawnRepos` / `spawnBranches` / `isResumable` off-actor.**
  - `emitShells` (`:723`): all three callers — `openShell` (`:705`), `inspect` (`:734`), `closeShell` (`:758`) — are **already `async`**, so hopping is ripple-free. Make `emitShells` `async` and hop its `sessions.windows(name)` (`:725`): `let s = sessions; guard let targets = try? await offActor { try s.windows(name) } else { return }`. **Do BOTH** here: hop the subprocess off-actor **and** evict the 5.2 snapshot cache (`observedSessions[t.id] = nil`) — they are orthogonal (the hop satisfies "no on-actor subprocess"; the evict keeps the snapshot fresh). Cache-evict alone does **not** move the subprocess off the actor, so it is not a substitute for the hop.
  - `spawnRepos` (`:963`): wrap `FileManager.contentsOfDirectory` in `offActor` (make the method `async`; update its call sites — a client-facing query, low-frequency).
  - `spawnBranches` (`:983`): wrap the `for-each-ref` `Proc.run` (already `timeout: .seconds(5)`) in `offActor` (make `async`; update call sites). **This removes the 5s actor freeze** — the single most valuable site in this task.
  - `isResumable` (`+Recovery.swift:223`): move `adapter.sessionInfo` + `fileExists` into a hop. It is called from `reconcilePhasesAtBoot`/relaunch (already `async`), so make `isResumable` `async` and `await` it there.

- [ ] **Step 5: verb-path + remote git off-actor.** In `setParent`/`synced`/`shipped` (`+Tree.swift`) and `remoteMergeStep`/`applyRemoteRedirect` (`+Remote.swift`), the git leaves are `nonisolated` (Task 5.1.4) or become so here (`privateRefOID`, `localBranchOID`, `isAncestor` — mark `nonisolated`, add `timeout: Duration`). Wrap their invocations at the verb call sites in `offActor`, batching a verb's sequential git calls into one hop (same order, same throws). Pass `Duration.seconds(config.controlTimeout)` captured on-actor.

- [ ] **Step 6: Run the full suite.**

Run: `swift test --no-parallel`
Expected: green. Re-run any real-tmux/UDS failure in isolation to confirm it is the known environmental flake.

- [ ] **Step 7: Commit.**

```bash
git add -A
git commit -m "perf(actor): sweep status/sweepScratch/prepareToLaunch/spawnBranches/spawnRepos/emitShells/isResumable/verb-git off-actor"
```

---

## Stage 5.2 — `boardSnapshot` from the reconciler's observed cache

**Deliverable:** for a **reconciled** card, `boardSnapshot` performs **zero tmux subprocess calls** — per-card `targets`/`running` come from an in-memory `observedSessions` cache the reconcile tick maintains (off-actor, session-alive cards only). **Trade, not free lunch (reviewer-corrected):** cost shifts from on-connect to every-tick (off-actor); per-card session state is up to one tick (~2s) **stale** but self-heals via live `shellsChanged`/reconcile events. **No mis-show:** a cache **miss** or an entry **older than the card's `phaseChangedAt`** (session changed since capture) falls back to a single live `sessions(card.id)`; the cache is **evicted** on teardown and on shell open/close/inspect so user-driven changes are never hidden.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `observedSessions` stored prop; `boardSnapshot:779-800` reads cache; evict in `openShell`/`closeShell`/`inspect`)
- Modify: `Sources/OrchestraCore/OrchestraService+Reconcile.swift` (populate cache each tick, off-actor, **non-archived + alive only**)
- Modify: `Sources/OrchestraCore/OrchestraService+Converge.swift` (`teardownActorDuties` evicts)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (add `windowsCount`/`windowsSleepMs` recorder to `StubSessions`)
- Create: `Tests/OrchestraCoreTests/BoardSnapshotTests.swift`

**Interfaces:**
- Produces: `struct ObservedSession: Sendable, Equatable { let targets: [TmuxTarget]; let running: Bool; let observedAt: Date }`; `var observedSessions: [UUID: ObservedSession] = [:]`.

- [ ] **Step 1: Add the `windowsCount` recorder.** In `StubSessions.windows` (`Stubs.swift:174`) increment a `private(set) var windowsCount` under the lock; add `var windowsSleepMs: UInt32 = 0` honored like `isAliveSleepMs`.

- [ ] **Step 2: Write the failing tests** (`BoardSnapshotTests.swift`). Four tests — the headline plus the reviewer-required coverage:

```swift
// (a) hit path shells zero tmux calls
func test_boardSnapshotDoesNotShell() async throws {
  let (service, stub) = try await BoardSnapshotSupport.serviceWithLiveCards(count: 3)
  await service.reconcile()                          // populates observedSessions off-actor
  let before = stub.windowsCount
  _ = await service.boardSnapshot()
  XCTAssertEqual(stub.windowsCount, before, "boardSnapshot shelled instead of reading cache")
}
// (b) content correctness — cache reflects the real windows
func test_boardSnapshotContentMatchesObservedWindows() async throws {
  let (service, stub, cardId) = try await BoardSnapshotSupport.liveCardWithShell()  // agent + one shell
  await service.reconcile()
  let snap = await service.boardSnapshot()
  let cs = snap.sessions.first { $0.id == cardId }!
  XCTAssertTrue(cs.running)
  XCTAssertEqual(Set(cs.targets.map(\.window)), Set(try stub.windowsForTest(cardId).map(\.window)))
}
// (c) cache miss → exactly one live shell, correct state (first-connect preserved)
func test_boardSnapshotCacheMissFallsBackToLiveShell() async throws {
  let (service, stub, _) = try await BoardSnapshotSupport.liveCardWithShell()  // NO reconcile yet
  let before = stub.windowsCount
  let snap = await service.boardSnapshot()
  XCTAssertEqual(stub.windowsCount, before + 1, "miss should live-shell exactly once")
  XCTAssertTrue(snap.sessions.first!.running)
}
// (d) shell open evicts → next snapshot reflects the new shell, not a stale cache
func test_boardSnapshotFreshAfterShellOpen() async throws {
  let (service, _, cardId) = try await BoardSnapshotSupport.liveCardWithShell()
  await service.reconcile()
  _ = try await service.openShell(cardId)             // evicts the entry
  let snap = await service.boardSnapshot()            // miss → live shell → sees the new window
  XCTAssertTrue(snap.sessions.first!.targets.contains { $0.window.hasPrefix("shell-") })
}
```

- [ ] **Step 3: Run to verify (a) fails.**

Run: `swift test --filter BoardSnapshotTests/test_boardSnapshotDoesNotShell`
Expected: FAIL — `boardSnapshot` calls `sessions(card.id)` → `windows()` per card (count jumps by 3).

- [ ] **Step 4: Implement.**

Add stored props to `OrchestraService`:
```swift
struct ObservedSession: Sendable, Equatable { let targets: [TmuxTarget]; let running: Bool; let observedAt: Date }
var observedSessions: [UUID: ObservedSession] = [:]
```
In `reconcile()` (after `aliveNames` at `+Reconcile.swift:48`), gather windows off-actor for **non-archived, alive** cards only (dead → empty without shelling; bounds idle-daemon cost to live-card count):
```swift
let now = Date()  // already present in reconcile()
let toObserve = tasks.filter { !$0.archived && aliveNames.contains(sessions.sessionName($0.id)) }
                     .map { ($0.id, sessions.sessionName($0.id)) }
let deadIds = tasks.filter { !$0.archived && !aliveNames.contains(sessions.sessionName($0.id)) }.map(\.id)
let s = sessions
let observedAlive: [UUID: [TmuxTarget]] = (try? await offActor {
  var out: [UUID: [TmuxTarget]] = [:]
  for (id, name) in toObserve { out[id] = (try? s.windows(name)) ?? [] }
  return out
}) ?? [:]
for (id, ts) in observedAlive { observedSessions[id] = ObservedSession(targets: ts, running: !ts.isEmpty, observedAt: now) }
for id in deadIds { observedSessions[id] = ObservedSession(targets: [], running: false, observedAt: now) }
```
Refactor `boardSnapshot`'s per-card loop (`:793-796`) to read the cache, live-shelling on **miss OR staleness vs `phaseChangedAt`**:
```swift
for card in active {
  if let obs = observedSessions[card.id], obs.observedAt >= card.phaseChangedAt {   // fresh vs the current session
    // agent info is fs (non-tmux); hop it off-actor. A nil sessionInfo (common early-life, before the
    // session id binds) MUST serve the same fallback AgentSessionInfo `sessions()` builds (:810-812) —
    // else the hit-branch is skipped and we live-shell an early-life card every snapshot (defeating the cache).
    let ctx = AdapterContext(cwd: card.cwd, model: card.model.id, sessionId: card.agentSessionId,
                             name: card.title, orchestraBin: orchestraBin)
    let a = try? registry.get(card.agentId)
    let agent = (try? await offActor { a?.sessionInfo(ctx, current: card.agentSessionId, prior: card.priorSessionIds) }) ?? nil
      ?? AgentSessionInfo(agentId: card.agentId, sessionId: card.agentSessionId, transcriptPath: nil,
                          priorSessionIds: card.priorSessionIds, priorTranscripts: [], resumeCmd: nil)
    sessionsList.append(CardSessions(ref: card.ref(), id: card.id, worktree: card.cwd,
      tmuxSocket: Config.tmuxSocket, session: sessions.sessionName(card.id),
      running: obs.running, targets: obs.targets, agent: agent))
  } else if let cs = try? await sessions(card.id) {                                // miss/stale → one live shell
    sessionsList.append(cs)
  }
  owners.append(terminalOwnership.snapshot(cardId: card.id, ref: card.ref(), now: now))
}
```
(The `agent` fs read hops off-actor like 5.1.3 so the snapshot stays fully off the tmux path; the `?? AgentSessionInfo(…)` fallback keeps a nil-`sessionInfo` card on the cache-hit branch — mirroring `sessions()`'s `:810-812` — so early-life cards don't shell every snapshot. `test_boardSnapshotDoesNotShell`'s helper must include a card **without** a resolvable `sessionInfo` so this path is actually exercised, not masked.) **Evict** in `teardownActorDuties` (`+Converge.swift:177`: `observedSessions[id] = nil`) and at the end of `openShell`/`closeShell`/`inspect` (`observedSessions[t.id] = nil` — next snapshot live-shells fresh, next tick repopulates).

- [ ] **Step 5: Run all four to verify they pass.**

Run: `swift test --filter BoardSnapshotTests`
Expected: PASS — (a) zero tmux on hit; (b) content matches; (c) miss shells exactly once; (d) shell-open freshness.

- [ ] **Step 6: Full suite green.**

Run: `swift test --no-parallel`
Expected: green (snapshot content identical for reconciled cards; `sessions(_:)` RPC untouched).

- [ ] **Step 7: Commit.**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Reconcile.swift Sources/OrchestraCore/OrchestraService+Converge.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/BoardSnapshotTests.swift
git commit -m "perf(actor): serve boardSnapshot session state from the reconciler's observed cache (evict on teardown/shell-op; stale→live fallback)"
```

---

## Stage 5.3 — Telemetry-persist debounce

**Deliverable:** N rapid telemetry-origin mutations coalesce into ≤1 `tasks.json` write. **`rev` + memory + the emit stay synchronous per mutation** (the wire/event stream is byte-identical — reviewers' key concern), only the **file write** is debounced. Whole-file atomic rewrite stays.

**Rev-durability handling (Review B1 — the core resolution):** deferring the file write means the on-disk `rev` can lag in-memory `rev`, so a **hard crash** may reload a lower `rev`. Bounded three ways: (1) **any immediate (non-telemetry) mutation force-flushes** pending telemetry (so `rev` only regresses over a *pure-telemetry burst since the last real mutation* — reconstructable from transcripts, bug-#13's accepted loss); (2) a **max-deferral cap** flushes an always-active card at least every `maxDeferral` (default 2s); (3) a **SIGTERM flush** in `orchestrad/main.swift` makes clean restarts (launchd's SIGTERM-before-SIGKILL) lossless. Correctness across a hard crash relies on the **reconnect-cursor-reset** contract — an **explicit new requirement PR5 hands PR6a** (adopt `boardSnapshot.rev` as ground truth on reconnect even if lower; see Global Constraints), **not** something already required by Stage 6. Write failures are **logged + keep the dirty bit** (a later mutation retries), never silently dropped.

**Files:**
- Modify: `Sources/OrchestraCore/TaskStore.swift`
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift:153` (opt the field-delta write into debounced flush)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`flushBeforeShutdown()` forwarding to the store)
- Modify: `Sources/orchestrad/main.swift` (SIGTERM → flush → exit)
- Modify: `Tests/OrchestraCoreTests/TaskStoreTests.swift`

**Interfaces:**
- Produces: `TaskStore.update(_ id:, debounceFlush: Bool = false, _ mutate:)`; `TaskStore.flushPendingWrites()`; `OrchestraService.flushBeforeShutdown() async`; test seams `var diskWriteCount: Int`, `func setPersistDebounce(_ interval: Duration)`, `func setMaxDeferral(_ interval: Duration)`.

- [ ] **Step 1: Write the failing tests.** `TaskStoreTests`:

```swift
func test_telemetryPersistDebounced() async throws {
  let store = TaskStore(path: tmpPath())
  _ = try await store.create(Task(id: id, ...))     // one immediate write
  await store.setPersistDebounce(.seconds(10)); await store.setMaxDeferral(.seconds(30))
  let base = await store.diskWriteCount
  var lastRev = await store.currentRev
  for pct in 1...20 {                               // 20 rapid telemetry deltas
    let (_, rev) = try await store.update(id, debounceFlush: true) { $0.ctxPct = pct }
    XCTAssertGreaterThan(rev, lastRev); lastRev = rev            // rev advances synchronously per real change
  }
  XCTAssertEqual(await store.diskWriteCount, base, "debounced telemetry wrote immediately")
  XCTAssertEqual(await store.get(id)?.ctxPct, 20)               // memory current despite deferred write
  await store.flushPendingWrites()
  XCTAssertEqual(await store.diskWriteCount, base + 1, "burst did not coalesce to one write")
}
func test_immediateMutationFlushesPendingTelemetry() async throws {
  // a debounced telemetry delta followed by a real move() writes ONCE (the move flushes the pending delta)
  … update(debounceFlush:true){ctxPct=5}; let c0 = diskWriteCount; try await store.move(id, to: .impl)
  XCTAssertEqual(diskWriteCount, c0 + 1); // reload sees ctxPct=5 AND the move
}
func test_reloadBeforeFlushSeesLastFlushedRev() async throws {
  // debounce a delta (no flush), reload a fresh TaskStore from the same path → rev == last flushed, not the bumped one
}
func test_reloadAfterFlushSeesCurrentRev() async throws {
  // debounce a delta, flushPendingWrites(), reload a fresh TaskStore → rev == the bumped rev AND the delta is on disk
}
func test_noOpUpdateDoesNotAdvanceRev() async throws {
  // update(debounceFlush:true) that changes nothing returns the same rev, schedules no flush
}
func test_flushBeforeShutdownPersists() async throws {
  // OrchestraService.flushBeforeShutdown() forwards to store.flushPendingWrites(): a debounced telemetry
  // delta is on disk (reload sees it) after the call — proves the SIGTERM path checkpoints cleanly.
}
```

- [ ] **Step 2: Run to verify they fail.**

Run: `swift test --filter TaskStoreTests/test_telemetryPersistDebounced`
Expected: FAIL — no `debounceFlush`/`diskWriteCount`/`flushPendingWrites`/`setMaxDeferral`; every `update` writes.

- [ ] **Step 3: Implement.** In `TaskStore`:
  - Factor the file write out of `persist()` into `private func writeToDisk() throws` (the `createDirectory`+encode+atomic-replace body, `:131-141`), incrementing `diskWriteCount` there.
  - `persist()` becomes: `currentRev += 1; cancelPendingFlush(); try writeToDisk()` (immediate mutations flush now **and** absorb pending telemetry — memory already holds the deltas).
  - Add `private var persistDebounce: _Concurrency.Task<Void, Never>? = nil`, `private var pendingDirty = false`, `private var debounceInterval: Duration = .milliseconds(500)`, `private var maxDeferral: Duration = .seconds(2)`, `private var firstDeferredAt: ContinuousClock.Instant? = nil`.
  - `private func persistDebounced()`: `currentRev += 1; pendingDirty = true`; if `firstDeferredAt == nil { firstDeferredAt = .now }`; if `now - firstDeferredAt >= maxDeferral` → `flushPendingWrites()` (max-deferral checkpoint) else (re)schedule a `_Concurrency.Task` that sleeps `debounceInterval`, checks `!Task.isCancelled`, then `flushPendingWrites()`.
  - `func flushPendingWrites()`: cancel timer; `firstDeferredAt = nil`; `guard pendingDirty else { return }`; `pendingDirty = false`; `do { try writeToDisk() } catch { pendingDirty = true; log the failure }` — **failures re-arm the dirty bit** (a later mutation retries), not silent.
  - `private func cancelPendingFlush()`: cancel timer; `pendingDirty = false; firstDeferredAt = nil` (an immediate persist supersedes — memory already includes the pending deltas).
  - Extend `update` with `debounceFlush: Bool = false`: same body as `:178-189` incl. the `guard tasks[idx] != before` no-op gate (so a no-op neither bumps rev nor schedules a flush); the terminal `try persist()` (`:187`) becomes `if debounceFlush { persistDebounced() } else { try persist() }`.
  - Test seams: `var diskWriteCount = 0`; `func setPersistDebounce(_ d: Duration) { debounceInterval = d }`; `func setMaxDeferral(_ d: Duration) { maxDeferral = d }`.
  
  In `report()` (`+Report.swift:153`) opt the field-delta telemetry write into debounce (the `transition()` phase write at `:162` stays immediate):
```swift
let (saved, rev) = try await store.update(id, debounceFlush: true) { $0.applyReportFields(from: task) }
```
  Add `OrchestraService.flushBeforeShutdown() async { await store.flushPendingWrites() }`. In `Sources/orchestrad/main.swift`, before `dispatchMain()`, install a SIGTERM source that flushes then exits:
```swift
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { _Concurrency.Task { await service.flushBeforeShutdown(); exit(0) } }
sigterm.resume()
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter TaskStoreTests`
Expected: PASS (debounce coalesces; rev synchronous+monotonic; immediate mutation flushes pending; reload-before-flush sees last-flushed rev; no-op doesn't advance).

- [ ] **Step 5: Full suite green.**

Run: `swift test --no-parallel`
Expected: green. Existing report/telemetry tests read `store.get` (fresh memory) so they pass unchanged; any test asserting **on-disk** state right after a `report()` must `flushPendingWrites()` first — fix such tests if any surface (search for tests that re-read `tasks.json`/construct a second `TaskStore` after a report).

- [ ] **Step 6: Commit.**

```bash
git add Sources/OrchestraCore/TaskStore.swift Sources/OrchestraCore/OrchestraService+Report.swift Sources/OrchestraCore/OrchestraService.swift Sources/orchestrad/main.swift Tests/OrchestraCoreTests/TaskStoreTests.swift
git commit -m "perf(store): debounce telemetry disk writes (rev/memory/emit synchronous; force-flush on real mutation + SIGTERM + max-deferral)"
```

---

## Stage 5.4 — Docs

**Files:**
- Modify: `docs/02-architecture.md#the-daemon-orchestrad`
- Modify: `notes/designs/lifecycle-convergence/03-implementation.md` (add PR5 as-built Decisions)

- [ ] **Step 1: Update `docs/02-architecture.md`.** Under "The daemon (orchestrad)", document: (a) **actor hygiene** — the single `OrchestraService` actor offloads all subprocess/file IO via `offActor`, so slow git/tmux/exec never freezes RPC servicing; (b) the **observed-session cache** — the reconcile tick captures each card's tmux window state off-actor so `boardSnapshot` (every client (re)connect) shells zero times; (c) **telemetry-persist debounce** — telemetry deltas update memory + `rev` synchronously but coalesce their `tasks.json` write. Commit `docs(arch): actor hygiene + observed-session cache + telemetry debounce`.

- [ ] **Step 2: Fold PR5 Decisions into the vault.** Append a "Decisions made — PR5 (Stage 5) as-built" table to `03-implementation.md` capturing: injectable `DiffProvider` seam; `nonisolated` git-leaf sweep (now `timeout`-bounded) + `GitRemotesCache` **invalidated on git-config mtime** (so a mid-run `git remote add/remove` IS observed — no behavior change); `observedSessions` cache (bounded ~2s self-healing staleness, live-shell fallback on miss/staleness, evict on teardown+shell-op; cost shifts on-connect→every-tick-off-actor); telemetry debounce keeps rev/memory/emit synchronous, only the file write coalesces (bounded cross-restart `rev` regression → the **explicit new PR6a reconnect-cursor-reset requirement**; clean restarts lossless via SIGTERM flush); the four §9-plus sites (`spawnBranches`/`spawnRepos`/`emitShells`/`isResumable`) hopped beyond the literal list. Commit `docs(vault): PR5 as-built decisions`.

---

## Self-Review checklist (run before Phase E)

1. **Spec coverage:** 5.1 → Tasks 5.1.1–5.1.6 (all §9 sites + reviewer-found: exec✔, diff✔, notes✔, pollTelemetry✔, treeStatRecompute✔, reconcile+reconcileLiveness list✔, status✔, sweepOrphanScratch✔, prepareToLaunch✔, gitRemotes-cache✔, +Tree/+Remote probes✔, **spawnBranches✔, spawnRepos✔, emitShells✔, isResumable✔**); 5.2 → boardSnapshot cache✔; 5.3 → telemetry debounce✔; 5.4 → docs✔. Gate tests: five `_by*` + `test_reconcileLivenessNotBlockedByList` + four `BoardSnapshot*` + four `TaskStore` debounce tests.
2. **No *observable* behavior change:** each moved call is the same call inside `offActor` (same order, same throws, `assertAllowed` kept on-actor); the **wire/event stream is unchanged** (telemetry emits `rev`-stamped synchronously — only the *disk write* coalesces). Bounded micro-effects, each a recorded Decision: (a) `gitRemotes` memo — **invalidated on `.git/config` mtime**, so effectively none; (b) telemetry write coalescing → bounded cross-restart `rev` regression, handled by force-flush + max-deferral + SIGTERM-flush + the reconnect-cursor-reset contract; (c) snapshot session-state up to ~2s stale, self-healing + live-shell fallback on miss/staleness.
3. **Type consistency:** `offActor`, `ObservedSession`/`observedSessions`, `GitRemotesCache.remotes(repo:configMtime:compute:)`, `computeTreeStat(repo:link:timeout:probe:)`, `update(_:debounceFlush:_:)`, `flushPendingWrites()`, `flushBeforeShutdown()`, `diskWriteCount`, `setPersistDebounce`/`setMaxDeferral` used identically across tasks.
4. **Agent-agnostic:** no `if agentId ==`; adapters flow through `Sendable` closures.
5. **Merge-clean with PR6a:** no edits to `SpawnInput`/`ControlClient`/`BoardStore`. **Correction (was overstated):** the TaskStore debounce *does* change disk-`rev` durability (on-disk `rev` can lag in-memory) — a **semantic touch-point with PR6a's rev-gap resync**, resolved by the reconnect-cursor-reset contract (Global Constraints) and surfaced to PR6a in the merge-request. File-surface collisions limited to `OrchestraService.swift` stored-prop declarations + the spawn region if PR6a edits there — coordinate the insertion point; low risk.
6. **Bounded:** every moved `Proc.run` keeps (or gains, for the previously-unbounded `+Tree`/`+ParentRef`/`+Remote` leaves) an explicit `timeout` from `config.controlTimeout`; `offActor` changes only the executor.

## Execution handoff

Per Allen's standing workflow: this plan goes to **dual plan-review** (Opus general-purpose xhigh + a read-only GPT-5.5 codex card in this worktree) until both are clean, then **superpowers:subagent-driven-development** at high effort implements it task-by-task with review between tasks, then **dual implementation-review** on `git diff orch/lifecycle-convergence...HEAD`, then full-suite verification (`swift test --no-parallel`), then `merge-request`.
