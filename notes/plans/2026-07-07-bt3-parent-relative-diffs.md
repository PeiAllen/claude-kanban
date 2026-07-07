# BT3 — Parent-Relative Diffs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a card carries a `parentBranch`, every diff consumer (footer diffstat, both inspectors, Zed "View changes", open-notes changed set) baselines against the card's parent (merge-base vs parent) instead of the repo default branch — so the card's pill/diff shows THE CARD'S OWN WORK, not its whole stack vs main.

**Architecture:** The diff pipeline (`DiffBase.parent`, `DiffBaseline.range`, provider plumbing, both inspectors' Parent picker option) already shipped dormant. BT3 flips the *defaults*: it introduces ONE shared seam — `resolvedParentRef(task)` — mapping `Task.parentBranch` to the git ref used as baseline (plain local name today; BT6 later extends it for `refs/orch/parents/…`), then routes all four consumers through it and makes them pick `.parent` when a parent exists. Graceful nil-parent behavior stays byte-identical to today.

**Tech Stack:** Swift, swift-testing (`#expect`/`@Test`) + XCTest (iOS app tests), real-git fixtures via `Proc`.

## Global Constraints

- Merges into `plan/parent-card-branch-linking`, NOT main. Never touch main or that base branch.
- Design for BOTH Claude and Codex — no agent-specific branches; baseline selection is agent-agnostic already.
- Scope is BT3 ONLY: baseline selection. Do NOT add TreeStat logic (BT4), spawn params (BT2), or UI badges/grouping (BT4/BT7).
- Keep edits tight to baseline selection — BT4 also touches `OrchestraService+Diff`'s neighborhood; the orchestrator resolves conflicts.
- Nil-parent (`task.parentBranch == nil`) behavior must be **byte-identical to today**.
- `swift test` must pass cleanly.
- Scratch work in `./.scratch/`.

---

## File Structure

- **Create** `Sources/OrchestraCore/OrchestraService+ParentRef.swift` — the single `resolvedParentRef(_:)` seam.
- **Modify** `Sources/OrchestraCore/OrchestraService+Diff.swift` — footer stat picks `.parent` by default when parent set; `diffText`/stat resolve the ref through the seam.
- **Modify** `Sources/OrchestraCore/Launcher.swift` — thread `parentRef` through `openInZed` / `openNotes` / `changedNoteFiles` / `branchDiffDirs` / `changedMarkdown` / `mergeBase`.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — pass `resolvedParentRef(t)` into `launcher.openInZed` / `launcher.openNotes`.
- **Modify** `Sources/OrchestraCore/OrchestraService+Notes.swift` — pass `resolvedParentRef(t)` into `launcher.changedNoteFiles`.
- **Modify** `App/Views/DiffInspectorView.swift` — initial `base = .parent` when `task.parentBranch != nil`.
- **Modify** `App-iOS/Views/CardDetail/CardDetailModel.swift` — add pure `diffDefaultBaseline(parentBranch:)` helper.
- **Modify** `App-iOS/Views/CardDetail/DiffTab.swift` — seed initial `base` via `diffDefaultBaseline`.
- **Test** `Tests/OrchestraCoreTests/DiffProviderTests.swift`, `Tests/OrchestraCoreTests/DiffServiceTests.swift`, `App-iOS/Tests/IOSAppTests.swift`.

---

### Task 1: The `resolvedParentRef` seam

**Files:**
- Create: `Sources/OrchestraCore/OrchestraService+ParentRef.swift`
- Test: `Tests/OrchestraCoreTests/DiffServiceTests.swift` (covered indirectly via Task 2; no dedicated unit test — it's a one-line pure map, exercised by every consumer test)

**Interfaces:**
- Produces: `func resolvedParentRef(_ task: Task) -> String?` on `OrchestraService` (internal). Returns the git ref to diff against when the card has a parent, `nil` otherwise. Today: normalized `task.parentBranch` (nil/empty → nil).

- [ ] **Step 1: Create the seam file**

```swift
import Foundation

/// The single seam mapping a card's `Task.parentBranch` to the concrete git ref its diffs baseline
/// against (goal 1 — parent-relative diffs). Today the parent-ref string IS a local branch name, so
/// this is identity minus empty-string normalization. This is the ONE place BT6 extends to map the
/// remote form (`origin/<name>`) to its fetched private ref (`refs/orch/parents/<name>`).
///
/// Returns `nil` when the card has no parent — every consumer then falls back to the default-branch
/// baseline, keeping nil-parent behavior byte-identical to before the branch-tree feature.
extension OrchestraService {
    func resolvedParentRef(_ task: Task) -> String? {
        guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
        return pb
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: builds clean (no callers yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+ParentRef.swift
git commit -m "feat(bt3): resolvedParentRef seam mapping parentBranch to diff baseline ref"
```

---

### Task 2: Footer diffstat + inspector diffText select the parent baseline

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Diff.swift`
- Test: `Tests/OrchestraCoreTests/DiffServiceTests.swift`

**Interfaces:**
- Consumes: `resolvedParentRef(_:)` (Task 1).
- Produces: `recomputeDiffStat(_ id:, base: DiffBase? = nil)` — when `base == nil` (the report-funnel path), selects `.parent` iff the card has a resolved parent ref, else `.branch`. Explicit `base` (on-selection endpoint) is honored verbatim. `diffText` resolves its parent ref through the seam.

- [ ] **Step 1: Write the failing test — footer stat auto-selects parent baseline**

Add to `DiffServiceTests`. First add a fixture helper that builds a parent/child topology in the card's real repo (place it next to `gitInit`):

```swift
/// Turn `dir` into a real repo with topology: main(base) → parent(parent's own commit) →
/// child=HEAD(child's own commit). Sets up the card so `.parent` excludes the parent's work.
/// Returns nothing; caller sets `task.parentBranch = "parent"`.
private func gitParentChild(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func git(_ a: String...) { #expect((try? Proc.run(["git"] + a, cwd: dir))?.ok == true) }
    git("init", "-q", "-b", "main"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
    try "base\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    git("add", "-A"); git("commit", "-q", "-m", "base")
    git("checkout", "-q", "-b", "parent")
    try "base\nPARENT\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    git("commit", "-q", "-am", "parent work")
    git("checkout", "-q", "-b", "child")
    try "base\nPARENT\nCHILD\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
    git("add", "-A"); git("commit", "-q", "-m", "child work")
}
```

Then the test:

```swift
@Test("footer diffstat auto-selects the parent baseline for a card with a parent")
func footerSelectsParentBaseline() async throws {
    let env = TestEnv.make()
    let repo = TestEnv.repo(env.base)
    let t = try await env.svc.spawn(SpawnInput(prompt: "task", repo: repo, branch: "child"))
    try gitParentChild(t.cwd)
    _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }

    // No explicit base ⇒ the funnel/default path. Parent-relative ⇒ only the child's own file (b.txt).
    let s = try #require(await env.svc.recomputeDiffStat(t.id))
    #expect(s.filesChanged == 1)   // b.txt only — NOT parent's a.txt change

    // Sanity: the .branch baseline (vs main) would include the parent's work too (a.txt + b.txt).
    let branchStat = try #require(await env.svc.recomputeDiffStat(t.id, base: .branch))
    #expect(branchStat.filesChanged == 2)
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `swift test --filter footerSelectsParentBaseline 2>&1 | tail -20`
Expected: FAIL — today the default path uses `.branch`, so the first `#expect(s.filesChanged == 1)` fails (it's 2). (Also won't compile until `recomputeDiffStat` takes `base: DiffBase?` — that's fine, a compile failure is a failing test.)

- [ ] **Step 3: Make the change in `OrchestraService+Diff.swift`**

Change `recomputeDiffStat` to a parent-aware default and route both entry points through the seam:

```swift
    @discardableResult
    public func recomputeDiffStat(_ id: UUID, base: DiffBase? = nil) async -> DiffStat? {
        guard let t = await store.get(id) else { return nil }
        let ref = resolvedParentRef(t)
        let effective = base ?? (ref != nil ? .parent : .branch)   // funnel path: parent when stacked
        var newStat: DiffStat? = nil
        if t.origin == .worktree {
            do {
                try resolver.assertAllowed(t.cwd)
                newStat = try GitDiffProvider().stat(worktree: t.cwd, base: effective, parentBranch: ref)
            } catch {
                newStat = nil
            }
        }
        guard newStat != t.diffStat else { return newStat }   // no delta → no persist, no emit
        guard let saved = try? await store.update(id, { $0.diffStat = newStat }) else { return newStat }
        emit(.taskUpserted(saved))
        return newStat
    }
```

And in `diffText`, resolve the ref through the seam (behavior-preserving today):

```swift
        let text = (try? GitDiffProvider().render(worktree: t.cwd, base: base,
                                                  parentBranch: resolvedParentRef(t))) ?? ""
```

Note: `diffStat(_:base:)` endpoint keeps its `base: DiffBase = .branch` signature and still calls `recomputeDiffStat(id, base: base)` — an explicit base, honored verbatim. `scheduleDiffStat` still calls `recomputeDiffStat(id)` (base nil → parent-aware). No other changes there.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `swift test --filter footerSelectsParentBaseline 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Run the full existing diff-service suite (nil-parent unchanged)**

Run: `swift test --filter DiffServiceTests 2>&1 | tail -20`
Expected: all pass — the existing tests use no parentBranch, so the default resolves to `.branch` exactly as before.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Diff.swift Tests/OrchestraCoreTests/DiffServiceTests.swift
git commit -m "feat(bt3): footer diffstat + diffText baseline against parent when card is stacked"
```

---

### Task 3: Provider-level parent baseline correctness (triple-dot)

**Files:**
- Modify: `Tests/OrchestraCoreTests/DiffProviderTests.swift`

**Interfaces:**
- Consumes: `GitDiffProvider.stat(worktree:base:parentBranch:)` + `DiffBaseline.range` (already shipped). No production change — this task pins the merge-base (triple-dot) semantics the whole feature relies on, extending the existing `parentFallsBackToBranch` test's neighborhood.

- [ ] **Step 1: Add a parent-topology fixture helper**

Add to `DiffProviderTests` (next to `makeRepo`):

```swift
    /// `makeRepo` extended with a parent branch that has its OWN commit, then a child forked from it.
    /// Layout: main(a.txt) → parent(+p.txt) → feat=HEAD(+c.txt). Returns the repo path on `feat`.
    static func makeParentChild() throws -> String {
        let dir = try makeRepo()
        try git(dir, "checkout", "-q", "-b", "parent")
        try write(dir, "p.txt", "parent work\n")
        try git(dir, "add", "-A"); try git(dir, "commit", "-q", "-m", "parent work")
        try git(dir, "checkout", "-q", "-b", "feat")
        try write(dir, "c.txt", "child work\n")
        try git(dir, "add", "-A"); try git(dir, "commit", "-q", "-m", "child work")
        return dir
    }
```

- [ ] **Step 2: Write the failing tests**

```swift
    @Test(".parent excludes the parent's own work (merge-base baseline)")
    func parentExcludesParentWork() throws {
        let dir = try Self.makeParentChild()
        let parent = try #require(try provider.stat(worktree: dir, base: .parent, parentBranch: "parent"))
        #expect(parent.filesChanged == 1)   // c.txt only — NOT parent's p.txt
        // vs .branch (against main) which sees BOTH the parent's and the child's files.
        let branch = try #require(try provider.stat(worktree: dir, base: .branch, parentBranch: "parent"))
        #expect(branch.filesChanged == 2)
    }

    @Test("after a merge-sync the parent merge-base advances; diff still shows only the child's work")
    func mergeSyncAdvancesMergeBase() throws {
        let dir = try Self.makeParentChild()
        // Parent gains a NEW commit; child merges parent down (sync). Triple-dot: the merge-base moves
        // to include the parent's new work, so it never re-counts as the child's.
        try Self.git(dir, "checkout", "-q", "parent")
        try Self.write(dir, "p2.txt", "more parent work\n")
        try Self.git(dir, "add", "-A"); try Self.git(dir, "commit", "-q", "-m", "parent work 2")
        try Self.git(dir, "checkout", "-q", "feat")
        try Self.git(dir, "merge", "-q", "--no-edit", "parent")   // sync parent into child
        let s = try #require(try provider.stat(worktree: dir, base: .parent, parentBranch: "parent"))
        #expect(s.filesChanged == 1)   // still c.txt only; p.txt + p2.txt are the parent's, excluded
    }
```

- [ ] **Step 3: Run them**

Run: `swift test --filter DiffProviderTests 2>&1 | tail -25`
Expected: PASS (the provider pipeline already implements `.parent` merge-base; these pin it). If any fails, the merge-base semantics regressed — stop and investigate before proceeding.

- [ ] **Step 4: Commit**

```bash
git add Tests/OrchestraCoreTests/DiffProviderTests.swift
git commit -m "test(bt3): pin parent-baseline merge-base correctness incl. post-sync triple-dot"
```

---

### Task 4: Zed "View changes" + open-notes honor the parent baseline

**Files:**
- Modify: `Sources/OrchestraCore/Launcher.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`openInZed`, `openNotes` call sites)
- Modify: `Sources/OrchestraCore/OrchestraService+Notes.swift` (`changedNotes` call site)
- Test: `Tests/OrchestraCoreTests/DiffServiceTests.swift`

**Interfaces:**
- Consumes: `resolvedParentRef(_:)` (Task 1).
- Produces: Launcher gains a `parentRef: String?` argument on `openInZed(worktree:parentRef:)`, `openNotes(worktree:parentRef:)`, `changedNoteFiles(worktree:parentRef:)`; internal `branchDiffDirs`, `changedMarkdown`, `mergeBase` gain `parentRef: String?`. `mergeBase` uses the parent merge-base when `parentRef` is set (falling back to the default-branch merge-base exactly like `DiffBaseline.range(.parent)`), preserving `nil` semantics when neither resolves.

- [ ] **Step 1: Write the failing test — changedNotes baselines against parent**

Add to `DiffServiceTests` (reuses `gitParentChild` from Task 2, but with a `.md` note as the child's file). Add a note-topology fixture and test:

```swift
    /// main(a.txt) → parent(+parent.md) → child=HEAD(+child.md). Parent's note must NOT show as the
    /// child's changed note once the card baselines against its parent.
    private func gitParentChildNotes(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ a: String...) { #expect((try? Proc.run(["git"] + a, cwd: dir))?.ok == true) }
        git("init", "-q", "-b", "main"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        try "base\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "parent")
        try "# parent\n".write(toFile: dir + "/parent.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "parent note")
        git("checkout", "-q", "-b", "child")
        try "# child\n".write(toFile: dir + "/child.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "child note")
    }

    @Test("changedNotes baselines against the parent — parent's note is excluded")
    func changedNotesUsesParentBaseline() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "task", repo: repo, branch: "child"))
        try gitParentChildNotes(t.cwd)
        _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }
        let notes = try await env.svc.changedNotes(t.id)
        #expect(notes.map(\.path) == ["child.md"])   // parent.md excluded
    }
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `swift test --filter changedNotesUsesParentBaseline 2>&1 | tail -20`
Expected: FAIL — `changedNotes` currently baselines against main, so `parent.md` also appears (`["child.md", "parent.md"]` or similar).

- [ ] **Step 3: Thread `parentRef` through `Launcher.swift`**

Public entry points — add the argument and pass it down:

```swift
    public func openNotes(_ worktree: String, parentRef: String?) throws -> (opened: Int, total: Int) {
```
Inside `openNotes`, change the changed-notes call:
```swift
        let all = changedNotes(worktree: worktree, parentRef: parentRef)   // vault-relative paths
```

```swift
    public func openInZed(_ worktree: String, parentRef: String?) throws {
```
Inside `openInZed`, change the diff-dirs call:
```swift
        if let dirs = try? branchDiffDirs(worktree: worktree, parentRef: parentRef) {
```

```swift
    func changedNoteFiles(worktree: String, parentRef: String?) -> [NoteFile] {
        changedMarkdown(worktree: worktree, parentRef: parentRef).compactMap { note in
```

```swift
    func changedNotes(worktree: String, parentRef: String?) -> [String] {
        changedMarkdown(worktree: worktree, parentRef: parentRef).map { $0.path }
    }
```

```swift
    func changedMarkdown(worktree: String, parentRef: String?) -> [ChangedNote] {
        guard let base = mergeBase(worktree: worktree, parentRef: parentRef) else { return [] }
```

```swift
    func branchDiffDirs(worktree: String, parentRef: String?) throws -> (old: String, new: String)? {
        guard let base = mergeBase(worktree: worktree, parentRef: parentRef) else { return nil }
```

And `mergeBase` — parent merge-base when set, else the existing default-branch merge-base (mirrors `DiffBaseline.range(.parent)`'s fallback; `nil` only when neither resolves):

```swift
    /// The commit this branch's diff baselines against: the merge-base of HEAD and either the card's
    /// PARENT branch (stacked cards — the card's own work only) or, when there's no parent, the repo's
    /// default branch (today's behavior). A set-but-unresolvable parent (e.g. branch missing) falls
    /// back to the default-branch merge-base, exactly like `DiffBaseline.range(.parent)`. `nil` when
    /// neither resolves or git fails. Base-ref resolution is shared with the board diffstat via
    /// `DiffBaseline.defaultBaseRef`.
    private func mergeBase(worktree: String, parentRef: String?) -> String? {
        if let parentRef, !parentRef.isEmpty,
           let r = try? Proc.run(["git", "merge-base", "HEAD", parentRef], cwd: worktree), r.ok {
            let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        guard let baseRef = DiffBaseline.defaultBaseRef(worktree: worktree),
              let r = try? Proc.run(["git", "merge-base", "HEAD", baseRef], cwd: worktree), r.ok
        else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
```

- [ ] **Step 4: Update the three service call sites**

`OrchestraService.swift`:
```swift
    public func openInZed(_ id: UUID) async throws {
        let t = try await require(id)
        try launcher.openInZed(t.cwd, parentRef: resolvedParentRef(t))
    }
```
```swift
    public func openNotes(_ id: UUID) async throws -> (opened: Int, total: Int) {
        let t = try await require(id)
        return try launcher.openNotes(t.cwd, parentRef: resolvedParentRef(t))
    }
```

`OrchestraService+Notes.swift`:
```swift
        return launcher.changedNoteFiles(worktree: t.cwd, parentRef: resolvedParentRef(t))
```

- [ ] **Step 5: Run the new test + build**

Run: `swift test --filter changedNotesUsesParentBaseline 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Full OrchestraCore test run (nil-parent notes/zed unchanged)**

Run: `swift test 2>&1 | tail -25`
Expected: all pass — existing notes tests (`NotesServiceTests`) use no parentBranch, so `parentRef` is nil and `mergeBase` takes the default-branch path byte-identically.

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Launcher.swift Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Notes.swift Tests/OrchestraCoreTests/DiffServiceTests.swift
git commit -m "feat(bt3): Zed View-changes + open-notes baseline against parent when stacked"
```

---

### Task 5: Inspector picker defaults to Parent when stacked (desktop + iOS)

**Files:**
- Modify: `App-iOS/Views/CardDetail/CardDetailModel.swift`
- Modify: `App-iOS/Views/CardDetail/DiffTab.swift`
- Modify: `App/Views/DiffInspectorView.swift`
- Test: `App-iOS/Tests/IOSAppTests.swift`

**Interfaces:**
- Produces: `func diffDefaultBaseline(parentBranch: String?) -> DiffBase` (pure, public, in `CardDetailModel.swift`) — `.parent` when a parent is set, else `.branch`. Used by `DiffTab`'s initial `@State`. Desktop `DiffInspectorView` uses the equivalent inline expression in its `init`.

- [ ] **Step 1: Write the failing test for the pure helper**

Add to `IOSAppTests.swift` (next to `testDiffBaselinesGateParentOnStackedCards`):

```swift
    func testDiffDefaultBaselinePrefersParentWhenStacked() {
        // §3 Diff: a stacked card opens on Parent; a non-stacked card opens on Branch.
        XCTAssertEqual(diffDefaultBaseline(parentBranch: nil), .branch)
        XCTAssertEqual(diffDefaultBaseline(parentBranch: "main-feature"), .parent)
    }
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `swift test --filter testDiffDefaultBaselinePrefersParentWhenStacked 2>&1 | tail -15`
Expected: FAIL — `diffDefaultBaseline` doesn't exist yet.

Note: if the iOS app test target isn't part of `swift test` here, verify by typecheck per the iOS memory (`ios-unit-tests-offline-run`); the assertion still encodes the contract. Check first with `swift test --list-tests 2>/dev/null | grep -i diffBaselines` — if the existing iOS baseline test isn't listed, run the iOS test bundle per that memory instead.

- [ ] **Step 3: Add the pure helper in `CardDetailModel.swift`**

Right below `diffBaselines(parentBranch:)`:

```swift
/// The baseline a card's Diff tab opens on (design §3 Diff, BT3): **Parent** for a stacked card so it
/// shows the card's OWN work vs its parent, else **Branch** (vs the default branch). Pure so the Diff
/// tab and its tests agree on the default.
public func diffDefaultBaseline(parentBranch: String?) -> DiffBase {
    parentBranch != nil ? .parent : .branch
}
```

- [ ] **Step 4: Seed `DiffTab`'s initial base**

`DiffTab` has no explicit init today; add one that seeds `base` (other `@State` keep their declared defaults):

```swift
    init(task: Task) {
        self.task = task
        _base = State(initialValue: diffDefaultBaseline(parentBranch: task.parentBranch))
    }
```

- [ ] **Step 5: Seed `DiffInspectorView`'s initial base (desktop)**

In the existing `init(task:preview:split:)`, add the base seed alongside the other `_State` seeds:

```swift
        _base = State(initialValue: task.parentBranch != nil ? .parent : .branch)
```

- [ ] **Step 6: Run the helper test to confirm it passes**

Run: `swift test --filter testDiffDefaultBaselinePrefersParentWhenStacked 2>&1 | tail -15`
Expected: PASS (or PASS in the iOS bundle per Step 2's note).

- [ ] **Step 7: Typecheck the apps**

Run: `swift build 2>&1 | tail -5` (core) and the iOS/desktop typecheck scripts if present (`scripts/` — see `ios-app-build-and-dev-transport` memory). Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add App-iOS/Views/CardDetail/CardDetailModel.swift App-iOS/Views/CardDetail/DiffTab.swift App/Views/DiffInspectorView.swift App-iOS/Tests/IOSAppTests.swift
git commit -m "feat(bt3): inspector diff picker defaults to Parent for stacked cards (desktop + iOS)"
```

---

### Task 6: Full verification pass

- [ ] **Step 1: Run the complete test suite**

Run: `swift test 2>&1 | tail -30`
Expected: all pass, no warnings introduced by BT3 files.

- [ ] **Step 2: Confirm nil-parent byte-identity**

Grep the diff of production files and eyeball that every `nil`-parent path is unchanged (default `.branch` selection, `parentRef` nil → default-branch merge-base). Run `git diff plan/parent-card-branch-linking -- Sources/` and review.

- [ ] **Step 3: Move to review** per the owner workflow, then run `superpowers:requesting-code-review` over the diff vs `plan/parent-card-branch-linking`.

---

## Self-Review

**Spec coverage** (scope's four consumers + shared helper + tests):
1. Footer diffstat parent-relative → Task 2 ✓
2. Inspector default baseline (desktop + iOS) → Task 5 ✓
3. Zed "View changes" → Task 4 ✓
4. Open-notes changed set → Task 4 ✓
5. ONE shared `resolvedParentRef(task)` helper → Task 1, consumed by Tasks 2 & 4 ✓ (BT6 extension point documented)
6. Tests: parent diffstat excludes parent's work → Tasks 2, 3; merge-sync triple-dot → Task 3; nil-parent unchanged → Tasks 2 (Step 5), 4 (Step 6); footer stat selection unit → Task 2 ✓
7. Nil-parent byte-identical → enforced in Tasks 2/4 design + Task 6 Step 2 ✓

**Out of scope (correctly absent):** TreeStat (BT4), spawn base (BT2), UI badges/grouping (BT4/BT7).

**Type consistency:** `resolvedParentRef(_ task: Task) -> String?` used identically in Tasks 2 & 4. `recomputeDiffStat(_:base:)` signature change (`DiffBase?`) is back-compatible with the `diffStat` endpoint (passes a non-nil `DiffBase`, auto-promotes) and `scheduleDiffStat` (passes nothing → nil). `diffDefaultBaseline(parentBranch:)` name consistent between CardDetailModel + DiffTab + test.
