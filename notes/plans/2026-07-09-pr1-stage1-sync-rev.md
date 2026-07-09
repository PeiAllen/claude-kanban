# PR1 — Stage 1: Sync `rev` + delta writes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Strict TDD per step (write failing test → run red → implement → run green → commit).

**Goal:** Give the board a monotonic, persisted `rev` that is stamped onto every mutation, every event notification, and the `BoardSnapshot`; and make `report()` write field-deltas so it can no longer clobber a concurrently-mutated field with a stale whole-object snapshot.

**Architecture:** `TaskStore` becomes the sole authority for a monotonic `currentRev`, bumped in its single `persist()` funnel and persisted in a new on-disk `{rev, tasks}` shape (a pre-upgrade bare `[Task]` array reads back as `rev = 0` — the one compat we keep). Events travel to clients wrapped in an `EventEnvelope{rev, event}` so every notification carries the board version at emit; `BoardSnapshot` gains a `rev` field read from the store. `report()` stops doing `store.update(id) { $0 = task }` and instead patches only the fields it owns.

**Tech Stack:** Swift (Swift Concurrency actors), swift-testing (`swift test`), newline-JSON-RPC over UDS.

**Companion vault (read first — this plan implements it):**
- `notes/designs/lifecycle-convergence/` — the approved layered design; PR1 is the top row of `05-pr-tree.md`.
- `notes/designs/2026-07-08-card-lifecycle-convergence.md` — the spec/contract.
- `notes/plans/2026-07-08-card-lifecycle-convergence.md` — the finalized whole-effort plan; **Stage 1** (Tasks 1.1–1.4) is this PR's scope, verbatim.

## Global Constraints (from the whole-effort plan)

- **Agent-agnostic.** No `if agentId == "claude"` in shared code. Stage 1 is agent-neutral, but honor the rule.
- **Break the wire freely; no cross-version interop.** Ship the daemon + all clients together. The **only** compat kept in Stage 1 is the one-time defaulting read of a pre-upgrade `tasks.json` (bare `[Task]` array → `rev = 0`). Do **not** preserve on-disk `rev` behavior for any old client; there are none.
- **Single service actor.** Keep the one `OrchestraService` actor; no new actors in Stage 1.
- **Full suite (~680 tests) green after every task.** Full run: `swift test` from the repo root. Never leave it red.
- **Anchor provenance:** all `file:line` anchors were verified against `main` @ `f1aa568`. If a line has drifted by execution time, search the symbol.
- **Fold deviations back into the vault:** if implementation deviates from a vault doc, update that doc's "Decisions made" table and mention it in the merge-request.

## File structure (this PR)

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraCore/TaskStore.swift` | `currentRev` authority: bump in `persist()`; on-disk `{rev, tasks}` shape; pre-upgrade bare-array read defaults `rev=0`. In 1.2, `create`/`update`/`move` return `(task, rev)` | 1.1, 1.2 |
| `Sources/OrchestraKit/Model.swift` | Add `EventEnvelope{rev, event}`; add `rev: Int` to `BoardSnapshot`; add `Task.applyReportFields(from:)` | 1.2, 1.3 |
| `Sources/OrchestraCore/OrchestraService.swift` | Subscriber stream becomes `AsyncStream<EventEnvelope>`; **synchronous** `emit(_:rev:)` (rev from the mutation return); ephemeral emits stamp the `lastRev` mirror (seeded in `init` via `store.peekPersistedRev()`); `boardSnapshot()` stamps `rev`; `shipped()` emit-only-on-success | 1.2 |
| `Sources/OrchestraCore/PushNotifier.swift:41` | Second `subscribe()` consumer — unwrap `event.event` before `handle(_:Event)` | 1.2 |
| `Sources/OrchestraCore/Control/ControlServer.swift` | Event pump + notification carry the envelope; ring-buffer unwraps `.event`; ring-replay wraps `rev: 0` | 1.2 |
| `Sources/OrchestraKit/Control/ControlClient.swift` | Decode `EventEnvelope`, yield `.event` to the existing `AsyncStream<Event>` (rev consumed in Stage 6) | 1.2 |
| `Sources/OrchestraCore/OrchestraService+Report.swift:133` | Replace `$0 = task` whole-object write with `$0.applyReportFields(from: task)` | 1.3 |
| `docs/02-architecture.md` | Document the `rev` cursor on events/snapshot + report field-delta | 1.4 |
| `Tests/OrchestraCoreTests/TaskStoreTests.swift` (**exists — APPEND**, 6 tests) | `TaskStoreRevTests`: `test_everyMutationBumpsRev`, `test_preUpgradeBareArrayDefaultsRevZero` | 1.1 |
| `Tests/OrchestraCoreTests/ControlServerTests.swift` (**create — absent**) | `test_eventCarriesRev`, `test_boardSnapshotCarriesRev`, `test_activityEventCarriesCurrentRev` | 1.2 |
| `Tests/OrchestraCoreTests/ReportTests.swift` (**exists — APPEND**, 23 tests) | `ReportDeltaTests`: `test_reportDoesNotClobberConcurrentFields` | 1.3 |

---

## Load-bearing design decision — how `rev` binds to events (STRICT binding, revised after plan review round 1)

**Requirement (spec/plan 1.2):** every `event` notification's params carry `rev`, and `BoardSnapshot.rev` equals the store's rev at emit. For Stage-6 gap-detection to be correct, a `.taskUpserted(A)` MUST carry the exact rev the mutation that produced `A` bumped to — never a later rev.

**Chosen mechanism (strict; no reentrancy gap):** the `TaskStore` mutators that feed `.taskUpserted` (`create`/`update`/`move`) **return the rev they produced, atomically** — `-> (task: Task, rev: Int)`. Events are wrapped in `EventEnvelope{rev: Int, event: Event}`. `emit(_ event: Event, rev: Int)` is **synchronous** and takes the rev explicitly, so there is **no `await` between the mutation and the emit** — the rev is bound to exactly the mutation that produced the task, and actor reentrancy cannot skew it. `emit` also refreshes a `lastRev` mirror.

**Ephemeral emits** (`emitActivity`, `emitOwnerIfChanged`, `.shellsChanged`) stay **synchronous** and stamp `lastRev` (the last task-state rev = the current board rev, since ephemeral events never bump rev). `lastRev` is **seeded synchronously in `OrchestraService.init`** via `store.peekPersistedRev()` — *before* `server.start()` accepts any RPC — and refreshed by every `emit`, so it is never a stale `0` on a persisted board (see Task 1.2 for why `init`, not `recoverSessions`).

**Why not `async emit` reading `store.currentRev`?** (Rejected — this was round-1's design.) Because `emit` would `await store.currentRev` *after* the mutation, actor reentrancy could let a concurrent mutation bump rev in the suspension window, stamping `.taskUpserted(A)` with mutation B's rev → Stage-6 apply-if-`rev>lastSeen` would apply stale A at rev B and **drop** the real B event. Strict binding (rev returned by the mutation) closes this.

**Why not stamp at serialization time (in `ControlServer`)?** Same class of bug: a later mutation could bump `store.currentRev` between emit and serialize, mis-stamping a `.taskUpserted`.

**Blast radius (counts verified against the tree @ current HEAD by the R2 Opus review):** 20 `TaskStore` mutator call sites in `Sources` (1 `create` @ `OrchestraService.swift:401`, 18 `update`, 1 `move` @ `:629`). Of these, **18 capture-and-emit** → `let (saved, rev) = try await store.update(...)` + `emit(.taskUpserted(saved), rev: rev)`; **2 discard** (`+MergeRequest.swift:86`, `+Tree.swift:165` — `_ = try? await store.update(...)`) → unchanged (they discard the tuple). There are **18** `emit(.taskUpserted)` sites (not 21), **each** verified to have a fresh mutation producing the emitted task (rev-binding is sound at every one — no site emits a `store.get`/cached/loop value). `create`/`update`/`move` return `(task: Task, rev: Int)`; `remove`/`save` stay as-is (no `.taskRemoved` emit exists). **Test-side captures also break under the tuple change and must be fixed in Task 1.2** (compile errors): `TaskStoreTests.swift:20,23,30,31,48` (`let t = try await store.create(...)` etc.) and this plan's own `test_everyMutationBumpsRev` (`let t = try await store.create(...)`) → append `.task`.

---

## Task 1.1: Board `rev` in `TaskStore`

**Files:**
- Modify: `Sources/OrchestraCore/TaskStore.swift`
- Test: `Tests/OrchestraCoreTests/TaskStoreTests.swift` (**exists — APPEND a new suite; do NOT overwrite the 6 existing tests**)

**Interfaces:**
- Produces: `TaskStore.currentRev: Int` (actor-isolated, `private(set)`, monotonic, persisted); `TaskStore.peekPersistedRev() -> Int` (`nonisolated`, sync — for the `OrchestraService.init` `lastRev` seed in Task 1.2). On-disk payload becomes `{"rev": Int, "tasks": [Task]}`. A pre-upgrade bare `[Task]` array loads with `currentRev = 0`.

- [ ] **Step 1: Write the failing test** — **APPEND** a new `struct` after the existing `TaskStoreTests` in `Tests/OrchestraCoreTests/TaskStoreTests.swift` (the file already imports Foundation/Testing/`@testable import OrchestraCore` and uses `Task`/`Column`/`AgentModel`, so OrchestraCore re-exports OrchestraKit — add `@testable import OrchestraKit` to the file's import block **only if** `OrchestraJSON` fails to resolve). Name `TaskStoreRevTests` (verified: no collision).

```swift
@Suite("TaskStore rev") struct TaskStoreRevTests {
    private func sample(_ title: String = "a", column: Column = .plan) -> Task {
        Task(title: title, repo: "/repos/app", branch: "b", cwd: "/wt/app/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: column, order: 0,
             initialPrompt: title)
    }
    private func tmpPath() -> String { NSTemporaryDirectory() + "orch-rev-\(UUID().uuidString)/tasks.json" }

    @Test("every mutation bumps rev monotonically; no two mutations share a rev")
    func test_everyMutationBumpsRev() async throws {
        let store = TaskStore(path: tmpPath())
        var seen: [Int] = []
        let t = try await store.create(sample())        // NOTE: in Task 1.2 this becomes `store.create(sample()).task`
        seen.append(await store.currentRev)
        _ = try await store.update(t.id) { $0.desc = "b" }
        seen.append(await store.currentRev)
        _ = try await store.move(t.id, to: .impl)
        seen.append(await store.currentRev)
        try await store.remove(t.id)
        seen.append(await store.currentRev)
        #expect(seen == seen.sorted())            // strictly increasing (monotonic)
        #expect(Set(seen).count == seen.count)    // unique — no two mutations share a rev
        #expect(seen.first! >= 1)
    }

    @Test("a pre-upgrade bare-array tasks.json reads back rev = 0")
    func test_preUpgradeBareArrayDefaultsRevZero() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let legacy = try OrchestraJSON.pretty.encode([sample("old")])   // legacy = top-level array, no {rev,tasks}
        try legacy.write(to: URL(fileURLWithPath: path))
        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(await store.currentRev == 0)
    }
}
```

> `.plan`/`.impl` are real `Column` cases (the board columns). Match `Task(...)`/`Column` to the real definitions (copy the existing `TaskStoreTests.sample()` helper) if they've drifted; the assertions are the contract.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TaskStoreRevTests`
Expected: FAIL — `currentRev` does not exist / on-disk shape is a bare array.

- [ ] **Step 3: Write minimal implementation** — `TaskStore.swift`

Add the rev field + on-disk wrapper. Replace the marked regions:

```swift
public actor TaskStore {
    private let path: String
    private var tasks: [Task] = []
    private var loaded = false
    /// Monotonic board version, bumped in `persist()` and persisted in the `{rev, tasks}` payload.
    /// A pre-upgrade bare-array `tasks.json` loads as `rev = 0` (the one on-disk compat we keep).
    public private(set) var currentRev: Int = 0

    // ... init unchanged ...

    /// On-disk payload shape (post-upgrade). Pre-upgrade files are a bare `[Task]` array.
    private struct StoredBoard: Codable { let rev: Int; let tasks: [Task] }

    @discardableResult
    public func load() -> [Task] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            tasks = []; currentRev = 0; loaded = true; return tasks
        }
        do {
            let data = try Data(contentsOf: url)
            if let board = try? OrchestraJSON.decoder.decode(StoredBoard.self, from: data) {
                tasks = board.tasks; currentRev = board.rev            // post-upgrade
            } else {
                tasks = try OrchestraJSON.decoder.decode([Task].self, from: data)
                currentRev = 0                                          // pre-upgrade migration read
            }
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            tasks = []; currentRev = 0
        }
        loaded = true
        return tasks
    }

    /// Synchronous, actor-independent peek of the persisted `rev` — used by `OrchestraService.init`
    /// to seed its `lastRev` mirror BEFORE the control server accepts RPCs (no `await`, so it can run
    /// in the sync init). `nonisolated` is legal: it reads only the immutable `let path` and the file.
    /// Same decode order as `load`; defaults 0 for absent/bare-array/malformed.
    public nonisolated func peekPersistedRev() -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let board = try? OrchestraJSON.decoder.decode(StoredBoard.self, from: data)
        else { return 0 }
        return board.rev
    }

    private func persist() throws {
        currentRev += 1                                                // single bump funnel
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(StoredBoard(rev: currentRev, tasks: tasks))
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
```

> The `StoredBoard`-first, bare-array-fallback decode order is deliberate: a bare array fails `StoredBoard` decode cleanly (array ≠ object), so the fallback catches exactly the pre-upgrade shape; a genuinely malformed file fails both and hits the `.bak` path. Keep `try?` on the `StoredBoard` decode and `try` on the `[Task]` decode so malformed still throws into the `catch`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TaskStoreRevTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite** (the on-disk shape changed — every store consumer must still load)

Run: `swift test`
Expected: green. If any test wrote a bare-array `tasks.json` fixture and asserted on-disk shape, update it to the `{rev, tasks}` shape (or leave it — the fallback read still works). Fix real breaks; do not weaken assertions.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/TaskStore.swift Tests/OrchestraCoreTests/TaskStoreTests.swift
git commit -m "feat(sync): monotonic board rev stamped by TaskStore"
```

---

## Task 1.2: `rev` on the event envelope + `BoardSnapshot`

**Files:**
- Modify: `Sources/OrchestraKit/Model.swift` (add `EventEnvelope`; add `rev` to `BoardSnapshot:707-722`)
- Modify: `Sources/OrchestraCore/TaskStore.swift` (`create`/`update`/`move` return `(task, rev)`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`subscribers:74`, `subscribe():136`, `emit:149`, `emitActivity:153`, `emitOwnerIfChanged`, `.shellsChanged:754`, `boardSnapshot():805`, + the **18** `.taskUpserted` emit sites across `+Report`/`+Diff`/`+MergeRequest`/`+Remote`/`+Recovery`/`+Tree`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` init (seed `lastRev = store.peekPersistedRev()`); `Sources/OrchestraCore/OrchestraService+Tree.swift:321` (`shipped()` — emit-only-on-success)
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (event pump `:30`, `handleEvent:272`, `eventNotification:290`, ring-replay `:119`)
- Modify: `Sources/OrchestraKit/Control/ControlClient.swift` (event decode `:322-325`)
- Test: `Tests/OrchestraCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: `TaskStore.currentRev` (Task 1.1).
- Produces: `EventEnvelope{ public let rev: Int; public let event: Event }` (Codable, Sendable, Equatable). `BoardSnapshot.rev: Int`. `TaskStore.create/update/move -> (task: Task, rev: Int)`. `OrchestraService.subscribe() -> AsyncStream<EventEnvelope>`. `emit(_ event: Event, rev: Int)` (**synchronous**). Client `subscribe()` still returns `AsyncStream<Event>` (envelope unwrapped internally).

- [ ] **Step 1: Write the failing test** — **create** `Tests/OrchestraCoreTests/ControlServerTests.swift` (absent). Build the service via `TestEnv.make()` (the pattern `ReportTests`/`Stubs.swift` use) and drive a **deterministic `move`** (emits `.taskUpserted` synchronously at `OrchestraService.swift:630` — no worktree/session stubs needed) rather than a full `spawn`.

```swift
import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("ControlServer / event rev") struct ControlServerRevTests {
    // Seed a card cheaply, then use `move` as the deterministic taskUpserted emitter.
    private func seededCard(_ svc: OrchestraService) async throws -> Task {
        let env = TestEnv.make()   // if a lighter path exists, prefer it; spawn works with the stubs
        return try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
    }

    @Test("a task-state event carries the store's rev at emit")
    func test_eventCarriesRev() async throws {
        let env = TestEnv.make()
        let card = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let stream = await env.svc.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = try await env.svc.move(card.id, to: .review)          // deterministic .taskUpserted
        let expected = await env.svc.storeCurrentRevForTest()     // = TaskStore.currentRev after the move
        // drain until the taskUpserted for our move (skip any interleaved ephemerals)
        var env0 = await iter.next()
        while env0 != nil, { if case .taskUpserted = env0!.event { return false }; return true }() {
            env0 = await iter.next()
        }
        #expect(env0?.rev == expected)
    }

    @Test("BoardSnapshot carries the store's rev")
    func test_boardSnapshotCarriesRev() async throws {
        let env = TestEnv.make()
        _ = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let snap = await env.svc.boardSnapshot()
        #expect(snap.rev == (await env.svc.storeCurrentRevForTest()))
    }

    @Test("an ephemeral activity event carries the current board rev (lastRev mirror)")
    func test_activityEventCarriesCurrentRev() async throws {
        let env = TestEnv.make()
        let card = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        _ = try await env.svc.move(card.id, to: .review)          // primes lastRev to the current board rev
        let rev = await env.svc.storeCurrentRevForTest()
        let stream = await env.svc.subscribe()
        var iter = stream.makeAsyncIterator()
        await env.svc.emitActivityForTest()                      // ephemeral — stamps lastRev
        let e = await iter.next()
        #expect(e?.rev == rev)
        if case .activity = e?.event {} else { Issue.record("expected activity") }
    }
}
```

> Adapt to the real `TestEnv`/`Stubs.swift` conventions (search `TestEnv.make` / `struct TestEnv`). Add two tiny `@testable` accessors on `OrchestraService` if absent: `func storeCurrentRevForTest() async -> Int { await store.currentRev }` and `func emitActivityForTest() { emitActivity(.custom, nil, .daemon, "test") }`. Use whatever real `ActivityKind`/args compile. The **assertions** (`rev == currentRev` for task events; `rev == lastRev` for ephemerals) are the contract. If subscribing *before* the mutation is easier, note that `spawn` itself emits `.taskUpserted`s you must drain first — subscribing *after* the seed spawn and driving a `move` (as above) keeps the stream focused.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ControlServerTests`
Expected: FAIL — `EventEnvelope` / `BoardSnapshot.rev` do not exist; `subscribe()` yields `Event`.

- [ ] **Step 3a: Add `EventEnvelope` + `BoardSnapshot.rev`** — `Model.swift`

After the `Event` enum (`Model.swift:687`):

```swift
/// Every event notification to clients is wrapped with the board `rev` at emit, so a client can
/// detect a gap (a missed event) and resync. Ephemeral events carry the current board rev.
public struct EventEnvelope: Codable, Sendable, Equatable {
    public let rev: Int
    public let event: Event
    public init(rev: Int, event: Event) { self.rev = rev; self.event = event }
}
```

Add `rev` to `BoardSnapshot` (`:707-722`) — new stored property, init parameter (place it first for clarity), and assignment:

```swift
public struct BoardSnapshot: Codable, Sendable, Equatable {
    public let rev: Int
    public let tasks: [Task]
    // ... existing fields ...
    public init(rev: Int, tasks: [Task], archived: [Task], config: Config, models: [AgentModel],
                agents: [AgentInfo], sessions: [CardSessions], owners: [AgentTerminalOwnerState]) {
        self.rev = rev
        self.tasks = tasks; self.archived = archived; self.config = config
        self.models = models; self.agents = agents; self.sessions = sessions; self.owners = owners
    }
}
```

- [ ] **Step 3b-i: `TaskStore` mutators return the produced rev** — `TaskStore.swift`

Change `create`/`update`/`move` to return the rev atomically with the task (so the emit binds the exact mutation's rev, no reentrancy gap). `remove`/`save` are unchanged (no `.taskRemoved` emit exists).

```swift
@discardableResult
public func create(_ task: Task) throws -> (task: Task, rev: Int) {
    ensureLoaded()
    var t = task
    t.order = nextOrder(in: t.column)
    t.updatedAt = Date()
    tasks.append(t)
    try persist()                     // bumps currentRev
    return (t, currentRev)
}

@discardableResult
public func update(_ id: UUID, _ mutate: (inout Task) -> Void) throws -> (task: Task, rev: Int) {
    ensureLoaded()
    guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
        throw OrchestraError.unknownTask(id.uuidString)
    }
    mutate(&tasks[idx])
    tasks[idx].updatedAt = Date()
    try persist()
    return (tasks[idx], currentRev)
}

@discardableResult
public func move(_ id: UUID, to column: Column) throws -> (task: Task, rev: Int) {
    let order = nextOrder(in: column, ignoring: id)
    return try update(id) { $0.column = column; $0.order = order }   // inherits (task, rev)
}
```

> **Call-site spread — THE PRINCIPLE (compile errors guide the mechanics):** every site that emits `.taskUpserted(x)` MUST obtain `rev` from the **same `store` mutation that produced `x`**, and MUST emit **only when that mutation succeeded** (so a rev exists). All 18 emit sites were enumerated and verified against the tree; the shapes:
> - **(a) plain capture (most sites, e.g. `+Report:133`, `+Diff` n/a, `OrchestraService:629/718`, `+Recovery:120/185/219`, `+Tree:36/62/78/92`):** `let updated = try await store.update/create/move(...)` → `let (updated, rev) = …` then `emit(.taskUpserted(updated), rev: rev)`.
> - **(b) `if let` optional (`+Remote:130-133`, `+MergeRequest:40-43`, `+Tree:275-279`):** `if let saved = try? await store.update(...) { emit(.taskUpserted(saved)) }` → `if let (saved, rev) = try? await store.update(...) { emit(.taskUpserted(saved), rev: rev) }`.
> - **(c) `guard let` optional (`+Diff:48-49`, `+Recovery:299-302`):** `guard let saved = try? await store.update(...) else { … }` → `guard let (saved, rev) = try? await store.update(...) else { … }`.
> - **(d) optional-captured, unwrapped-later, reused (`+Tree:374/385` `recomputeTreeStat`):** `let saved = try? await store.update(...) { … }` then `guard changed, let saved else { return }` → `let res = try? await store.update(...) { … }` then `guard changed, let (saved, rev) = res else { return }`; then `emit(.taskUpserted(saved), rev: rev)` (`saved.shortId` still works).
> - **(e) TRAP — `?? fallback` to a non-mutation value (`+Tree:321-322` `shipped()`):** `let updated = (try? await store.update(child.id, {…})) ?? child; emit(.taskUpserted(updated))` — the fallback `child` has no rev and the tuple breaks the `??`. **Restructure to emit only on success:** `if let (updated, rev) = try? await store.update(child.id, {…}) { emit(.taskUpserted(updated), rev: rev); emitActivity(.command, updated, source, "shipped \(child.branch)"); return updated } else { return child }`.
> - **(f) deferred emit across many lines (`spawn`, `store.create:401` → `emit:424`):** capture `let (created, rev) = try await store.create(...)` at `:401`; thread `rev` down to `emit(.taskUpserted(created), rev: rev)` at `:424` (no store mutation of `created` happens in between — the pair stays consistent).
> - **(g) discard (2 sites — `+MergeRequest:86`, `+Tree:165`):** `_ = try? await store.update(...)` — **unchanged** (discards the tuple).
> - **(h) test captures (fix in this task — compile errors):** `TaskStoreTests.swift:20,23,30,31,48` and this plan's own `test_everyMutationBumpsRev` → append `.task`. Existing `ReportTests` capture their spawn result (not a store-mutator return) — unaffected.
> Also verified NOT traps (plain shape (a), fresh mutation present): `+Recovery:194`, `+Tree:40/66/279`.

- [ ] **Step 3b-ii: Synchronous `emit(_:rev:)` + `lastRev` mirror** — `OrchestraService.swift`

```swift
// :74
private var subscribers: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
/// Mirror of the last board rev an event carried; stamped onto ephemeral events (which never bump
/// rev, so the last task-state rev is the current board rev). Seeded in init via store.peekPersistedRev().
private var lastRev: Int = 0

// :136
public func subscribe() -> AsyncStream<EventEnvelope> {
    let sid = UUID()
    return AsyncStream { cont in
        subscribers[sid] = cont
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            _Concurrency.Task { await self.unsubscribe(sid) }
        }
    }
}

// :149  — SYNCHRONOUS: rev is passed in (from the mutation return, or lastRev for ephemerals).
// No await between mutation and emit → no reentrancy skew.
func emit(_ event: Event, rev: Int) {
    lastRev = rev
    let envelope = EventEnvelope(rev: rev, event: event)
    for cont in subscribers.values { cont.yield(envelope) }
}

// :153  — ephemeral: stamps the current board rev via the mirror
func emitActivity(_ kind: ActivityKind, _ task: Task?, _ source: ActivitySource, _ text: String) {
    let item = ActivityItem(taskId: task?.id, ref: task?.ref(), source: source, kind: kind, text: text)
    emit(.activity(item), rev: lastRev)
}
```

- In `emitOwnerIfChanged` (`:855-860`): `emit(.agentTerminalOwner(state), rev: lastRev)`.
- At `:754`: `emit(.shellsChanged(ShellWindowsState(cardId: t.id, shells: shells)), rev: lastRev)`.
- At the **21 task-state `emit(.taskUpserted(x))` sites** (OrchestraService.swift + `+Report`/`+Diff`/`+MergeRequest`/`+Remote`/`+Recovery`/`+Tree`): pass the rev captured from that site's mutation → `emit(.taskUpserted(saved), rev: rev)`. Each such site has a `store.create`/`update`/`move` immediately above it that now yields `(saved, rev)`.
- **Seed `lastRev` at `init` (NOT in `recoverSessions` — R2 fix)** — `server.start()` (`main.swift:24`) accepts RPCs, and `PushNotifier.run()` subscribes, **before** the async boot `Task` ever reaches `recoverSessions()` (`main.swift:50`); an early `borrow`/`trust`/`set-parent` RPC could emit an ephemeral activity at `lastRev == 0`. So seed it synchronously in `OrchestraService.init`, before the server can accept anything:

```swift
public init(config: Config, store: TaskStore, ...) {
    // ... existing assignments ...
    self.lastRev = store.peekPersistedRev()   // sync, nonisolated; before server.start() accepts RPCs
}
```

Every subsequent `emit(_:rev:)` refreshes `lastRev`, so it tracks from the first mutation on. (This makes any `recoverSessions` seed redundant — do not add one.)
- **Second `subscribe()` consumer (`PushNotifier.swift:41`)** — `for await event in await service.subscribe() { await handle(event) }` now receives an `EventEnvelope`; change to `await handle(event.event)`. Leave `handle(_ event: Event)` (`:48`, `public`, unit-tested) as-is. This is the only other daemon-side `subscribe()` — `BoardStore.swift:454` is the **client** `subscribe()` (stays `AsyncStream<Event>`, unaffected).
- In `boardSnapshot()` (`:805`): stamp rev and refresh the mirror:

```swift
public func boardSnapshot() async -> BoardSnapshot {
    let rev = await store.currentRev
    lastRev = rev
    let active = await list(nil)
    // ... unchanged ...
    return BoardSnapshot(rev: rev, tasks: active, archived: archived, config: config,
                         models: models(agentId: nil), agents: agents(),
                         sessions: sessionsList, owners: owners)
}
```

> **Read `rev` BEFORE `list(nil)` (deliberate, fail-safe).** A mutation landing between the two awaits makes `snap.rev` *≤* the true rev of the task data → the client, on resync, at most does a redundant idempotent re-apply, never drops a real event. Reading rev *after* `list` could over-claim (snapshot data older than its rev) and cause a dropped event — so rev-first is the safe order.

- [ ] **Step 3c: Carry the envelope over the wire** — `ControlServer.swift`

```swift
// :30  event pump
for await envelope in await self.service.subscribe() {
    self.handleEvent(envelope)
}

// :272
private func handleEvent(_ envelope: EventEnvelope) {
    let line = (try? RPCCodec.line(eventNotification(envelope))) ?? Data()
    let conns: [PeerConnection] = lock.withLock {
        if case .activity(let item) = envelope.event {        // ring buffers the inner event only
            ring.append(item)
            if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        }
        return Array(subscribers.values)
    }
    for c in conns { c.enqueue(line) }
}

// :290
private func eventNotification(_ envelope: EventEnvelope) -> RPCNotification {
    RPCNotification(method: "event", params: try? JSONValue(encodable: envelope))
}
```

> **Ring-replay site (`case "subscribe":` `:119`)** — the ring replays historical `.activity` items to a newly-connected client via `eventNotification(.activity(item))`, inside a **synchronous** `lock.withLock` that cannot `await` the service. Wrap each replayed item as `eventNotification(EventEnvelope(rev: 0, event: .activity(item)))`. `rev: 0` is correct here: replayed activities are historical, informational, and never drive gap-detection (a reconnecting client resyncs from the fresh `boardSnapshot`, which carries the live rev). Verify the exact construction against the file before editing.

- [ ] **Step 3d: Decode the envelope on the client** — `ControlClient.swift:322`

```swift
if msg.method == "event" {
    if let env = try? msg.params?.decode(EventEnvelope.self) {
        // Stage 6 consumes env.rev for gap detection; Stage 1 forwards the inner event unchanged.
        stateLock.withLock { eventContinuation }?.yield(env.event)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ControlServerTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: green. Update any test that constructed `BoardSnapshot(tasks:...)` positionally (only the one production site exists at `:817`; tests generally use `boardSnapshot()`), or that iterated `subscribe()` expecting a bare `Event` — those now get `EventEnvelope` (read `.event`). Fix real breaks; keep assertions honest.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraKit/Model.swift Sources/OrchestraCore/OrchestraService.swift \
        Sources/OrchestraCore/Control/ControlServer.swift Sources/OrchestraKit/Control/ControlClient.swift \
        Tests/OrchestraCoreTests/ControlServerTests.swift
git commit -m "feat(sync): carry board rev on events and boardSnapshot"
```

---

## Task 1.3: `report()` field-delta write (kill `$0 = task`)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift:133`; `Sources/OrchestraKit/Model.swift` (add `applyReportFields`)
- Test: `Tests/OrchestraCoreTests/ReportTests.swift` (**exists — APPEND a new suite; do NOT overwrite the 23 existing tests**)

**Interfaces:**
- Consumes: nothing new. Produces: `Task.applyReportFields(from:)` — overlays exactly the report-owned fields from a computed snapshot onto `self`, leaving all other fields untouched. `report()` persists via `store.update(id) { $0.applyReportFields(from: task) }`.

**Report-owned fields (verified: exactly the `task.<field> =` assignments in the `report` body — cross-checked against `+Report.swift`):**
`status`, `deadReason`, `deadDetail`, `agentSessionId`, `priorSessionIds`, `desc`, `titleProvisional`, `title`, `ctxPct`, `model`, `waitReason`. (`model.displayName` is a sub-field of `model`, covered by copying `model` whole. `updatedAt` is stamped by `store.update` itself.)

> **Why a pure extracted function, not an integration race test (revised after plan review round 1):** GPT-5.5 correctly flagged that mutating an unrelated field *before* calling `report()` lets `report` snapshot the already-mutated value, so the whole-object `$0 = task` would *preserve* it — the test would pass on unfixed code. There is no deterministic in-process seam to mutate the store strictly between `report`'s entry read and its `store.update` without adding a production test-hook. So we test the field-delta **directly** as a pure function: it goes red before implementation (the function doesn't exist → compile error) and cannot pass on unfixed code (the function *is* the fix).

- [ ] **Step 1: Write the failing test** — **APPEND** a new `struct` after the existing `ReportTests` in `Tests/OrchestraCoreTests/ReportTests.swift` (the file already imports Foundation/Testing/`@testable import OrchestraCore`; no new header). Name `ReportDeltaTests` (verified: no collision).

```swift
@Suite("report field-delta") struct ReportDeltaTests {
    private func sample() -> Task {
        Task(title: "c", repo: "/r", branch: "b", cwd: "/wt/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: .plan, order: 0, initialPrompt: "c")
    }
    @Test("applyReportFields overlays only report-owned fields, preserving concurrently-mutated ones")
    func test_reportDoesNotClobberConcurrentFields() throws {
        // `current` = the store's live value, with an UNRELATED field (column) changed concurrently
        // after report took its snapshot. `snapshot` = what report computed from its (older) read.
        var current = sample()
        current.column = .impl             // concurrent write to a field report does NOT own
        current.ctxPct = 0
        var snapshot = current
        snapshot.column = .plan            // report's stale view of the unowned field
        snapshot.ctxPct = 42               // report's owned field, freshly computed

        current.applyReportFields(from: snapshot)

        #expect(current.ctxPct == 42)      // owned field applied
        #expect(current.column == .impl)   // unowned field PRESERVED — not clobbered
    }
}
```

> Match `Task(...)`/`Column` to the real definitions (reuse the existing `ReportTests` spawn/`sample` helper if simpler). The two `#expect`s are the contract.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReportDeltaTests`
Expected: FAIL — `Task.applyReportFields(from:)` does not exist (compile error). This cannot pass on unfixed code.

- [ ] **Step 3a: Write the field-delta function** — add to `Sources/OrchestraKit/Model.swift` (near `Task`) or `OrchestraService+Report.swift`

```swift
extension Task {
    /// The `report()` field-delta write: overlay exactly the fields `report()` owns from a
    /// freshly-computed snapshot `s`, leaving every other (possibly concurrently-mutated) field at
    /// self's current value. Centralizes report's ownership so a whole-object write can't clobber.
    mutating func applyReportFields(from s: Task) {
        status = s.status
        deadReason = s.deadReason
        deadDetail = s.deadDetail
        agentSessionId = s.agentSessionId
        priorSessionIds = s.priorSessionIds
        desc = s.desc
        titleProvisional = s.titleProvisional
        title = s.title
        ctxPct = s.ctxPct
        model = s.model
        waitReason = s.waitReason
    }
}
```

- [ ] **Step 3b: Wire `report()` to use it** — `OrchestraService+Report.swift:133`

Replace `let saved = try await store.update(id) { $0 = task }` with:

```swift
let saved = try await store.update(id) { $0.applyReportFields(from: task) }.task
```

(`.task` because `update` now returns `(task, rev)` after Task 1.2; this site does not emit with rev — the existing `emit(.taskUpserted(saved))` below becomes `emit(.taskUpserted(saved), rev: rev)` in the 1.2 sweep, so capture `let (saved, rev) = ...` if 1.2 already landed here.) Keep the `guard task != before else { return }` idempotency gate above it unchanged.

> **Sweep (do it in this step, record the result in the commit body):** `rg -Fn '$0 = task' Sources App` — the only per-card whole-object `Task` write is this one (`+Report.swift:133`). `ControlServer.swift:129` `setConfig { $0 = newConfig }` is the **config** setter (a deliberate whole-`Config` replace, not a per-card `Task` record) — out of scope, leave it. The `+Tree.swift:369-384` `treeStat` writers already compute inside the `store.update` closure (`$0.treeStat = …`) — field-deltas already, leave them. After this task the suite-wide rule is **field-delta patches only** for `Task` writes.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReportDeltaTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraKit/Model.swift Sources/OrchestraCore/OrchestraService+Report.swift \
        Tests/OrchestraCoreTests/ReportTests.swift
git commit -m "fix(report): field-delta write so report no longer clobbers concurrent mutations"
```

---

## Task 1.4: Docs

**Files:**
- Modify: `docs/02-architecture.md` (sections `## The control plane` `:55` and `### Request flow, server-side` `:97`; also `## The report channel` `:133` for the field-delta rule)

- [ ] **Step 1: Update the architecture doc**

- In **`### Request flow, server-side`** and **`## The control plane`**: document that the board carries a monotonic `rev` (owned by `TaskStore`, bumped in its single `persist()` funnel, persisted in the `{rev, tasks}` on-disk shape), that every `event` notification is wrapped in an `EventEnvelope{rev, event}`, and that `BoardSnapshot` carries `rev` — the cursor a client uses to detect a missed event and resync (client-side gap detection lands in a later stage).
- In **`## The report channel`**: note that `report()` writes **field-deltas** (only the fields it owns), never a whole-object replace, so a concurrent mutation to an unrelated field is never clobbered.
- Keep edits tight and truthful to what Stage 1 actually ships (no forward-promises beyond "consumed in a later stage"). Verify the exact heading anchors in the file before editing.

- [ ] **Step 2: Commit**

```bash
git add docs/02-architecture.md
git commit -m "docs(sync): document board rev on events/snapshot"
```

---

## Self-review checklist (run before requesting plan review)

1. **Spec coverage:** 1.1 (store rev + on-disk shape + pre-upgrade read) ✓; 1.2 (event envelope + BoardSnapshot rev, stamped at emit) ✓; 1.3 (report field-delta + repo sweep) ✓; 1.4 (docs) ✓. All four Stage-1 tasks mapped; nothing from Stage 2+ pulled in.
2. **Test names match the plan:** `test_everyMutationBumpsRev`, `test_eventCarriesRev`, `test_boardSnapshotCarriesRev`, `test_reportDoesNotClobberConcurrentFields` — all present; plus defensive `test_preUpgradeBareArrayDefaultsRevZero` and `test_activityEventCarriesCurrentRev`.
3. **Type consistency:** `currentRev` (store), `create`/`update`/`move -> (task, rev)`, `EventEnvelope{rev,event}`, `BoardSnapshot.rev`, `lastRev` (service mirror), synchronous `emit(_ event:, rev:)`, `Task.applyReportFields(from:)` — names used identically across tasks.
4. **No placeholders:** every code step shows real code; test-helper names are flagged for adaptation to the file's existing `Stubs.swift` conventions (the assertions are exact).
5. **Green-after-every-task:** each task ends with a full `swift test` run; the on-disk shape change (1.1) and wire change (1.2) each have an explicit "fix real breaks, keep assertions honest" full-suite step.
6. **Review round 1 resolved (GPT-5.5):** (a) BLOCKER reentrancy rev-skew → strict binding (mutators return rev, synchronous `emit(_:rev:)`); (b) MAJOR `lastRev` unseeded → seed in `recoverSessions()` + refresh on every emit; (c) MAJOR report clobber test passed on unfixed code → pure `applyReportFields(from:)` unit test.
7. **Review round 2 resolved (Opus xhigh + GPT-5.5 — both confirmed rev-binding + `applyReportFields` field-set sound):** (a) BLOCKER `PushNotifier.swift:41` 2nd `subscribe()` consumer → unwrap `event.event` (both reviewers); (b) BLOCKER `TaskStoreTests`/`ReportTests` already exist (6+23 tests) — Write would silently delete them → **APPEND** (Opus); (c) MAJOR `+Tree:321 shipped()` `?? child` fallback has no fresh rev + breaks the tuple → emit-only-on-success restructure (GPT); (d) MAJOR seed timing — `server.start()` accepts RPCs before `recoverSessions()` → seed `lastRev` in `OrchestraService.init` via `nonisolated peekPersistedRev()` (GPT); (e) MAJOR blast-radius counts corrected (18 emit sites) + all shapes enumerated + test-side captures added to the spread; (f) NITs: `+Tree:374` optional-unwrap shape, `boardSnapshot` rev-before-`list` fail-safe note, deterministic `move` in the rev test. All 18 emit sites individually verified against the tree (only `+Tree:321`/`:374` are traps).
