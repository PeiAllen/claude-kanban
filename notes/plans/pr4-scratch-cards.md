# PR4 — Scratch Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ephemeral "scratch" freeform cards — Orchestra creates a fresh throwaway dir (`~/.orchestra/scratch/<id>`), the agent works there, and the dir is `rm -rf`'d when the card is archived. Plus a startup sweep for orphans.

**Architecture:** A "Scratch" spawn path mkdir's `Config.scratchRoot/<id>`, sets `cwd` + `origin = .scratch`. The archive `.scratch` arm (a no-op since PR2) now deletes the dir unconditionally, guarded by an under-scratch-root assertion. The daemon removes orphaned scratch dirs (no matching live card) on start.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, FileManager.

## Global Constraints

- Core via `swift test`, app via `scripts/build-app.sh`. (spec)
- (Agent housekeeping only — **not** a code constraint) The implementing agent's own git/commit shell commands avoid `git -C`; Orchestra's *source* may use any git invocation freely.
- **Depends on PR2** (`origin`/archive switch) and **PR3** (freeform region + spawn mode + `SpawnInput`).
- Scratch dirs are **truly ephemeral** — deleted on archive, unconditionally (no dirty-guard); the user moves out anything useful first.
- Each scratch dir is per-`id` (`~/.orchestra/scratch/<id>`) — never shared, so no refcount.
- The destructive `rm -rf` is gated on `origin == .scratch` **and** an assertion that the path is under `Config.scratchRoot`.

---

## File Structure

- `Sources/OrchestraCore/Config.swift` (Modify) — add `scratchRoot`.
- `Sources/OrchestraCore/OrchestraService.swift` (Modify) — scratch spawn branch; `.scratch` archive arm; orphan sweep.
- `Sources/OrchestraCore/OrchestraService+Recovery.swift` (Modify) — call the orphan sweep at startup.
- `App/Views/SpawnSheet.swift` (Modify) — a "Scratch" choice.
- Tests under `Tests/OrchestraCoreTests/`.

---

### Task 1: `Config.scratchRoot`

**Files:**
- Modify: `Sources/OrchestraCore/Config.swift` (near `defaultWorktreesRoot` ~`:54`)
- Test: `Tests/OrchestraCoreTests/ScratchPathTests.swift` (Create)

**Interfaces:**
- Produces: `static var scratchRoot: String { "\(home)/.orchestra/scratch" }` and `static func scratchDir(_ id: UUID) -> String { "\(scratchRoot)/\(id.uuidString.lowercased())" }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OrchestraCore

final class ScratchPathTests: XCTestCase {
    func test_scratchDir_is_under_scratchRoot_keyed_by_id() {
        let id = UUID()
        let dir = Config.scratchDir(id)
        XCTAssertTrue(dir.hasPrefix(Config.scratchRoot + "/"))
        XCTAssertTrue(dir.hasSuffix(id.uuidString.lowercased()))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ScratchPathTests` → FAIL ("no member 'scratchRoot'").

- [ ] **Step 3: Implement** — in `Config`:

```swift
public static var scratchRoot: String { "\(home)/.orchestra/scratch" }
public static func scratchDir(_ id: UUID) -> String { "\(scratchRoot)/\(id.uuidString.lowercased())" }
```

- [ ] **Step 4: Run to verify it passes** — `swift test --filter ScratchPathTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Config.swift Tests/OrchestraCoreTests/ScratchPathTests.swift
git commit -m "feat(core): Config.scratchRoot + scratchDir(id)"
```

---

### Task 2: Spawn a scratch card

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (`SpawnInput`), `Sources/OrchestraCore/OrchestraService.swift` (`spawn`)
- Test: `Tests/OrchestraCoreTests/ScratchSpawnTests.swift` (Create)

**Interfaces:**
- Consumes: `Config.scratchDir`, `Task(cwd:origin:)`.
- Produces: `SpawnInput.scratch: Bool` (default false). When true: `let dir = Config.scratchDir(id)` (the card id, generated before the Task), `mkdir -p` it, set `cwd = dir`, `origin = .scratch`. Takes precedence over `cwd`/worktree branches.

- [ ] **Step 1: Write the failing test**

```swift
final class ScratchSpawnTests: XCTestCase {
    func test_scratch_spawn_creates_dir_and_marks_origin_scratch() async throws {
        let svc = makeServiceWithFakes()
        let t = try await svc.spawn(.init(scratch: true, prompt: "mess around"))
        XCTAssertEqual(t.origin, .scratch)
        XCTAssertEqual(t.cwd, Config.scratchDir(t.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.cwd))
        try? FileManager.default.removeItem(atPath: t.cwd)   // cleanup
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ScratchSpawnTests` → FAIL (`SpawnInput` has no `scratch`).

- [ ] **Step 3: Implement**
  - `SpawnInput`: add `public var scratch: Bool` (default false) to struct + init.
  - `spawn(_:)`: generate the id up front (`let id = UUID()`) so the scratch path can use it; add the branch **before** the borrowed/worktree branches:
    ```swift
    let cwd: String
    let origin: CardOrigin
    if input.scratch {
        cwd = Config.scratchDir(id)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        origin = .scratch
    } else if let borrowed = input.cwd {
        cwd = borrowed; origin = .borrowed
    } else {
        let realRepo = try resolver.resolveRepo(input.repo)
        (cwd, _) = try worktrees.ensure(repo: realRepo, branch: input.branch)
        origin = .worktree
    }
    ```
    Pass `id: id` into the `Task(...)` initializer so the dir and card share an id.

- [ ] **Step 4: Run to verify it passes** — `swift test --filter ScratchSpawnTests` → PASS; then `swift test` (full) → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore Tests/OrchestraCoreTests/ScratchSpawnTests.swift
git commit -m "feat(core): spawn scratch cards (mkdir ~/.orchestra/scratch/<id>)"
```

---

### Task 3: Archive deletes the scratch dir

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`archive` — the `.scratch` arm)
- Test: `Tests/OrchestraCoreTests/ScratchArchiveTests.swift` (Create)

**Interfaces:**
- Consumes: `Task.origin == .scratch`, `Task.cwd`, `Config.scratchRoot`.

- [ ] **Step 1: Write the failing test**

```swift
final class ScratchArchiveTests: XCTestCase {
    func test_archiving_scratch_card_rm_rfs_its_dir() async throws {
        let svc = makeServiceWithFakes()
        let t = try await svc.spawn(.init(scratch: true, prompt: "x"))
        let marker = "\(t.cwd)/note.txt"
        try "keep?".write(toFile: marker, atomically: true, encoding: .utf8)
        try await svc.archive(t.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.cwd))   // unconditional, even non-empty
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ScratchArchiveTests` → FAIL (the `.scratch` arm is still the PR2 no-op).

- [ ] **Step 3: Implement** — replace the `.scratch` arm in the archive switch:

```swift
case .scratch:
    assert(t.cwd.hasPrefix(Config.scratchRoot + "/"))   // never rm -rf outside the scratch root
    if t.cwd.hasPrefix(Config.scratchRoot + "/") {
        try? FileManager.default.removeItem(atPath: t.cwd)
    }
```

> Keep both the `assert` (debug catch) and the runtime `if` (release-safe guard) — a destructive op must not depend on assertions being enabled.

- [ ] **Step 4: Run to verify it passes** — `swift test --filter ScratchArchiveTests` → PASS; then `swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/ScratchArchiveTests.swift
git commit -m "feat(core): archive rm -rf's scratch dirs (guarded by scratch root)"
```

---

### Task 4: Startup orphan sweep

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `sweepOrphanScratch`), `Sources/OrchestraCore/OrchestraService+Recovery.swift` (call it during `recoverSessions`/startup)
- Test: `Tests/OrchestraCoreTests/ScratchSweepTests.swift` (Create)

**Interfaces:**
- Produces: `func sweepOrphanScratch() async` — lists `Config.scratchRoot` subdirs; removes any whose dir name (a UUID) has no matching non-archived live `Task` with `origin == .scratch`.

- [ ] **Step 1: Write the failing test**

```swift
final class ScratchSweepTests: XCTestCase {
    func test_sweep_removes_dirs_with_no_live_card() async throws {
        let svc = makeServiceWithFakes()
        let orphan = Config.scratchDir(UUID())
        try FileManager.default.createDirectory(atPath: orphan, withIntermediateDirectories: true)
        let live = try await svc.spawn(.init(scratch: true, prompt: "x"))   // has a card
        await svc.sweepOrphanScratch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan))      // orphan gone
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.cwd))     // live kept
        try? FileManager.default.removeItem(atPath: live.cwd)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ScratchSweepTests` → FAIL ("no member 'sweepOrphanScratch'").

- [ ] **Step 3: Implement**

```swift
public func sweepOrphanScratch() async {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: Config.scratchRoot) else { return }
    let liveScratchDirs = Set(await store.all()
        .filter { $0.origin == .scratch && !$0.archived }
        .map { $0.cwd })
    for name in entries {
        let path = "\(Config.scratchRoot)/\(name)"
        if !liveScratchDirs.contains(path) { try? fm.removeItem(atPath: path) }
    }
}
```

Call `await sweepOrphanScratch()` once during startup (in `recoverSessions` or wherever the daemon boots the service — match the existing startup sequence).

- [ ] **Step 4: Run to verify it passes** — `swift test --filter ScratchSweepTests` → PASS; then `swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore Tests/OrchestraCoreTests/ScratchSweepTests.swift
git commit -m "feat(core): sweep orphan scratch dirs on startup"
```

---

### Task 5: Spawn sheet — Scratch choice

**Files:**
- Modify: `App/Views/SpawnSheet.swift`

**Interfaces:**
- Consumes: the spawn client payload (add `scratch: true`). Mirror PR3's freeform-mode wiring.

- [ ] **Step 1:** Add a third spawn mode / button: "Scratch (throwaway dir)". It needs no path/repo input — just a prompt (optional). On submit, send the spawn with `scratch: true`.

- [ ] **Step 2: Build app + manual verification** — `scripts/build-app.sh`; create a scratch card; confirm it lands in the freeform region, `~/.orchestra/scratch/<id>` exists, the agent can write there; make a file, archive the card, confirm the dir is gone.

- [ ] **Step 3: Commit**

```bash
git add App/Views/SpawnSheet.swift
git commit -m "feat(app): scratch spawn option"
```

---

## Self-Review

- **Spec coverage:** §4.1 scratch convenience (Tasks 1–2, 5), §4.3 unconditional delete-on-archive (Task 3), §4.3 orphan sweep (Task 4). ✓
- **Safety:** the `rm -rf` is double-gated — `origin == .scratch` (switch arm) **and** a runtime under-`scratchRoot` prefix check (not just an `assert`). Per-id dirs ⇒ no refcount needed. ✓
- **Type consistency:** `SpawnInput.scratch`, `Config.scratchRoot`/`scratchDir`, `CardOrigin.scratch`, `sweepOrphanScratch` consistent across tasks and matching PR2/PR3 names.
- **Placeholder scan:** startup call site flagged to "match the existing boot sequence" — a real wiring point, not a vague TODO.
