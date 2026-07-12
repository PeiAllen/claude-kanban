# Card Navigation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Vim-mode `Ctrl-O`/`Ctrl-I` browser-style card history that works from board and terminal contexts without changing the active mode.

**Architecture:** A pure `CardNavigationHistory` cursor records every desktop selection through a new `BoardStore` selection-change hook. The pure Vim keymap emits history intents, and `KeyboardController` asks `BoardUX` to traverse while preserving board focus or reusing the existing terminal-entry path.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest, Swift Package Manager

## Global Constraints

- Record every non-nil card selection regardless of source.
- Use browser semantics: duplicate suppression, back/forward traversal, and forward truncation after a new selection.
- Skip removed cards; archived cards remain valid while still present in `archived`.
- Keep history session-local.
- Bind shortcuts only in Vim mode and only in board/terminal contexts.
- Terminal traversal lands in the destination card's agent terminal; board traversal stays on the board.

---

## File map

- `Sources/OrchestraUI/CardNavigationHistory.swift` — pure UUID history and cursor.
- `Sources/OrchestraUI/BoardStore.swift` — shared selection-change observation seam.
- `Sources/OrchestraUI/BoardUX.swift` — desktop recording, traversal, and focus preservation.
- `Sources/OrchestraKit/Keyboard/KeyChord.swift` — new resolved keyboard intents.
- `Sources/OrchestraCore/Keyboard/Keybindings.swift` — Vim chord-to-intent mapping.
- `App/KeyboardController.swift` — execute history intents using the derived context.
- `Tests/OrchestraUITests/CardNavigationHistoryTests.swift` — pure cursor tests.
- `Tests/OrchestraUITests/BoardModelPlatformTests.swift` — integration and focus tests.
- `Tests/OrchestraCoreTests/KeybindingsTests.swift` — context/keymap tests.
- `App/Views/KeyboardHelpView.swift`, `docs/07-app-ui.md`, `scripts/orch-key-demo.sh` — discoverability and real-event harness coverage.

### Task 1: Pure browser-style card history

**Files:**
- Create: `Sources/OrchestraUI/CardNavigationHistory.swift`
- Create: `Tests/OrchestraUITests/CardNavigationHistoryTests.swift`

**Interfaces:**
- Consumes: `Foundation.UUID`
- Produces: internal `CardNavigationHistory.record(_:)`, `back(validIds:)`, and `forward(validIds:)`

- [ ] **Step 1: Write failing pure-history tests**

```swift
import XCTest
@testable import OrchestraUI

final class CardNavigationHistoryTests: XCTestCase {
    func testBackAndForwardUseBrowserOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        let valid = Set([a, b, c])

        XCTAssertEqual(history.back(validIds: valid), b)
        XCTAssertEqual(history.back(validIds: valid), a)
        XCTAssertNil(history.back(validIds: valid))
        XCTAssertEqual(history.forward(validIds: valid), b)
        XCTAssertEqual(history.forward(validIds: valid), c)
        XCTAssertNil(history.forward(validIds: valid))
    }

    func testDuplicateCurrentSelectionIsIgnored() {
        let a = UUID(), b = UUID()
        var history = CardNavigationHistory()
        history.record(a); history.record(b); history.record(b)
        XCTAssertEqual(history.back(validIds: Set([a, b])), a)
    }

    func testNewVisitAfterBackTruncatesForwardBranch() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        XCTAssertEqual(history.back(validIds: Set([a, b, c, d])), b)
        history.record(d)
        XCTAssertNil(history.forward(validIds: Set([a, b, c, d])))
        XCTAssertEqual(history.back(validIds: Set([a, b, c, d])), b)
    }

    func testTraversalSkipsRemovedCards() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        XCTAssertEqual(history.back(validIds: Set([a, c])), a)
        XCTAssertEqual(history.forward(validIds: Set([a, c])), c)
    }
}
```

- [ ] **Step 2: Run the tests and confirm RED**

Run: `swift test --filter CardNavigationHistoryTests`

Expected: compilation fails because `CardNavigationHistory` does not exist.

- [ ] **Step 3: Implement the minimal pure cursor**

```swift
import Foundation

struct CardNavigationHistory {
    private var entries: [UUID] = []
    private var cursor: Int?

    mutating func record(_ id: UUID) {
        if let cursor, entries[cursor] == id { return }
        if let cursor, cursor + 1 < entries.count {
            entries.removeSubrange((cursor + 1)..<entries.count)
        }
        entries.append(id)
        cursor = entries.count - 1
    }

    mutating func back(validIds: Set<UUID>) -> UUID? { move(by: -1, validIds: validIds) }
    mutating func forward(validIds: Set<UUID>) -> UUID? { move(by: 1, validIds: validIds) }

    private mutating func move(by step: Int, validIds: Set<UUID>) -> UUID? {
        guard let cursor else { return nil }
        var candidate = cursor + step
        while entries.indices.contains(candidate) {
            if validIds.contains(entries[candidate]) {
                self.cursor = candidate
                return entries[candidate]
            }
            candidate += step
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests and confirm GREEN**

Run: `swift test --filter CardNavigationHistoryTests`

Expected: four tests pass.

- [ ] **Step 5: Commit the pure history unit**

```bash
git add Sources/OrchestraUI/CardNavigationHistory.swift Tests/OrchestraUITests/CardNavigationHistoryTests.swift
git commit -m "feat(ui): add card navigation history cursor"
```

### Task 2: Record all selections and preserve focus during traversal

**Files:**
- Modify: `Sources/OrchestraUI/BoardStore.swift`
- Modify: `Sources/OrchestraUI/BoardUX.swift`
- Modify: `Tests/OrchestraUITests/BoardModelPlatformTests.swift`

**Interfaces:**
- Consumes: `CardNavigationHistory`, `BoardStore.selectedId`, `BoardUX.selectAndEnterTerminal(_:)`
- Produces: `BoardStore.onSelectionChanged(from:to:)`, `BoardUX.navigateCardHistoryBack(fromTerminal:)`, and `BoardUX.navigateCardHistoryForward(fromTerminal:)`

- [ ] **Step 1: Write failing BoardUX integration tests**

Add a helper that creates distinct tasks, then add the integration tests:

```swift
private func makeCard(_ title: String) -> Task {
    Task(title: title, repo: "/repo", branch: "feat/\(title.lowercased())",
         cwd: "/repo/.worktrees/\(title.lowercased())", model: AgentModel(id: "claude-opus-4-8"),
         startIn: .plan, column: .plan, order: 0, initialPrompt: title)
}

func testCardHistoryRecordsEverySelectedIdTransitionAndDoesNotSelfRecord() {
    let (model, _, _, _) = makeModel()
    let a = makeCard("A"), b = makeCard("B"), c = makeCard("C")
    model.tasks = [a, b, c]
    model.selectedId = a.id
    model.selectedId = b.id
    model.selectedId = c.id

    model.navigateCardHistoryBack(fromTerminal: false)
    XCTAssertEqual(model.selectedId, b.id)
    model.navigateCardHistoryBack(fromTerminal: false)
    XCTAssertEqual(model.selectedId, a.id)
    model.navigateCardHistoryForward(fromTerminal: false)
    XCTAssertEqual(model.selectedId, b.id)
}

func testNewSelectionAfterHistoryBackDropsForwardHistory() {
    let (model, _, _, _) = makeModel()
    let a = makeCard("A"), b = makeCard("B"), c = makeCard("C"), d = makeCard("D")
    model.tasks = [a, b, c, d]
    model.selectedId = a.id; model.selectedId = b.id; model.selectedId = c.id
    model.navigateCardHistoryBack(fromTerminal: false)
    model.selectedId = d.id
    model.navigateCardHistoryForward(fromTerminal: false)
    XCTAssertEqual(model.selectedId, d.id)
}

func testHistoryBackFromBoardKeepsBoardFocus() {
    let (model, _, _, win) = makeModel()
    let a = makeCard("A"), b = makeCard("B")
    model.tasks = [a, b]; model.selectedId = a.id; model.selectedId = b.id
    model.navigateCardHistoryBack(fromTerminal: false)
    XCTAssertEqual(model.selectedId, a.id)
    XCTAssertEqual(model.focusZone, .board)
    XCTAssertEqual(win.enterCount, 0)
}

func testHistoryBackFromTerminalKeepsTerminalFocus() async throws {
    let (model, _, _, win) = makeModel()
    let a = makeCard("A"), b = makeCard("B")
    model.tasks = [a, b]; model.selectedId = a.id; model.selectedId = b.id
    model.focusZone = .terminal
    model.navigateCardHistoryBack(fromTerminal: true)
    XCTAssertEqual(model.selectedId, a.id)
    XCTAssertEqual(model.focusZone, .terminal)
    try await _Concurrency.Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(win.enterCount, 1)
}
```

- [ ] **Step 2: Run the tests and confirm RED**

Run: `swift test --filter BoardModelPlatformTests`

Expected: compilation fails because the history traversal methods do not exist.

- [ ] **Step 3: Add the shared selection hook**

Change `selectedId` to call both lifecycle hooks only on a real transition:

```swift
@Published public var selectedId: UUID? {
    didSet {
        guard oldValue != selectedId else { return }
        if selectedId == nil { onSelectionCleared() }
        onSelectionChanged(from: oldValue, to: selectedId)
    }
}
func onSelectionCleared() {}
func onSelectionChanged(from oldValue: UUID?, to newValue: UUID?) {}
```

- [ ] **Step 4: Integrate history in `BoardUX`**

Add state, override recording, and traversal:

```swift
private var cardNavigationHistory = CardNavigationHistory()
private var replayingCardNavigationHistory = false

override func onSelectionChanged(from oldValue: UUID?, to newValue: UUID?) {
    guard !replayingCardNavigationHistory, let newValue else { return }
    cardNavigationHistory.record(newValue)
}

public func navigateCardHistoryBack(fromTerminal: Bool) {
    navigateCardHistory(backward: true, fromTerminal: fromTerminal)
}

public func navigateCardHistoryForward(fromTerminal: Bool) {
    navigateCardHistory(backward: false, fromTerminal: fromTerminal)
}

private func navigateCardHistory(backward: Bool, fromTerminal: Bool) {
    let validIds = Set((tasks + archived).map(\.id))
    let destination = backward
        ? cardNavigationHistory.back(validIds: validIds)
        : cardNavigationHistory.forward(validIds: validIds)
    guard let destination else { return }

    replayingCardNavigationHistory = true
    defer { replayingCardNavigationHistory = false }
    if fromTerminal {
        selectAndEnterTerminal(destination)
    } else {
        focusZone = .board
        selectedId = destination
    }
}
```

- [ ] **Step 5: Run the tests and confirm GREEN**

Run: `swift test --filter BoardModelPlatformTests`

Expected: all BoardModel platform tests pass.

- [ ] **Step 6: Commit selection integration**

```bash
git add Sources/OrchestraUI/BoardStore.swift Sources/OrchestraUI/BoardUX.swift Tests/OrchestraUITests/BoardModelPlatformTests.swift
git commit -m "feat(ui): record and traverse card selection history"
```

### Task 3: Bind Ctrl-O and Ctrl-I in Vim board/terminal contexts

**Files:**
- Modify: `Sources/OrchestraKit/Keyboard/KeyChord.swift`
- Modify: `Sources/OrchestraCore/Keyboard/Keybindings.swift`
- Modify: `App/KeyboardController.swift`
- Modify: `Tests/OrchestraCoreTests/KeybindingsTests.swift`

**Interfaces:**
- Consumes: `KeyChord`, `KeyContext`, and the two `BoardUX` traversal methods from Task 2
- Produces: `KeyIntent.historyBack` and `KeyIntent.historyForward`

- [ ] **Step 1: Write failing keybinding tests**

```swift
func test_ctrl_o_i_traverse_history_on_board_and_terminal() {
    for ctx in [KeyContext.board, .terminal] {
        XCTAssertEqual(map(KeyChord("o", .control), ctx), .historyBack)
        XCTAssertEqual(map(KeyChord("i", .control), ctx), .historyForward)
    }
}

func test_ctrl_o_i_pass_through_fields_overlays_and_command_mode() {
    for ctx in [KeyContext.field, .overlay] {
        XCTAssertNil(map(KeyChord("o", .control), ctx))
        XCTAssertNil(map(KeyChord("i", .control), ctx))
    }
    XCTAssertNil(base(KeyChord("o", .control), .board))
    XCTAssertNil(base(KeyChord("i", .control), .terminal))
}
```

- [ ] **Step 2: Run the tests and confirm RED**

Run: `swift test --filter KeybindingsTests`

Expected: compilation fails because the new intents do not exist.

- [ ] **Step 3: Add the intents and Vim-only mapping**

Add to `KeyIntent`:

```swift
case historyBack               // Ctrl-O — previous visited card
case historyForward            // Ctrl-I — next visited card
```

In `VimKeybindings.intent`, after command-modifier handling and before `Ctrl-Shift-hjkl`, add:

```swift
if chord.mods == .control, ctx == .board || ctx == .terminal {
    switch chord.key.lowercased() {
    case "o": return .historyBack
    case "i": return .historyForward
    default: break
    }
}
```

- [ ] **Step 4: Execute the intents in `KeyboardController`**

Add exhaustive switch cases:

```swift
case .historyBack:
    model.navigateCardHistoryBack(fromTerminal: ctx == .terminal); return true
case .historyForward:
    model.navigateCardHistoryForward(fromTerminal: ctx == .terminal); return true
```

- [ ] **Step 5: Run keybinding and UI tests and confirm GREEN**

Run: `swift test --filter KeybindingsTests && swift test --filter CardNavigationHistoryTests && swift test --filter BoardModelPlatformTests`

Expected: all targeted tests pass.

- [ ] **Step 6: Commit keyboard routing**

```bash
git add Sources/OrchestraKit/Keyboard/KeyChord.swift Sources/OrchestraCore/Keyboard/Keybindings.swift App/KeyboardController.swift Tests/OrchestraCoreTests/KeybindingsTests.swift
git commit -m "feat(keyboard): bind card history navigation"
```

### Task 4: Discoverability, real-event coverage, and full verification

**Files:**
- Modify: `App/Views/KeyboardHelpView.swift`
- Modify: `docs/07-app-ui.md`
- Modify: `scripts/orch-key-demo.sh`

**Interfaces:**
- Consumes: shipped `Ctrl-O`/`Ctrl-I` behavior
- Produces: visible help row, documentation table row, and synthetic-key harness steps

- [ ] **Step 1: Add the help and docs rows**

In the Help overlay's Navigate section add:

```swift
Row(keys: "⌃o / ⌃i", desc: "Previous / next visited card"),
```

In `docs/07-app-ui.md` add this binding row:

```markdown
| `⌃o` / `⌃i` | Previous / next visited card (browser-style history); works from the board or a terminal and preserves that mode |
```

- [ ] **Step 2: Extend the synthetic-key harness**

After the initial selection moves, add:

```bash
keys C-o;          shot history-back
keys C-i;          shot history-forward
```

- [ ] **Step 3: Run formatting and targeted verification**

Run: `git diff --check`

Expected: no output.

Run: `swift test --filter KeybindingsTests && swift test --filter CardNavigationHistoryTests && swift test --filter BoardModelPlatformTests`

Expected: all targeted tests pass.

Run: `scripts/typecheck-app.sh`

Expected: exits 0 with no typechecking errors.

Run where Screen Recording/Xcode are available: `scripts/orch-key-demo.sh`

Expected: the generated `history-back` and `history-forward` screenshots show the selection returning to the prior card and then advancing again.

- [ ] **Step 4: Commit documentation and harness coverage**

```bash
git add App/Views/KeyboardHelpView.swift docs/07-app-ui.md scripts/orch-key-demo.sh
git commit -m "docs: expose card history shortcuts"
```

- [ ] **Step 5: Run the complete relevant verification suite**

Run: `swift test`

Expected: the complete Swift package test suite passes.

Run: `scripts/typecheck-app.sh`

Expected: exits 0.
