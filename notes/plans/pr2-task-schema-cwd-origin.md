# PR2 — Task Schema: `cwd` + `origin` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `Task` to a single total run-directory field `cwd` plus an `origin` enum (`.worktree | .scratch | .borrowed`), removing the redundant `worktree` string and routing every run-dir call site through `cwd` — **with no observable behavior change** (only `.worktree` cards exist after this PR).

**Architecture:** `Task` gains `cwd: String` and `origin: CardOrigin`, drops `worktree: String`. A custom `init(from:)` backfills both from the old `worktree` field for existing persisted cards. The archive block becomes a `switch origin`. Every reader of `t.worktree` (≈14 sites) becomes `t.cwd`. Because spawn sets `cwd = worktreePath(repo,branch)` and `origin = .worktree`, the system behaves exactly as before.

**Tech Stack:** Swift 6 / SwiftPM (`OrchestraCore`), SwiftUI (`App`), JSON persistence (`tasks.json`).

## Global Constraints

- Core is unit-tested via `swift build && swift test`; the app via `scripts/build-app.sh`. (spec)
- (Agent housekeeping only — **not** a code constraint) The implementing agent's own git/commit shell commands avoid `git -C`; Orchestra's *source* may use any git invocation freely.
- **Pure refactor — behavior identical.** Success = all pre-existing tests still pass + the migration test.
- `access` is **NOT** in this PR (it lands in PR3). Define all three `origin` cases now but only ever construct `.worktree`.
- `cwd` is authoritative for every directory operation, including the worktree `remove` and the sibling refcount (`cwd` == worktree root for `.worktree` cards). `Config.worktreePath` is used only at spawn.

---

## File Structure

- `Sources/OrchestraCore/Model.swift` (Modify) — add `CardOrigin`; add `cwd`/`origin` to `Task`; drop `worktree`; custom `init(from:)` migration; keep the memberwise `init` (now takes `cwd`/`origin`).
- `Sources/OrchestraCore/OrchestraService.swift` (Modify) — spawn sets `cwd`/`origin`; archive switches on `origin`; `openShell`/`exec`/AdapterContext use `t.cwd`.
- `Sources/OrchestraCore/OrchestraService+Recovery.swift` (Modify) — AdapterContext `cwd: task.cwd`.
- `Sources/OrchestraCore/SessionManager.swift` (Modify) — tmux `-c task.cwd`.
- `App/BoardModel.swift` (Modify) — `worktreeSiblings` compares `cwd`.
- `App/Views/InspectorView.swift`, `App/Views/RecoveryView.swift` (Modify) — display `task.cwd`.
- `Sources/orchestra/CLIRunner.swift` (Modify) — print `cwd`.
- `Tests/OrchestraCoreTests/TaskMigrationTests.swift` (Create), `Tests/OrchestraCoreTests/ArchiveOriginTests.swift` (Create).

---

### Task 1: `CardOrigin` enum + `Task` fields + migration decoder

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (`Task` ~`:95-185`)
- Test: `Tests/OrchestraCoreTests/TaskMigrationTests.swift` (Create)

**Interfaces:**
- Produces:
  - `enum CardOrigin: String, Codable, Sendable { case worktree, scratch, borrowed }`
  - `Task.cwd: String` (the run dir), `Task.origin: CardOrigin`; `Task.worktree` removed.
  - Memberwise `init(...)` now takes `cwd: String, origin: CardOrigin = .worktree` (replacing `worktree`).
  - `init(from:)` backfills: missing `cwd` ⇐ old `worktree`; missing `origin` ⇐ `.worktree`.

- [ ] **Step 1: Write the failing migration test**

```swift
import XCTest
@testable import OrchestraCore

final class TaskMigrationTests: XCTestCase {
    // Old persisted card: has `worktree`, no `cwd`/`origin`.
    func test_legacy_task_json_backfills_cwd_and_origin() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"x","titleProvisional":false,"desc":"",
         "repo":"/r/app","branch":"feat","worktree":"/wt/app/feat","agentId":"claude-code",
         "model":"claude-opus-4-8","startIn":"impl","column":"impl","order":0,"status":"running",
         "ctxPct":0,"priorSessionIds":[],"initialPrompt":"go","archived":false,
         "createdAt":0,"updatedAt":0}
        """
        let t = try JSONDecoder.orchestra.decode(Task.self, from: Data(legacy.utf8))
        XCTAssertEqual(t.cwd, "/wt/app/feat")
        XCTAssertEqual(t.origin, .worktree)
    }

    func test_new_task_roundtrips_cwd_and_origin() throws {
        let t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        let data = try JSONEncoder.orchestra.encode(t)
        let back = try JSONDecoder.orchestra.decode(Task.self, from: data)
        XCTAssertEqual(back.cwd, "/wt/app/feat")
        XCTAssertEqual(back.origin, .worktree)
    }
}
```

> Use whatever encoder/decoder the store uses (find it: `grep -rn "JSONDecoder\|JSONEncoder" Sources/OrchestraCore`). If there's no `JSONDecoder.orchestra`, use a plain `JSONDecoder()` matching the store's date strategy.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TaskMigrationTests`
Expected: FAIL — `Task.init` has no `cwd:` / `worktree` still required.

- [ ] **Step 3: Implement** — in `Model.swift`:

Add the enum above `Task`:
```swift
/// What kind of directory a card runs in. Drives archive cleanup ("Orchestra deletes only dirs it
/// made": `.worktree` + `.scratch`) and board placement (`.worktree` ⇒ workflow column).
public enum CardOrigin: String, Codable, Sendable { case worktree, scratch, borrowed }
```

In `Task`, replace `public var worktree: String` with:
```swift
public var cwd: String           // the ONE path: where the agent + shells run (== worktree root for .worktree)
public var origin: CardOrigin    // worktree | scratch | borrowed
```

In the memberwise `init`, replace the `worktree: String` parameter with `cwd: String, origin: CardOrigin = .worktree` and assign `self.cwd = cwd; self.origin = origin` (drop `self.worktree = worktree`).

Add a custom decoder (Swift won't synthesize the backfill). Add `CodingKeys` if not present and:
```swift
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.title = try c.decode(String.self, forKey: .title)
    self.titleProvisional = try c.decodeIfPresent(Bool.self, forKey: .titleProvisional) ?? false
    self.desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
    self.repo = try c.decode(String.self, forKey: .repo)
    self.branch = try c.decode(String.self, forKey: .branch)
    // MIGRATION: prefer new `cwd`; fall back to the old `worktree` string.
    let legacyWorktree = try c.decodeIfPresent(String.self, forKey: .worktree)
    self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? legacyWorktree ?? ""
    self.origin = try c.decodeIfPresent(CardOrigin.self, forKey: .origin) ?? .worktree
    self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude-code"
    self.model = try c.decode(AgentModel.self, forKey: .model)
    self.startIn = try c.decode(StartIn.self, forKey: .startIn)
    self.column = try c.decode(Column.self, forKey: .column)
    self.order = try c.decode(Int.self, forKey: .order)
    self.status = try c.decodeIfPresent(AgentStatus.self, forKey: .status) ?? .running
    self.deadReason = try c.decodeIfPresent(DeadReason.self, forKey: .deadReason)
    self.deadDetail = try c.decodeIfPresent(String.self, forKey: .deadDetail)
    self.ctxPct = try c.decodeIfPresent(Double.self, forKey: .ctxPct) ?? 0
    self.agentSessionId = try c.decodeIfPresent(String.self, forKey: .agentSessionId)
    self.priorSessionIds = try c.decodeIfPresent([String].self, forKey: .priorSessionIds) ?? []
    self.initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? ""
    self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
}

enum CodingKeys: String, CodingKey {
    case id, title, titleProvisional, desc, repo, branch, cwd, worktree, origin, agentId, model,
         startIn, column, order, status, deadReason, deadDetail, ctxPct, agentSessionId,
         priorSessionIds, initialPrompt, archived, createdAt, updatedAt
}
```

> Note `worktree` stays in `CodingKeys` (decode-only, for migration) but is no longer a stored property and is never encoded. Confirm the synthesized encoder is acceptable, or add `encode(to:)` writing `cwd`/`origin` and not `worktree`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TaskMigrationTests`
Expected: PASS (2 tests). The build will now break at every `t.worktree` site — fixed in Tasks 2–4.

- [ ] **Step 5: Commit** (after Task 2 makes it build — or commit Model.swift now and finish the build fix next)

```bash
git add Sources/OrchestraCore/Model.swift Tests/OrchestraCoreTests/TaskMigrationTests.swift
git commit -m "feat(core): Task cwd + origin fields with legacy-worktree migration"
```

---

### Task 2: Reroute core run-dir call sites to `cwd`; spawn sets `cwd`/`origin`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (spawn ~`:67-105`; `openShell` `:180-181`; `exec` `:191-192`; AdapterContext `:203`)
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`:62`, `:111`, `:155`)
- Modify: `Sources/OrchestraCore/SessionManager.swift` (`:55`)

**Interfaces:**
- Consumes: `Task.cwd`, `Config.worktreePath`. `SessionManager.ensure` already takes a `Task` — change its internal `task.worktree` to `task.cwd`.

- [ ] **Step 1: Spawn** — in `spawn(_:)`, after `worktrees.ensure`:
```swift
let (wt, _) = try worktrees.ensure(repo: realRepo, branch: input.branch)
// ...
let task = Task(
    title: title, titleProvisional: provisional, desc: "",
    repo: realRepo, branch: input.branch, cwd: wt, origin: .worktree,   // was worktree: wt
    agentId: adapter.id, model: model, startIn: startIn,
    column: startIn.column, order: 0, status: provisional ? .waiting : .running,
    ctxPct: 0, agentSessionId: sid, initialPrompt: input.prompt)
```
And `AdapterContext(cwd: wt, ...)` stays (it already used `wt`).

- [ ] **Step 2: Replace remaining `t.worktree` / `task.worktree` reads with `.cwd`:**
  - `OrchestraService.swift:180` `newShellWindow(name, cwd: t.worktree)` → `cwd: t.cwd`
  - `:181` `ShellTab(... pwd: t.worktree)` → `pwd: t.cwd`
  - `:191` `resolver.assertAllowed(t.worktree)` → `resolver.assertAllowed(t.cwd)` (relaxation comes in PR3; unchanged here since all cards are `.worktree`)
  - `:192` `Proc.run(... cwd: t.worktree ...)` → `cwd: t.cwd`
  - `:203` `AdapterContext(cwd: t.worktree, ...)` → `cwd: t.cwd`
  - `:208` `CardSessions(... worktree: t.worktree ...)` → `worktree: t.cwd` (keep the `CardSessions.worktree` field name; it's a debug payload)
  - `:214` `launcher.openInZed(t.worktree)` → `t.cwd`
  - Recovery `:62`, `:111`, `:155` `AdapterContext(cwd: task.worktree, ...)` → `cwd: task.cwd`
  - `SessionManager.swift:55` `"-c", task.worktree` → `"-c", task.cwd`

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles (UI still broken — fixed in Task 3).

- [ ] **Step 4: Run the full core suite**

Run: `swift test`
Expected: PASS (pre-existing tests unchanged + migration test). If a test constructs `Task(worktree:)`, update it to `cwd:`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore App-not-yet  # core files only
git commit -m "refactor(core): route run-dir through Task.cwd; spawn sets origin=.worktree"
```

---

### Task 3: Reroute app + CLI display sites to `cwd`

**Files:**
- Modify: `App/BoardModel.swift` (`:65`), `App/Views/InspectorView.swift` (`:284`, `:345`), `App/Views/RecoveryView.swift` (`:43`, `:56`, `:58`), `Sources/orchestra/CLIRunner.swift` (`:115`)

- [ ] **Step 1: Replace reads:**
  - `BoardModel.swift:65` `worktreeSiblings`: `$0.worktree == task.worktree` → `$0.cwd == task.cwd && $0.origin == .worktree && task.origin == .worktree` (scope to worktree cards — borrowed shared cwds are fine, see PR3; harmless now since all are `.worktree`)
  - `InspectorView.swift:284` `task.worktree.split(...)` → `task.cwd.split(...)`
  - `InspectorView.swift:345` `copy(task.worktree)` → `copy(task.cwd)`
  - `RecoveryView.swift:43/:56/:58` `task.worktree` → `task.cwd`
  - `CLIRunner.swift:115` `print("worktree:   \(cs.worktree)")` → keep label or rename to `cwd:`; value already migrated via `CardSessions.worktree = t.cwd`

- [ ] **Step 2: Build app**

Run: `swift build` then `scripts/build-app.sh`
Expected: both build.

- [ ] **Step 3: Commit**

```bash
git add App Sources/orchestra/CLIRunner.swift
git commit -m "refactor(app+cli): display Task.cwd instead of worktree string"
```

---

### Task 4: Archive switches on `origin` (fold in the refcount)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`archive` ~`:153-167`)
- Test: `Tests/OrchestraCoreTests/ArchiveOriginTests.swift` (Create)

**Interfaces:**
- Consumes: `Task.origin`, `Task.cwd`, the existing `worktrees.remove(worktree:force:)` + `OrchestraError.worktreeDirty`. Use the existing fake `WorktreeManaging` test double (find it: `grep -rln "WorktreeManaging\|FakeWorktree" Tests`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OrchestraCore

final class ArchiveOriginTests: XCTestCase {
    func test_archiving_one_of_two_co_located_worktree_cards_keeps_the_tree() async throws {
        let svc = makeServiceWithFakes()                 // mirror existing service-test setup
        let a = try await svc.spawn(.init(repo: "/r/app", branch: "feat", prompt: "a"))
        let b = try await svc.spawn(.init(repo: "/r/app", branch: "feat", prompt: "b"))
        XCTAssertEqual(a.cwd, b.cwd)                     // idempotent ensure → shared tree
        try await svc.archive(a.id)
        XCTAssertFalse(fakeWorktrees.removed.contains(a.cwd))   // sibling b still lives there
        try await svc.archive(b.id)
        XCTAssertTrue(fakeWorktrees.removed.contains(b.cwd))    // last one out removes it
    }
}
```

> Mirror the existing service-test harness (constructor, fakes). If there isn't one, model it on the closest existing `OrchestraServiceTests`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ArchiveOriginTests`
Expected: FAIL until the switch lands (or passes already if refcount logic survives the refactor — then assert the `.borrowed`/`.scratch` no-ops in a later PR).

- [ ] **Step 3: Implement the switch**

```swift
if removeWorktree {
    switch t.origin {
    case .worktree:
        let siblings = await store.all().filter {
            $0.id != id && !$0.archived && $0.origin == .worktree && $0.cwd == t.cwd
        }
        if siblings.isEmpty {
            do { try worktrees.remove(worktree: t.cwd, force: false) }   // cwd == worktree root
            catch OrchestraError.worktreeDirty { /* keep dirty tree */ }
        }
    case .scratch:
        // PR4 fills this in (rm -rf t.cwd). No-op for now (none exist).
        break
    case .borrowed:
        break
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS (full suite + new test).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/ArchiveOriginTests.swift
git commit -m "refactor(core): archive switches on Task.origin; refcount keyed on cwd"
```

---

## Self-Review

- **Spec coverage:** §2 schema (Task 1), §7 reroute list (Tasks 2–3), §5 archive switch + §6 refcount (Task 4). `access`, `.scratch`/`.borrowed` behavior intentionally deferred to PR3/PR4. ✓
- **Behavior-neutral:** every card is `.worktree`; archive/placement identical to today; only persistence gains two fields with a transparent migration. ✓
- **Type consistency:** `cwd: String`, `origin: CardOrigin`, memberwise `init(... cwd:, origin:)` used identically in spawn (Task 2), tests (Task 1/4). `worktree` fully removed except as a decode-only `CodingKey`.
- **Placeholder scan:** the `.scratch` archive arm is an explicit, labeled no-op (PR4), not a vague TODO. Real signatures flagged where they must be copied (encoder/decoder, fakes).
