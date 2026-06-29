# PR3 — Freeform (Borrowed) Cards + Read-only Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a card run in an existing directory it doesn't own (`origin = .borrowed`) — a free path under the sandbox, or a repo's `main` in read-only mode — shown in a standalone freeform region, with archive never deleting the dir.

**Architecture:** Spawn gains a `borrowed` path (skips `worktrees.ensure`, sets `cwd`/`origin = .borrowed`). `Task` gains `access: CardAccess`; a `.readOnly` borrowed card launches via adapter flags built from the PR1 `ReadOnlyLaunch` recipe but keeping Orchestra hooks (it IS a tracked card). The board renders `.borrowed`/`.scratch` cards in a freeform region instead of the workflow columns. The collision badge is rescoped to `.worktree`.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, tmux, Claude Code CLI.

## Global Constraints

- Core via `swift test`, app via `scripts/build-app.sh`. (spec)
- (Agent housekeeping only — **not** a code constraint) The implementing agent's own git/commit shell commands avoid `git -C`; Orchestra's *source* may use any git invocation freely.
- **Depends on PR2** (`cwd`/`origin` exist; archive switches on `origin`) and **PR1** (`ReadOnlyLaunch`).
- Freeform region is a **standalone board region**, NOT a configurable column (no axis-1 dependency).
- Free-path cwd is trusted via the **sandbox**, not the repo allowlist — `assertAllowed` is bypassed for non-`.worktree` cards.
- `.readOnly` borrowed cards keep the Orchestra hooks `--settings` (tracked), unlike PR1's untracked shell.

---

## File Structure

- `Sources/OrchestraCore/Model.swift` (Modify) — `CardAccess` enum; `Task.access`; `SpawnInput` gains `cwd: String?` + `access`.
- `Sources/OrchestraCore/OrchestraService.swift` (Modify) — spawn branches on borrowed vs worktree; `exec` relaxes `assertAllowed` for non-`.worktree`.
- `Sources/OrchestraCore/Agents/Adapter.swift` (Modify) — `AdapterContext.access`.
- `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` (Modify) — `start`/`resume` add read-only flags when `access == .readOnly`.
- `App/BoardModel.swift` (Modify) — `worktreeSiblings` scope (done in PR2); a `freeformTasks` computed list.
- `App/Views/BoardView.swift` (Modify) — render the freeform region.
- `App/Views/CardView.swift`, `App/Views/InspectorView.swift` (Modify) — show borrowed/read-only chips; rescope the count badge.
- `App/Views/SpawnSheet.swift` (Modify) — a "Freeform (pick a directory)" mode.
- Tests under `Tests/OrchestraCoreTests/`.

---

### Task 1: `CardAccess` + `Task.access` + read-only adapter flags

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift`, `Sources/OrchestraCore/Agents/Adapter.swift`, `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Test: `Tests/OrchestraCoreTests/ReadOnlyAdapterTests.swift` (Create)

**Interfaces:**
- Produces:
  - `enum CardAccess: String, Codable, Sendable { case readWrite, readOnly }`
  - `Task.access: CardAccess` (memberwise `init` default `.readWrite`; `init(from:)` `decodeIfPresent ?? .readWrite`).
  - `AdapterContext.access: CardAccess` (default `.readWrite`).
  - `ClaudeCodeAdapter.start/resume` append, when `access == .readOnly`: `--disallowedTools Edit Write MultiEdit NotebookEdit` (reuse `ReadOnlyLaunch.argv`'s tool list). Sandbox `denyWrite` is added via a per-card read-only settings file written in `prepareToLaunch` and passed as an extra `--settings` — but hooks `--settings` stays.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OrchestraCore

final class ReadOnlyAdapterTests: XCTestCase {
    func test_start_readonly_appends_disallowed_edit_tools() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", model: "claude-opus-4-8",
                                 sessionId: "sid", name: "look", access: .readOnly)
        let argv = a.start(ctx)
        XCTAssertTrue(argv.contains("--disallowedTools"))
        for t in ["Edit", "Write", "MultiEdit", "NotebookEdit"] { XCTAssertTrue(argv.contains(t)) }
    }
    func test_start_readwrite_has_no_disallowed_tools() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", sessionId: "sid", access: .readWrite)
        XCTAssertFalse(a.start(ctx).contains("--disallowedTools"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ReadOnlyAdapterTests`
Expected: FAIL — `AdapterContext` has no `access`.

- [ ] **Step 3: Implement**
  - `Model.swift`: add `CardAccess`; add `public var access: CardAccess` to `Task`; memberwise `init` param `access: CardAccess = .readWrite`; decode `self.access = try c.decodeIfPresent(CardAccess.self, forKey: .access) ?? .readWrite`; add `access` to `CodingKeys`.
  - `Adapter.swift`: add `public let access: CardAccess` to `AdapterContext` with default `.readWrite` in the `init`.
  - `ClaudeCodeAdapter.swift`: add a helper and call it in `start` and `resume`:
    ```swift
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly
            ? ["--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit"]
            : []
    }
    ```
    In `start`: insert `argv += accessFlags(ctx.access)` after `startInFlags`. In `resume`: append `argv += accessFlags(ctx.access)`.
  - For the sandbox half, in `prepareToLaunch` write `ReadOnlyLaunch.settingsJSON(cwd: ctx.cwd, gitDir: nil)` to `"\(Config.dataDir)/readonly-card-<hash(cwd)>.json"` when `ctx.access == .readOnly`, and append `--settings <that path>` in `start`/`resume` **in addition to** the hooks settings (Claude merges multiple `--settings`; verify ordering/precedence — deny rules win regardless).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ReadOnlyAdapterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Sources/OrchestraCore/Agents Tests/OrchestraCoreTests/ReadOnlyAdapterTests.swift
git commit -m "feat(core): CardAccess + read-only adapter launch flags"
```

---

### Task 2: Spawn a borrowed card

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (`SpawnInput`), `Sources/OrchestraCore/OrchestraService.swift` (`spawn`, `exec`)
- Test: `Tests/OrchestraCoreTests/BorrowedSpawnTests.swift` (Create)

**Interfaces:**
- Consumes: `Task(cwd:origin:access:)`, `CardOrigin.borrowed`.
- Produces: `SpawnInput.cwd: String?` (+ `access: CardAccess = .readWrite`). When `cwd != nil`: skip `worktrees.ensure`, set `origin = .borrowed`, `cwd = input.cwd!`, no `repo`/`branch` worktree derivation (repo may still be set for context; branch empty allowed). Archive's `.borrowed` arm (PR2) already no-ops.

- [ ] **Step 1: Write the failing test**

```swift
final class BorrowedSpawnTests: XCTestCase {
    func test_borrowed_spawn_skips_worktree_and_never_removes_on_archive() async throws {
        let svc = makeServiceWithFakes()
        let t = try await svc.spawn(.init(cwd: "/Users/me/data", prompt: "process", access: .readWrite))
        XCTAssertEqual(t.origin, .borrowed)
        XCTAssertEqual(t.cwd, "/Users/me/data")
        XCTAssertFalse(fakeWorktrees.ensured)            // never cut a worktree
        try await svc.archive(t.id)
        XCTAssertTrue(fakeWorktrees.removed.isEmpty)     // borrowed dir untouched
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter BorrowedSpawnTests` → FAIL (`SpawnInput` has no `cwd`).

- [ ] **Step 3: Implement**
  - `SpawnInput`: add `public var cwd: String?` and `public var access: CardAccess` (default `.readWrite`) to the struct + its init.
  - `spawn(_:)`, at the top:
    ```swift
    let isBorrowed = input.cwd != nil
    let cwd: String
    if let borrowed = input.cwd {
        cwd = borrowed                                  // sandbox is the trust boundary; no allowlist gate
    } else {
        let realRepo = try resolver.resolveRepo(input.repo)
        (cwd, _) = try worktrees.ensure(repo: realRepo, branch: input.branch)
        // ... existing realRepo path continues
    }
    ```
    Build the `Task` with `cwd: cwd, origin: isBorrowed ? .borrowed : .worktree, access: input.access`. For borrowed cards `column` is unused for placement (the freeform region keys off `origin`), but set a stable value (e.g. `.impl`) to satisfy the field.
    Pass `access: input.access` into `AdapterContext`.
  - `exec(_:)`: relax the allowlist for non-worktree cards:
    ```swift
    if t.origin == .worktree { try resolver.assertAllowed(t.cwd) }
    ```

- [ ] **Step 4: Run to verify it passes** — `swift test --filter BorrowedSpawnTests` → PASS. Then `swift test` (full) → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore Tests/OrchestraCoreTests/BorrowedSpawnTests.swift
git commit -m "feat(core): spawn borrowed cards (cwd, no worktree, sandbox-trusted)"
```

---

### Task 3: Freeform region on the board

**Files:**
- Modify: `App/BoardModel.swift` (add `freeformTasks`), `App/Views/BoardView.swift` (render region)

**Interfaces:**
- Produces: `BoardModel.freeformTasks: [Task]` = `tasks.filter { $0.origin != .worktree }.sorted { $0.createdAt < $1.createdAt }`. Workflow columns filter to `$0.origin == .worktree` so freeform cards don't appear in plan/impl/review.

- [ ] **Step 1:** In `BoardModel`, add `freeformTasks`; ensure the per-column task lists add `&& $0.origin == .worktree`.

- [ ] **Step 2:** In `BoardView`, after the three workflow columns, render a freeform region (a labeled section/lane) iterating `model.freeformTasks` with the existing `CardView`. Match the column layout/styling; header e.g. "Freeform".

- [ ] **Step 3: Build app** — `scripts/build-app.sh` → builds.

- [ ] **Step 4: Manual verification** — spawn a borrowed card (Task 5 UI, or via CLI `orchestra spawn --cwd ~/data`); confirm it appears in the freeform region, not in plan/impl/review.

- [ ] **Step 5: Commit**

```bash
git add App/BoardModel.swift App/Views/BoardView.swift
git commit -m "feat(app): standalone freeform board region for non-worktree cards"
```

---

### Task 4: Card chips — borrowed path + read-only; rescope count badge

**Files:**
- Modify: `App/Views/CardView.swift` (`footer` ~`:116-129`), `App/Views/InspectorView.swift` (`TerminalHeader` ~`:142-189`)

- [ ] **Step 1:** In `CardView.footer`, when `task.origin != .worktree` show `task.cwd` (last path component) instead of `repo · branch`; add a small read-only glyph (`Image(systemName: "eye")`) when `task.access == .readOnly`. Show the worktree count badge only when `task.origin == .worktree` (it already calls `model.worktreeSiblings`, now scoped in PR2 — confirm it renders nothing for borrowed cards).

- [ ] **Step 2:** In `TerminalHeader`, render a "borrowed" chip (glyph `arrow.down.doc`) for `.borrowed`/`.scratch` cards in place of the branch chip; show a read-only chip when `.readOnly`. The `SharedWorktreeBadge` already keys off `worktreeSiblings` (scoped to `.worktree`), so it won't fire for borrowed.

- [ ] **Step 3: Build app** — `scripts/build-app.sh`; confirm chips render correctly for a borrowed RW card, a borrowed RO card, and a normal worktree card; confirm no count badge on freeform cards even when two share a cwd.

- [ ] **Step 4: Commit**

```bash
git add App/Views/CardView.swift App/Views/InspectorView.swift
git commit -m "feat(app): borrowed/read-only card chips; scope worktree badge to .worktree"
```

---

### Task 5: Spawn sheet — Freeform mode

**Files:**
- Modify: `App/Views/SpawnSheet.swift`

**Interfaces:**
- Consumes: `BoardModel.spawn(...)` / the spawn client call. Add `cwd` + `access` to whatever payload it builds (mirror PR2's `SpawnInput` additions through the control client).

- [ ] **Step 1:** Add a mode toggle: "Worktree (repo + branch)" (existing) vs "Freeform (pick a directory)". In freeform mode show a directory picker (`NSOpenPanel`, `canChooseDirectories = true`) binding to `cwd`, and a "Read-only" checkbox binding to `access`. Hide repo/branch fields in freeform mode.

- [ ] **Step 2:** On submit in freeform mode, send the spawn with `cwd` + `access` set and repo/branch empty.

- [ ] **Step 3: Build app + manual verification** — `scripts/build-app.sh`; create a freeform card via the sheet pointed at `~`; confirm it lands in the freeform region and runs there; create a read-only one pointed at a repo and confirm it cannot edit.

- [ ] **Step 4: Commit**

```bash
git add App/Views/SpawnSheet.swift
git commit -m "feat(app): freeform spawn mode (pick a dir + read-only toggle)"
```

---

## Self-Review

- **Spec coverage:** §4.1 free-path/sandbox (Task 2), §4.2 access + RO launch keeping hooks (Task 1), §4.4 standalone region (Task 3), §2 chips + §6 badge rescope (Task 4), spawn UX (Task 5). ✓
- **Dependencies honored:** reuses PR1 `ReadOnlyLaunch` tool list; builds on PR2 `cwd`/`origin`/archive switch. No axis-1 work.
- **Type consistency:** `CardAccess`, `SpawnInput.cwd/access`, `AdapterContext.access`, `CardOrigin.borrowed` consistent across tasks. `freeformTasks`/column filters both key on `origin == .worktree`.
- **Deferred:** scratch (`.scratch` lifecycle) is PR4; the `.scratch` archive arm stays a no-op until then.
