# BT7 — Board Tree UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the desktop and iOS boards, group child cards under their parent within the same column (indented by tree depth), and show a tappable parent chip on every card that has a `parentBranch`, jumping to the live parent card when one exists.

**Architecture:** The pure tree computation (in-column parent lookup, stable pre-order flatten, indent depth, cross-column parent-card lookup) lives as a new `BoardTree` enum in **OrchestraKit** — mirroring the existing `BoardNavigator` pure helper — so it is unit-testable from `Tests/OrchestraCoreTests` without touching the `@MainActor` `BoardStore`. `BoardStore` (OrchestraUI) and `BoardNavigator` become thin wrappers over `BoardTree`, keeping keyboard-nav order and visual order consistent. The two card views (`CardView`, `BoardCardCell`) gain a parent chip and read a per-card indent from the store.

**Tech Stack:** Swift 6 / SwiftUI, Swift Package Manager, XCTest. Modules: `OrchestraKit` (client-safe model + pure helpers), `OrchestraUI` (BoardStore, cross-platform), `App` (macOS SwiftUI), `App-iOS` (iOS SwiftUI).

## Global Constraints

- Design for BOTH Claude and Codex agents; no `if agent == "claude"` branches (project rule). This slice is pure UI/data over `Task` fields — no agent-specific code.
- Scope is **BT7 only**: OrchestraUI + App + App-iOS views + the `BoardTree` helper + tests. No daemon/OrchestraCore command changes (BT5 owns that surface — flag, don't make, any daemon need).
- Gate decision (owner, locked): children indent under their parent **within the same column only**. Cross-column relationships are covered by the parent chip + jump, never a connector or reorder.
- Do NOT duplicate the BT4 badges (`treeBadge` on both card views already renders `↓N` / restack). This slice adds only the parent chip + grouping/indent.
- Indent depth capped at **3** levels; ordering is cycle-safe (defensive, must never crash or drop a card).
- `parentless` column ordering must be **byte-stable vs today** (no reordering when no card has an in-column parent).
- `swift test` must pass cleanly.
- Never touch `main` or `plan/parent-card-branch-linking`; never merge.
- House git idiom: no `git -C`. Scratch in `./.scratch/`.

---

## File Structure

- **Create** `Sources/OrchestraKit/BoardTree.swift` — pure `BoardTree` enum: `inColumnParent`, `ordered`, `indent`, `parentCard`. Sole home of the tree computation. Mirrors `Sources/OrchestraKit/Keyboard/BoardNavigator.swift`.
- **Create** `Tests/OrchestraCoreTests/BoardTreeTests.swift` — unit tests for `BoardTree` (mirrors `BoardNavigatorTests.swift`).
- **Modify** `Sources/OrchestraUI/BoardStore.swift` — `cards(in:)` (~:247) delegates ordering to `BoardTree.ordered`; add `parentCard(of:)` and `treeDepth(of:)` thin wrappers next to `worktreeSiblings` (:262).
- **Modify** `Sources/OrchestraKit/Keyboard/BoardNavigator.swift` — `columnCards` (:13) delegates to `BoardTree.ordered` so keyboard-nav order matches visual order.
- **Modify** `App/Views/CardView.swift` — add `parentChip` in the footer (near the branch label, :135-164).
- **Modify** `App/Views/BoardView.swift` — apply per-card leading indent in the column `ForEach` (:133).
- **Modify** `App-iOS/Views/BoardCardCell.swift` — add `parentChip` in the footer (:71); add `@EnvironmentObject model` for the lookup.
- **Modify** `App-iOS/Views/BoardTab.swift` — apply per-card leading indent in the page `ForEach` (:173).

---

## Task 1: `BoardTree` pure helper + unit tests

**Files:**
- Create: `Sources/OrchestraKit/BoardTree.swift`
- Test: `Tests/OrchestraCoreTests/BoardTreeTests.swift`

**Interfaces:**
- Consumes: `Task` (OrchestraKit/Model.swift — fields `id`, `repo`, `branch`, `parentBranch`, `column`, `order`, `origin`, `archived`), `Column`.
- Produces:
  - `BoardTree.maxIndent: Int` (== 3)
  - `BoardTree.inColumnParent(_ cards: [Task], of child: Task) -> Task?`
  - `BoardTree.ordered(_ cards: [Task]) -> [Task]` — stable pre-order flatten
  - `BoardTree.indent(_ cards: [Task], of task: Task) -> Int` — 0…maxIndent
  - `BoardTree.parentCard(_ tasks: [Task], of task: Task) -> Task?` — cross-column active-card lookup

**Design notes (contract → behavior):**
- `inColumnParent`: first card in `cards` where `p.repo == child.repo && p.branch == child.parentBranch && p.id != child.id`. `nil` when `child.parentBranch == nil`, or the parent lives in another column / is absent from `cards`, or self-parent.
- `ordered`: if NO card in `cards` has an in-column parent, return `cards` unchanged (byte-stable). Otherwise pre-order DFS: roots (no in-column parent) in original order, each child emitted immediately after its parent, siblings in original order. `visited` set guarantees each card once; a final defensive pass emits any card left unvisited by a cycle, in original order.
- `indent`: walk `inColumnParent` upward from `task`, counting steps, capped at `maxIndent`, with a `visited` cycle-guard. Roots/parentless → 0.
- `parentCard`: first task where `!archived && origin == .worktree && repo == task.repo && branch == task.parentBranch && id != task.id`, over ALL tasks (any column). `nil` when `parentBranch == nil` or the parent is archived/absent.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/BoardTreeTests.swift`:

```swift
import XCTest
@testable import OrchestraCore

final class BoardTreeTests: XCTestCase {
    /// A worktree board card. `parent` seeds `parentBranch`; `branch` defaults to the id.
    private func card(_ id: String, _ col: Column, order: Int,
                      parent: String? = nil, branch: String? = nil,
                      repo: String = "/r", archived: Bool = false) -> Task {
        var t = Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                     title: id, repo: repo, branch: branch ?? id, cwd: "\(repo)/\(id)",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
                     order: order, status: .running, initialPrompt: id)
        t.parentBranch = parent
        t.archived = archived
        return t
    }

    // MARK: ordered — stability

    func test_ordered_parentless_is_bytestable() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1),
                  card("03", .plan, order: 2)]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.id), ts.map(\.id))
    }

    func test_ordered_parent_in_other_column_does_not_reorder() {
        // 02's parent branch is "p", but the only "p" card is in another column ⇒ 02 is a root here.
        let col = [card("01", .impl, order: 0),
                   card("02", .impl, order: 1, parent: "p")]
        XCTAssertEqual(BoardTree.ordered(col).map(\.id), col.map(\.id))
    }

    // MARK: ordered — grouping

    func test_ordered_child_follows_parent_same_column() {
        // parent "01" (branch 01) at order 0; child "03" (parent 01) at order 2; unrelated "02" at 1.
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1),
                  card("03", .plan, order: 2, parent: "01")]
        // child 03 is pulled up to directly follow its parent 01, before unrelated 02.
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "03", "02"])
    }

    func test_ordered_grandchild_nests_depth_first() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02"),
                  card("04", .plan, order: 3)]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "02", "03", "04"])
    }

    func test_ordered_siblings_keep_original_order() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "01")]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "02", "03"])
    }

    // MARK: ordered — cycle safety

    func test_ordered_cycle_emits_all_cards_once() {
        // 01 → parent 02, 02 → parent 01 (both in-column): pathological cycle.
        let ts = [card("01", .plan, order: 0, parent: "02"),
                  card("02", .plan, order: 1, parent: "01")]
        let out = BoardTree.ordered(ts)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.id)), Set(ts.map(\.id)))
    }

    // MARK: indent

    func test_indent_root_is_zero() {
        let ts = [card("01", .plan, order: 0)]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[0]), 0)
    }

    func test_indent_counts_in_column_depth() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02")]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[1]), 1)
        XCTAssertEqual(BoardTree.indent(ts, of: ts[2]), 2)
    }

    func test_indent_caps_at_max() {
        // chain 01→02→03→04→05, deeper than maxIndent (3)
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02"),
                  card("04", .plan, order: 3, parent: "03"),
                  card("05", .plan, order: 4, parent: "04")]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[4]), BoardTree.maxIndent)
    }

    func test_indent_parent_in_other_column_is_zero() {
        let ts = [card("01", .impl, order: 0, parent: "p")]  // no "p" card present
        XCTAssertEqual(BoardTree.indent(ts, of: ts[0]), 0)
    }

    func test_indent_cycle_is_bounded() {
        let ts = [card("01", .plan, order: 0, parent: "02"),
                  card("02", .plan, order: 1, parent: "01")]
        XCTAssertLessThanOrEqual(BoardTree.indent(ts, of: ts[0]), BoardTree.maxIndent)
    }

    // MARK: parentCard — cross-column lookup

    func test_parentCard_finds_live_parent_any_column() {
        let parent = card("01", .plan, order: 0)                 // branch "01"
        let child  = card("02", .impl, order: 0, parent: "01")
        XCTAssertEqual(BoardTree.parentCard([parent, child], of: child)?.id, parent.id)
    }

    func test_parentCard_nil_when_parent_archived() {
        let parent = card("01", .plan, order: 0, archived: true)
        let child  = card("02", .impl, order: 0, parent: "01")
        XCTAssertNil(BoardTree.parentCard([parent, child], of: child))
    }

    func test_parentCard_nil_when_no_parentBranch() {
        let child = card("02", .impl, order: 0)
        XCTAssertNil(BoardTree.parentCard([child], of: child))
    }

    func test_parentCard_nil_when_no_matching_branch() {
        let child = card("02", .impl, order: 0, parent: "ghost")
        XCTAssertNil(BoardTree.parentCard([child], of: child))
    }

    func test_parentCard_respects_repo() {
        // Same branch name in a different repo must not match.
        let other = card("01", .plan, order: 0, repo: "/other")
        let child = card("02", .impl, order: 0, parent: "01", repo: "/r")
        XCTAssertNil(BoardTree.parentCard([other, child], of: child))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BoardTreeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'BoardTree' in scope` (type doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Sources/OrchestraKit/BoardTree.swift`:

```swift
import Foundation

/// Pure branch-tree layout for the board — no UI, no daemon, fully unit-testable. Mirrors
/// `BoardNavigator`: it operates on the same `[Task]` the board draws. Children indent under
/// their parent **within the same column only** (owner gate); cross-column parent relationships
/// are surfaced by the parent chip + `parentCard(of:)` jump, never a reorder or connector.
public enum BoardTree {
    /// Maximum indent level for nested children (the chip/indent stays legible on narrow cards).
    public static let maxIndent = 3

    /// The card in `cards` that owns `child`'s parent branch (same repo, `branch == parentBranch`),
    /// or nil when the child is parentless, self-parented, or its parent lives outside this column.
    public static func inColumnParent(_ cards: [Task], of child: Task) -> Task? {
        guard let parent = child.parentBranch else { return nil }
        return cards.first { $0.id != child.id && $0.repo == child.repo && $0.branch == parent }
    }

    /// One column's cards, flattened depth-first so each child directly follows its parent. Roots
    /// (no in-column parent) keep their incoming order; siblings keep theirs. When no card has an
    /// in-column parent the input is returned unchanged (byte-stable vs today). Cycle-safe: a
    /// `visited` set emits every card exactly once, and a defensive final pass sweeps any card a
    /// parent-cycle left unreached.
    public static func ordered(_ cards: [Task]) -> [Task] {
        var childrenOf: [UUID: [Task]] = [:]
        var hasParent: Set<UUID> = []
        for c in cards {
            if let p = inColumnParent(cards, of: c) {
                childrenOf[p.id, default: []].append(c)
                hasParent.insert(c.id)
            }
        }
        if hasParent.isEmpty { return cards }

        var result: [Task] = []
        result.reserveCapacity(cards.count)
        var visited: Set<UUID> = []
        func visit(_ c: Task) {
            guard visited.insert(c.id).inserted else { return }
            result.append(c)
            for child in childrenOf[c.id] ?? [] { visit(child) }
        }
        for c in cards where !hasParent.contains(c.id) { visit(c) }  // roots, original order
        for c in cards { visit(c) }                                  // defensive: cycles / orphans
        return result
    }

    /// Indent level of `task` within its column tree — the number of in-column ancestors, capped at
    /// `maxIndent`. Roots and parentless cards are 0. Cycle-safe (a `visited` set bounds the walk).
    public static func indent(_ cards: [Task], of task: Task) -> Int {
        var depth = 0
        var current = task
        var visited: Set<UUID> = [task.id]
        while let parent = inColumnParent(cards, of: current) {
            guard visited.insert(parent.id).inserted else { break }
            depth += 1
            if depth >= maxIndent { break }
            current = parent
        }
        return min(depth, maxIndent)
    }

    /// The live card to jump to for `task`'s parent branch: an active (non-archived) worktree card
    /// in the same repo whose branch is `task.parentBranch`, across ANY column. Nil when the card
    /// has no parent branch or no live card owns it (bare/archived parent ⇒ chip is a no-op).
    public static func parentCard(_ tasks: [Task], of task: Task) -> Task? {
        guard let parent = task.parentBranch else { return nil }
        return tasks.first {
            !$0.archived && $0.origin == .worktree && $0.id != task.id
                && $0.repo == task.repo && $0.branch == parent
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BoardTreeTests 2>&1 | tail -20`
Expected: PASS — all `BoardTreeTests` green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraKit/BoardTree.swift Tests/OrchestraCoreTests/BoardTreeTests.swift
git commit -m "feat(bt7): BoardTree pure helper — in-column grouping, indent, parent lookup"
```

---

## Task 2: Wire `BoardStore` + `BoardNavigator` to `BoardTree`

**Files:**
- Modify: `Sources/OrchestraUI/BoardStore.swift:247` (`cards(in:)`) and near `:262` (add helpers)
- Modify: `Sources/OrchestraKit/Keyboard/BoardNavigator.swift:13` (`columnCards`)

**Interfaces:**
- Consumes: `BoardTree.ordered`, `BoardTree.parentCard`, `BoardTree.indent` (Task 1).
- Produces:
  - `BoardStore.cards(in: Column) -> [Task]` — now tree-ordered (same filter, delegated sort+flatten)
  - `BoardStore.parentCard(of: Task) -> Task?`
  - `BoardStore.treeDepth(of: Task) -> Int`
  - `BoardNavigator.columnCards` order now matches `cards(in:)`

**Note on tests:** the store methods are thin, `@MainActor`, and covered transitively by Task 1's `BoardTree` tests (the real logic). Existing `BoardNavigatorTests` (parentless fixtures) must still pass — they exercise the byte-stable path.

- [ ] **Step 1: Update `cards(in:)` to delegate ordering**

In `Sources/OrchestraUI/BoardStore.swift`, replace the `cards(in:)` body (:247):

```swift
    public func cards(in column: Column) -> [Task] {
        BoardTree.ordered(
            tasks.filter { $0.column == column && !$0.archived && $0.origin == .worktree }
                 .sorted { $0.order < $1.order })
    }
```

- [ ] **Step 2: Add `parentCard(of:)` and `treeDepth(of:)` next to `worktreeSiblings`**

In `Sources/OrchestraUI/BoardStore.swift`, after `worktreeSiblingsHelp(of:)` (~:273), add:

```swift
    /// The live card on this card's parent branch (same repo, active worktree card), or nil when the
    /// card is unparented or its parent branch has no live card. Drives the card's parent chip +
    /// jump-to-parent. Pure `Task`-data lookup — see `BoardTree.parentCard`.
    public func parentCard(of task: Task) -> Task? {
        BoardTree.parentCard(tasks, of: task)
    }

    /// Indent level of `task` within its column's branch tree (0 for roots), capped at
    /// `BoardTree.maxIndent`. The card views multiply this by a per-surface step for the leading inset.
    public func treeDepth(of task: Task) -> Int {
        BoardTree.indent(
            tasks.filter { $0.column == task.column && !$0.archived && $0.origin == .worktree }
                 .sorted { $0.order < $1.order },
            of: task)
    }
```

- [ ] **Step 3: Update `BoardNavigator.columnCards` to match visual order**

In `Sources/OrchestraKit/Keyboard/BoardNavigator.swift`, replace `columnCards` (:13):

```swift
    /// The board cards in a column, in display order (matches `BoardModel.cards(in:)`) — tree-grouped
    /// so keyboard `hjkl` walks the same order the board draws.
    public static func columnCards(_ tasks: [Task], _ col: Column) -> [Task] {
        BoardTree.ordered(
            tasks.filter { $0.column == col && !$0.archived && $0.origin == .worktree }
                 .sorted { $0.order < $1.order })
    }
```

- [ ] **Step 4: Build + run the full unit suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; all tests pass (Task 1 tests + existing `BoardNavigatorTests` still green via the byte-stable path).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraUI/BoardStore.swift Sources/OrchestraKit/Keyboard/BoardNavigator.swift
git commit -m "feat(bt7): tree-order cards(in:) + keyboard nav; add parentCard/treeDepth store helpers"
```

---

## Task 3: Desktop parent chip + indent

**Files:**
- Modify: `App/Views/CardView.swift` (footer :135-164; add `parentChip`)
- Modify: `App/Views/BoardView.swift:133` (column `ForEach` — leading indent)

**Interfaces:**
- Consumes: `model.parentCard(of:)`, `model.treeDepth(of:)`, `model.selectAndEnterTerminal(_:)` (existing).
- Produces: visual only — no new public API.

**Note:** UI polish beyond logic is verified by the orchestrator later (orch-ui-shot). This task wires the affordance; it is not unit-tested (SwiftUI view code). Verify it **compiles** via `swift build`.

- [ ] **Step 1: Add the `parentChip` view to `CardView`**

In `App/Views/CardView.swift`, add after `worktreeBadge` (~:178), before `treeBadge`:

```swift
    /// Parent-branch chip: shows `⤴ <parent>` whenever the card has a parent branch. Clicking jumps to
    /// the live parent card (select + enter its terminal); a no-op with an explanatory tooltip when no
    /// live card owns that branch. Reads `Task` + the store's derived lookup — no new plumbing.
    @ViewBuilder private var parentChip: some View {
        if let parent = task.parentBranch {
            let target = model.parentCard(of: task)
            Button {
                if let target { model.selectAndEnterTerminal(target.id) }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.turn.left.up").font(F.ui(8))
                    Text(parent).font(F.mono(9.5)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(target != nil ? theme.accent : theme.text3)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule(style: .continuous).fill(theme.chip))
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            .frame(maxWidth: 120, alignment: .leading)
            .help(target != nil
                  ? "Jump to parent card on \(parent)"
                  : "No card on parent branch \(parent)")
        }
    }
```

- [ ] **Step 2: Render `parentChip` in the footer**

In `App/Views/CardView.swift`, in the `footer` HStack (:157-158), insert the chip after the read-only eye and before `worktreeBadge`:

```swift
            if task.access == .readOnly {
                Image(systemName: "eye")
                    .font(F.ui(9))
                    .foregroundStyle(theme.text3)
                    .help("Read-only")
            }
            parentChip
            worktreeBadge
            treeBadge
```

- [ ] **Step 3: Apply the per-card indent in the column**

In `App/Views/BoardView.swift`, in `content`'s `ForEach` (:133-136):

```swift
                        ForEach(cards) { task in
                            CardView(task: task)
                                .id(task.id)
                                .padding(.leading, CGFloat(model.treeDepth(of: task)) * 14)
                                .draggable(task.id.uuidString)
                        }
```

- [ ] **Step 4: Build the macOS app target**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds (view code compiles; `App` builds via `scripts/build-app.sh` are heavier — a package build proves the OrchestraUI/Kit surface; App view compile is confirmed in Task 5's app build).

- [ ] **Step 5: Commit**

```bash
git add App/Views/CardView.swift App/Views/BoardView.swift
git commit -m "feat(bt7): desktop parent chip + same-column tree indent"
```

---

## Task 4: iOS parent chip + indent

**Files:**
- Modify: `App-iOS/Views/BoardCardCell.swift` (footer :71; add `parentChip` + `@EnvironmentObject model`)
- Modify: `App-iOS/Views/BoardTab.swift:173` (page `ForEach` — leading indent)

**Interfaces:**
- Consumes: `model.parentCard(of:)`, `model.treeDepth(of:)`, `model.selectedId` (existing; setting it pushes the detail per `selectedCardBinding`).
- Produces: visual only.

- [ ] **Step 1: Give `BoardCardCell` access to the model**

In `App-iOS/Views/BoardCardCell.swift`, add the env object under the existing `task`/`theme` (:10-11):

```swift
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
```

- [ ] **Step 2: Add the `parentChip` view**

In `App-iOS/Views/BoardCardCell.swift`, add after `treeBadge` (~:105):

```swift
    /// Parent-branch chip: `⤴ <parent>` when the card has a parent branch. Tapping navigates to the
    /// live parent card's detail (sets `selectedId`); a no-op when no live card owns the branch.
    @ViewBuilder private var parentChip: some View {
        if let parent = task.parentBranch {
            let target = model.parentCard(of: task)
            Button {
                if let target { model.selectedId = target.id }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.turn.left.up")
                    Text(parent).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(target != nil ? theme.accent : theme.text3)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            .frame(maxWidth: 130, alignment: .leading)
        }
    }
```

- [ ] **Step 3: Render `parentChip` in the footer**

In `App-iOS/Views/BoardCardCell.swift`, in the `footer` HStack (:73-82), insert after `treeBadge`:

```swift
            Text(pathLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            treeBadge
            parentChip
            Spacer(minLength: 6)
```

- [ ] **Step 4: Apply the per-card indent in the page list**

In `App-iOS/Views/BoardTab.swift`, in `BoardPageView`'s `ForEach` (:173):

```swift
                        ForEach(cards) { task in
                            MovableCard(task: task)
                                .padding(.leading, CGFloat(model.treeDepth(of: task)) * 16)
                        }
```

- [ ] **Step 5: Typecheck the iOS surface**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds. (The OrchestraUI/Kit code the iOS views consume compiles cross-platform; the iOS app view compile is confirmed by the iOS typecheck script in Task 5 if available, else by the orchestrator's later build.)

- [ ] **Step 6: Commit**

```bash
git add App-iOS/Views/BoardCardCell.swift App-iOS/Views/BoardTab.swift
git commit -m "feat(bt7): iOS parent chip + same-column tree indent"
```

---

## Task 5: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full package build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -25`
Expected: build clean; all tests pass (BoardTreeTests + BoardNavigatorTests + the rest).

- [ ] **Step 2: iOS view typecheck (if a script exists)**

Run: `ls scripts/ | grep -i "typecheck\|ios" ` then run the iOS typecheck script if present (e.g. `scripts/typecheck-kit-ios.sh`) to confirm the App-iOS views compile against the iOS SDK.
Expected: typecheck passes. If no script covers App-iOS view compilation, note that the orchestrator's App-iOS build is the gate and record it in the summary.

- [ ] **Step 3: Confirm no daemon/OrchestraCore command surface was touched**

Run: `git diff --stat plan/parent-card-branch-linking -- Sources/OrchestraCore Sources/orchestrad Sources/OrchestraKit/CommandCatalog.swift`
Expected: empty (BT7 must not collide with BT5's daemon surface). `Sources/OrchestraKit/BoardTree.swift` + `Keyboard/BoardNavigator.swift` are the only Kit changes.

---

## Self-Review

**Spec coverage (04-tests.md + 02-contract §UI affordances + 03 §10):**
- BoardStore grouping — child ordered after parent in same column with depth → Task 1 `test_ordered_child_follows_parent_same_column`, `test_ordered_grandchild_nests_depth_first`; depth via `test_indent_*`. ✓
- parentless ordering byte-stable vs today → `test_ordered_parentless_is_bytestable`. ✓
- parent in another column ⇒ no reorder, chip-only → `test_ordered_parent_in_other_column_does_not_reorder` + `test_indent_parent_in_other_column_is_zero` + chip driven by cross-column `parentCard`. ✓
- cycle-safe depth (defensive cap) → `test_ordered_cycle_emits_all_cards_once`, `test_indent_cycle_is_bounded`, `test_indent_caps_at_max`. ✓
- `parentCard(of:)` incl. archived-parent ⇒ nil → `test_parentCard_nil_when_parent_archived` (+ no-branch, no-match, repo-scoped). ✓
- Desktop chip + jump + indent → Task 3. iOS chip + navigate + indent → Task 4. ✓
- No BT4 badge duplication → chip is a distinct affordance; `treeBadge` untouched. ✓

**Placeholder scan:** none — every code step shows complete code.

**Type consistency:** `BoardTree.ordered/indent/parentCard/inColumnParent/maxIndent` used identically across Tasks 1–4. Store wrappers `parentCard(of:)`/`treeDepth(of:)` match their call sites in Tasks 3–4. `selectAndEnterTerminal` (desktop) / `selectedId` (iOS) are existing APIs confirmed in the views.

**Open flag for the summary:** if `swift build` cannot compile the `App`/`App-iOS` SwiftUI targets in this environment (they build via Xcode/`scripts/build-app.sh`), the view-code changes are gated by the orchestrator's later app build + orch-ui-shot; the package (`OrchestraUI`+`OrchestraKit`+tests) build/test is the in-scope automated gate here.
```
