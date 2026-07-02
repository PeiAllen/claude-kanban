# Vim-Style Keyboard Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Orchestra macOS app fully keyboard-navigable with a vim-flavored scheme (focus-as-mode; bare `hjkl` selection, `Ctrl-hjkl` spatial pane focus, `g`-go-to, verbs, `/` search, Cmd accelerators).

**Architecture:** Pure decision logic (chord→intent mapping, board selection movement) lives in `OrchestraCore` as unit-tested value types (`KeyChord`, `KeyContext`, `KeyIntent`, `KeyMap`, `BoardNavigator`). The App installs one `NSEvent` keyDown local monitor (`KeyboardController`) — mirroring the existing shared scroll monitor in `AgentTerminalView` — which derives the current `KeyContext` from the first responder + model state, asks `KeyMap`/`BoardNavigator` what to do, and executes the resulting `KeyIntent` against `BoardModel`. Consumed keys return `nil` from the monitor (swallowed); everything else passes through to SwiftTerm/fields untouched.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS 14+), SwiftTerm (app only), XCTest (`swift test`) for the core logic. App built via `scripts/build-app.sh`; UI verified via `scripts/orch-ui-shot.sh` (isolated instance, screenshot by window id — never the live app).

## Global Constraints

- **`Esc` is sacred to a focused terminal** — never intercept it there; it always reaches the agent.
- **In terminal context, intercept only** `Ctrl-hjkl` (and only the directions with a real neighbor — edge directions pass through) plus the `Cmd` accelerators. Everything else → pty.
- **No global mode** — `KeyContext` is derived from the first responder + model state every event, never a stored toggle.
- Pure logic in `OrchestraCore` must stay **offline / dependency-free** (no AppKit imports) so `swift test` stays green. `KeyChord` uses plain `Character` + an `OptionSet` of modifiers, not `NSEvent`.
- App code is **not** a SwiftPM target: App-side tasks are verified by `scripts/build-app.sh` succeeding + driving the isolated instance, not XCTest.
- Follow existing App patterns: `@MainActor final class ... : ObservableObject`, `_Concurrency.Task { await model.… }` for daemon calls, `F.ui/F.mono` fonts, `theme.*` tokens.
- **Out of scope (deferred / not this plan):** multi-select (`x`), `f` link-hints, `:` command palette. Leave `KeyIntent` cases room for them but do not implement.

---

## File Structure

**Create (OrchestraCore — pure, tested):**
- `Sources/OrchestraCore/Keyboard/KeyChord.swift` — `KeyChord` (char + `KeyModifiers` OptionSet), `KeyContext`, `KeyIntent`.
- `Sources/OrchestraCore/Keyboard/KeyMap.swift` — `KeyMap.intent(for:in:)` pure dispatch.
- `Sources/OrchestraCore/Keyboard/BoardNavigator.swift` — pure selection movement over `[Task]`.
- `Tests/OrchestraCoreTests/KeyMapTests.swift`
- `Tests/OrchestraCoreTests/BoardNavigatorTests.swift`

**Create (App — wiring):**
- `App/KeyboardController.swift` — `NSEvent` monitor, context detection, intent execution.
- `App/Views/ContextChip.swift` — the small BOARD/TERMINAL focus indicator.

**Modify (App):**
- `App/BoardModel.swift` — add navigation state (`focusZone`, `pendingG`, `searchQuery`, `showHelp`) + intent-executing methods (`selectNext`, `carrySelected`, `focusPane`, etc.).
- `App/OrchestraApp.swift` — instantiate `KeyboardController`; add `.commands { }` menu for Cmd-N/T/W; mount the context chip.
- `App/Views/InspectorView.swift` — expose an "enter terminal" focus hook + read `mode` from the model (so `d` can toggle it).
- `App/Views/BoardView.swift` — draw the selection highlight from `model.selectedId` (already partially there via CardView) and scroll-to-selection.

---

## Phase 1 — Pure core logic (OrchestraCore, TDD)

### Task 1: KeyChord / KeyContext / KeyIntent value types

**Files:**
- Create: `Sources/OrchestraCore/Keyboard/KeyChord.swift`
- Test: (exercised by Tasks 2–3)

**Interfaces:**
- Produces:
  - `public struct KeyModifiers: OptionSet, Sendable { public let rawValue: Int; static let control, command, shift, option }`
  - `public struct KeyChord: Equatable, Sendable { public let key: Character; public let mods: KeyModifiers; public init(_ key: Character, _ mods: KeyModifiers = []) }`
  - `public enum KeyContext: Sendable { case board, terminal, field, overlay }`
  - `public enum Direction: Sendable { case up, down, left, right }`
  - `public enum KeyIntent: Equatable, Sendable` with cases: `moveSelection(Direction)`, `selectEnd(first: Bool)` (gg/G), `openInspector`, `closeOrClear`, `enterTerminal`, `focusPane(Direction)`, `carry(Direction)`, `spawn`, `archive`, `openInZed`, `toggleDiff`, `openInbox`, `copy(CopyTarget)`, `goTo(GoTarget)`, `beginGoTo`, `search`, `help`, `newShell`, `closeFrontmost`, `newCard`.
  - `public enum CopyTarget: Sendable { case chatLink, tmux, path }`
  - `public enum GoTarget: String, Sendable, CaseIterable { case plan, impl, review, freeform, activity, done, settings }`

- [ ] **Step 1: Write the type file**

```swift
import Foundation

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let command = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let option  = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyChord: Equatable, Sendable {
    public let key: Character
    public let mods: KeyModifiers
    public init(_ key: Character, _ mods: KeyModifiers = []) { self.key = key; self.mods = mods }
}

public enum KeyContext: Sendable { case board, terminal, field, overlay }
public enum Direction: Sendable, Equatable { case up, down, left, right }
public enum CopyTarget: Sendable, Equatable { case chatLink, tmux, path }
public enum GoTarget: String, Sendable, CaseIterable, Equatable {
    case plan, impl, review, freeform, activity, done, settings
}

public enum KeyIntent: Equatable, Sendable {
    case moveSelection(Direction)
    case selectEnd(first: Bool)
    case openInspector
    case closeOrClear
    case enterTerminal
    case focusPane(Direction)
    case carry(Direction)
    case spawn
    case newCard
    case archive
    case openInZed
    case toggleDiff
    case openInbox
    case copy(CopyTarget)
    case beginGoTo
    case goTo(GoTarget)
    case search
    case help
    case newShell
    case closeFrontmost
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (no test yet). This type file is consumed by Tasks 2–3.

- [ ] **Step 3: Commit**

```bash
git add Sources/OrchestraCore/Keyboard/KeyChord.swift
git commit -m "feat(keyboard): KeyChord/KeyContext/KeyIntent value types"
```

### Task 2: BoardNavigator — pure selection movement

**Files:**
- Create: `Sources/OrchestraCore/Keyboard/BoardNavigator.swift`
- Test: `Tests/OrchestraCoreTests/BoardNavigatorTests.swift`

**Interfaces:**
- Consumes: `Task`, `Column` (from Model.swift).
- Produces:
  - `public enum BoardNavigator` with:
    - `static func columnCards(_ tasks: [Task], _ col: Column) -> [Task]` — non-archived worktree cards in `col`, sorted by `order`.
    - `static func move(_ tasks: [Task], selected: UUID?, _ dir: Direction) -> UUID?` — returns the new selection id (nil-safe: if nothing selected, selects the first card of the Plan column on any move).
    - `static func end(_ tasks: [Task], selected: UUID?, first: Bool) -> UUID?` — first/last card of the selected card's column.
    - `static func columnOf(_ tasks: [Task], _ id: UUID) -> Column?`

Semantics: `.left`/`.right` move to the same-or-nearest row index in the adjacent column (Plan↔Impl↔Review); `.up`/`.down` move within the current column. Movement never crosses into freeform (that's `Ctrl-j`, a pane focus, handled App-side). If the target column is empty, selection stays.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OrchestraCore

final class BoardNavigatorTests: XCTestCase {
    private func card(_ id: String, _ col: Column, order: Int) -> Task {
        Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
             title: id, repo: "/r", branch: id, cwd: "/r/\(id)",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
             order: order, status: .running, initialPrompt: id)
    }

    func test_down_moves_within_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        let start = ts[0].id
        XCTAssertEqual(BoardNavigator.move(ts, selected: start, .down), ts[1].id)
    }

    func test_down_at_bottom_stays() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .down), ts[1].id)
    }

    func test_right_moves_to_adjacent_column_same_row() {
        let ts = [card("01", .plan, order: 0),
                  card("11", .impl, order: 0), card("12", .impl, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .right), ts[1].id)
    }

    func test_right_into_empty_column_stays() {
        let ts = [card("01", .plan, order: 0)]   // impl + review empty
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .right), ts[0].id)
    }

    func test_move_with_no_selection_picks_first_plan() {
        let ts = [card("01", .plan, order: 0)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: nil, .down), ts[0].id)
    }

    func test_end_last_of_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.end(ts, selected: ts[0].id, first: false), ts[1].id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BoardNavigatorTests`
Expected: FAIL — `BoardNavigator` not defined.

- [ ] **Step 3: Implement BoardNavigator**

```swift
import Foundation

public enum BoardNavigator {
    private static let order: [Column] = [.plan, .impl, .review]

    public static func columnCards(_ tasks: [Task], _ col: Column) -> [Task] {
        tasks.filter { $0.column == col && !$0.archived && $0.origin == .worktree }
             .sorted { $0.order < $1.order }
    }

    public static func columnOf(_ tasks: [Task], _ id: UUID) -> Column? {
        tasks.first { $0.id == id && !$0.archived && $0.origin == .worktree }?.column
    }

    public static func move(_ tasks: [Task], selected: UUID?, _ dir: Direction) -> UUID? {
        guard let selected, let col = columnOf(tasks, selected) else {
            return columnCards(tasks, .plan).first?.id
        }
        let cards = columnCards(tasks, col)
        guard let row = cards.firstIndex(where: { $0.id == selected }) else { return selected }
        switch dir {
        case .up:   return row > 0 ? cards[row - 1].id : selected
        case .down: return row < cards.count - 1 ? cards[row + 1].id : selected
        case .left, .right:
            guard let ci = order.firstIndex(of: col) else { return selected }
            let ti = dir == .left ? ci - 1 : ci + 1
            guard ti >= 0, ti < order.count else { return selected }
            let target = columnCards(tasks, order[ti])
            guard !target.isEmpty else { return selected }
            return target[min(row, target.count - 1)].id
        }
    }

    public static func end(_ tasks: [Task], selected: UUID?, first: Bool) -> UUID? {
        guard let selected, let col = columnOf(tasks, selected) else { return selected }
        let cards = columnCards(tasks, col)
        return first ? cards.first?.id : cards.last?.id
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BoardNavigatorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Keyboard/BoardNavigator.swift Tests/OrchestraCoreTests/BoardNavigatorTests.swift
git commit -m "feat(keyboard): pure BoardNavigator selection movement + tests"
```

### Task 3: KeyMap — pure chord → intent dispatch

**Files:**
- Create: `Sources/OrchestraCore/Keyboard/KeyMap.swift`
- Test: `Tests/OrchestraCoreTests/KeyMapTests.swift`

**Interfaces:**
- Consumes: `KeyChord`, `KeyContext`, `KeyIntent` (Task 1).
- Produces: `public enum KeyMap { public static func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent? }`

Rules (the spec, distilled):
- **Cmd accelerators** apply in every context: `Cmd-n`→`newCard`, `Cmd-t`→`newShell`, `Cmd-w`→`closeFrontmost`.
- **terminal context:** only `Ctrl-h/j/k/l` → `focusPane(dir)`. Everything else → nil (passes to pty). (Edge passthrough is decided App-side; KeyMap always maps the chord to a `focusPane`, App decides whether to honor or pass through.)
- **field context:** only `Ctrl-j/k` → `focusPane(.down/.up)` (dropdown/form move). Everything else → nil.
- **overlay context:** `Esc`→`closeOrClear`. Everything else → nil (SwiftUI handles the overlay).
- **board context:** the full map below; if `awaitingGoTo` is true, a letter resolves via `goTarget(for:)` → `goTo(...)` (or nil to cancel).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OrchestraCore

final class KeyMapTests: XCTestCase {
    func test_board_hjkl_moves() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("j"), in: .board, awaitingGoTo: false), .moveSelection(.down))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("h"), in: .board, awaitingGoTo: false), .moveSelection(.left))
    }
    func test_board_verbs() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("c"), in: .board, awaitingGoTo: false), .spawn)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("a"), in: .board, awaitingGoTo: false), .archive)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("o"), in: .board, awaitingGoTo: false), .openInZed)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("d"), in: .board, awaitingGoTo: false), .toggleDiff)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("i"), in: .board, awaitingGoTo: false), .enterTerminal)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("I", .shift), in: .board, awaitingGoTo: false), .openInbox)
    }
    func test_board_carry_is_shifted_hl() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("H", .shift), in: .board, awaitingGoTo: false), .carry(.left))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("L", .shift), in: .board, awaitingGoTo: false), .carry(.right))
    }
    func test_board_ctrl_hjkl_is_pane_focus() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("l", .control), in: .board, awaitingGoTo: false), .focusPane(.right))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("j", .control), in: .board, awaitingGoTo: false), .focusPane(.down))
    }
    func test_goto_prefix_and_targets() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("g"), in: .board, awaitingGoTo: false), .beginGoTo)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("p"), in: .board, awaitingGoTo: true), .goTo(.plan))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("r"), in: .board, awaitingGoTo: true), .goTo(.review))
    }
    func test_gg_is_select_first() {
        XCTAssertEqual(KeyMap.intent(for: KeyChord("g"), in: .board, awaitingGoTo: true), .selectEnd(first: true))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("G", .shift), in: .board, awaitingGoTo: false), .selectEnd(first: false))
    }
    func test_copy_yank_needs_second_key_appside() {
        // y alone begins a yank; the map exposes yc/yt/yp as awaitingGoTo-like? Represent copies as direct chords:
        XCTAssertEqual(KeyMap.intent(for: KeyChord("/"), in: .board, awaitingGoTo: false), .search)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("?"), in: .board, awaitingGoTo: false), .help)
        XCTAssertEqual(KeyMap.intent(for: KeyChord("\u{1B}"), in: .board, awaitingGoTo: false), .closeOrClear)
    }
    func test_cmd_accelerators_everywhere() {
        for ctx in [KeyContext.board, .terminal, .field, .overlay] {
            XCTAssertEqual(KeyMap.intent(for: KeyChord("n", .command), in: ctx, awaitingGoTo: false), .newCard)
            XCTAssertEqual(KeyMap.intent(for: KeyChord("w", .command), in: ctx, awaitingGoTo: false), .closeFrontmost)
        }
    }
    func test_terminal_passes_through_non_ctrl() {
        XCTAssertNil(KeyMap.intent(for: KeyChord("j"), in: .terminal, awaitingGoTo: false))
        XCTAssertEqual(KeyMap.intent(for: KeyChord("h", .control), in: .terminal, awaitingGoTo: false), .focusPane(.left))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyMapTests`
Expected: FAIL — `KeyMap` not defined.

- [ ] **Step 3: Implement KeyMap**

```swift
import Foundation

public enum KeyMap {
    public static func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent? {
        // Cmd accelerators — every context.
        if chord.mods.contains(.command) {
            switch chord.key {
            case "n": return .newCard
            case "t": return .newShell
            case "w": return .closeFrontmost
            default: return nil
            }
        }
        // Ctrl-hjkl pane focus — board, terminal, field (field maps only j/k).
        if chord.mods.contains(.control), let dir = direction(chord.key) {
            if ctx == .field { return (dir == .up || dir == .down) ? .focusPane(dir) : nil }
            if ctx == .board || ctx == .terminal { return .focusPane(dir) }
            return nil
        }
        switch ctx {
        case .terminal, .field:
            return nil                         // everything else → pty / text field
        case .overlay:
            return chord.key == "\u{1B}" ? .closeOrClear : nil
        case .board:
            return boardIntent(chord, awaitingGoTo: awaitingGoTo)
        }
    }

    private static func direction(_ key: Character) -> Direction? {
        switch key { case "h": return .left; case "j": return .down
                     case "k": return .up; case "l": return .right; default: return nil }
    }

    private static func boardIntent(_ chord: KeyChord, awaitingGoTo: Bool) -> KeyIntent? {
        if awaitingGoTo {
            if chord.key == "g" { return .selectEnd(first: true) }         // gg
            if let t = GoTarget(rawValue: goName(chord.key)) { return .goTo(t) }
            return nil                                                     // unknown → cancel silently
        }
        switch chord.key {
        case "h": return .moveSelection(.left)
        case "j": return .moveSelection(.down)
        case "k": return .moveSelection(.up)
        case "l": return .moveSelection(.right)
        case "H": return .carry(.left)
        case "L": return .carry(.right)
        case "G": return .selectEnd(first: false)
        case "g": return .beginGoTo
        case "\r", "\n": return .openInspector
        case "\u{1B}": return .closeOrClear
        case "i": return .enterTerminal
        case "I": return .openInbox
        case "c": return .spawn
        case "a": return .archive
        case "o": return .openInZed
        case "d": return .toggleDiff
        case "t": return .newShell
        case "/": return .search
        case "?": return .help
        default: return nil
        }
    }

    /// Map a go-to letter to a GoTarget raw value (p→plan, i→impl, r→review, f→freeform, a→activity, D/d→done, s→settings).
    private static func goName(_ key: Character) -> String {
        switch key {
        case "p": return "plan"; case "i": return "impl"; case "r": return "review"
        case "f": return "freeform"; case "a": return "activity"; case "d": return "done"
        case "s": return "settings"; default: return ""
        }
    }
}
```

Note: `y`-prefixed copies (`yc`/`yt`/`yp`) are handled App-side as a small pending-`y` state machine analogous to `awaitingGoTo` (kept out of `KeyMap` to avoid a second prefix param); the App emits `.copy(...)` directly. Covered in Task 6.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyMapTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Keyboard/KeyMap.swift Tests/OrchestraCoreTests/KeyMapTests.swift
git commit -m "feat(keyboard): pure KeyMap chord->intent dispatch + tests"
```

---

## Phase 2 — App wiring (verified by build + isolated-instance driving)

### Task 4: BoardModel navigation state + intent-executing methods

**Files:**
- Modify: `App/BoardModel.swift`

**Interfaces:**
- Produces on `BoardModel`:
  - `@Published var focusZone: FocusZone = .board` where `enum FocusZone { case board, inspector, terminal, shell }`
  - `@Published var showHelp = false`, `@Published var searchQuery: String? = nil`, `@Published var inspectorMode: InspectorMode` (move `mode` off InspectorView so `d` can drive it — but `InspectorMode` is App-local; keep it App-side).
  - `@Published var requestInboxOpen = false` (a pulse the inspector observes to open its popover).
  - Methods: `func selectMove(_ dir: Direction)`, `func selectEnd(first: Bool)`, `func carrySelected(_ dir: Direction)`, `func archiveSelected()`, `func openZedSelected()`, `func copySelected(_ target: CopyTarget)`, `func goTo(_ target: GoTarget)`, `func closeFrontmost()`.

- [ ] **Step 1: Add the state + methods** (no isolated unit test — App target; verified by build). Example additions:

```swift
enum FocusZone { case board, inspector, terminal, shell }

@Published var focusZone: FocusZone = .board
@Published var showHelp = false
@Published var searchQuery: String? = nil
@Published var inspectorMode: InspectorMode = .agent
@Published var requestInboxOpen = false

func selectMove(_ dir: Direction) { selectedId = BoardNavigator.move(tasks, selected: selectedId, dir) }
func selectEnd(first: Bool) { selectedId = BoardNavigator.end(tasks, selected: selectedId, first: first) }

func carrySelected(_ dir: Direction) {
    guard let id = selectedId, let col = BoardNavigator.columnOf(tasks, id) else { return }
    let order: [Column] = [.plan, .impl, .review]
    guard let ci = order.firstIndex(of: col) else { return }
    let ti = dir == .left ? ci - 1 : ci + 1
    guard ti >= 0, ti < order.count else { return }
    _Concurrency.Task { await move(id, to: order[ti]) }
}

func archiveSelected() { if let id = selectedId { _Concurrency.Task { await archive(id) } } }
func openZedSelected() { if let id = selectedId { _Concurrency.Task { await openInZed(id) } } }

func copySelected(_ target: CopyTarget) {
    guard let t = selected else { return }
    let s: String
    switch target {
    case .chatLink: s = t.ref()
    case .tmux:     s = "\(t.tmuxSession):agent"
    case .path:     s = t.cwd
    }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    toast("Copied", sub: nil)
}

func goTo(_ target: GoTarget) {
    switch target {
    case .plan:     selectedId = BoardNavigator.columnCards(tasks, .plan).first?.id
    case .impl:     selectedId = BoardNavigator.columnCards(tasks, .impl).first?.id
    case .review:   selectedId = BoardNavigator.columnCards(tasks, .review).first?.id
    case .freeform: selectedId = freeformTasks.first?.id; focusZone = .board
    case .activity: showActivity = true
    case .done:     showDone = true
    case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

func closeFrontmost() {
    if showSpawn { showSpawn = false; return }
    if showDone { showDone = false; return }
    if showActivity { showActivity = false; return }
    if showHelp { showHelp = false; return }
    // shell tab focused → close it
    if focusZone == .shell, let id = selectedId, let w = selectedShell[id] {
        _Concurrency.Task { await closeShell(id, w) }; return
    }
    if selectedId != nil, focusZone != .board { selectedId = nil; focusZone = .board; return } // close inspector
    if let id = selectedId { _Concurrency.Task { await archive(id) } }                          // archive card
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(app): BoardModel navigation state + intent-executing methods"
```

### Task 5: KeyboardController — the NSEvent monitor

**Files:**
- Create: `App/KeyboardController.swift`

**Interfaces:**
- Consumes: `BoardModel`, `KeyMap`, `KeyChord`, `KeyContext`.
- Produces: `@MainActor final class KeyboardController { init(model: BoardModel); func install() }` — installs one `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`. Determines context, builds `KeyChord`, asks `KeyMap`, executes intent, returns `nil` if consumed else the event.

Context detection:
- If a popover/sheet is up (`model.showSpawn || model.showDone || model.showActivity || model.showHelp`) → `.overlay`.
- Else if the window's first responder is (or descends from) a `ScrollableTerminalView` → `.terminal`.
- Else if the first responder is an `NSText`/`NSTextView`/field editor → `.field`.
- Else → `.board`.

- [ ] **Step 1: Implement KeyboardController**

```swift
import AppKit
import OrchestraCore

@MainActor
final class KeyboardController {
    private let model: BoardModel
    private var pendingG = false
    private var pendingY = false
    init(model: BoardModel) { self.model = model }

    func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func context() -> KeyContext {
        if model.showSpawn || model.showDone || model.showActivity || model.showHelp { return .overlay }
        let fr = NSApp.keyWindow?.firstResponder
        var v = fr as? NSView
        while let cur = v {
            if String(describing: type(of: cur)).contains("ScrollableTerminalView") { return .terminal }
            v = cur.superview
        }
        if fr is NSText || fr is NSTextView { return .field }
        return .board
    }

    private func chord(from e: NSEvent) -> KeyChord? {
        guard let chars = e.charactersIgnoringModifiers, let c = chars.first else { return nil }
        var mods: KeyModifiers = []
        if e.modifierFlags.contains(.control) { mods.insert(.control) }
        if e.modifierFlags.contains(.command) { mods.insert(.command) }
        if e.modifierFlags.contains(.shift)   { mods.insert(.shift) }
        if e.modifierFlags.contains(.option)  { mods.insert(.option) }
        return KeyChord(c, mods)
    }

    /// Returns true if the event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        guard let ch = chord(from: e) else { return false }
        let ctx = context()

        // y-prefix copy state machine (board only).
        if ctx == .board, pendingY {
            pendingY = false
            switch ch.key {
            case "c": model.copySelected(.chatLink); return true
            case "t": model.copySelected(.tmux); return true
            case "p": model.copySelected(.path); return true
            default: return true      // swallow the aborted yank
            }
        }
        if ctx == .board, ch.key == "y", ch.mods.isEmpty { pendingY = true; return true }

        guard let intent = KeyMap.intent(for: ch, in: ctx, awaitingGoTo: pendingG) else {
            pendingG = false
            return false
        }
        if pendingG, case .beginGoTo = intent {} else { pendingG = false }
        return execute(intent, ctx: ctx)
    }

    private func execute(_ intent: KeyIntent, ctx: KeyContext) -> Bool {
        switch intent {
        case .moveSelection(let d): model.selectMove(d); return true
        case .selectEnd(let f): model.selectEnd(first: f); return true
        case .openInspector: model.focusZone = .inspector; return true      // selection already opens the inspector
        case .closeOrClear: model.closeFrontmost(); return true
        case .enterTerminal: model.focusZone = .terminal; FocusBridge.enterTerminal(); return true
        case .focusPane(let d): return FocusBridge.movePane(d, model: model, from: ctx)
        case .carry(let d): model.carrySelected(d); return true
        case .spawn, .newCard: model.spawnDefaultColumn = .plan; model.showSpawn = true; return true
        case .archive: model.archiveSelected(); return true
        case .openInZed: model.openZedSelected(); return true
        case .toggleDiff: model.inspectorMode = (model.inspectorMode == .agent ? .diff : .agent); return true
        case .openInbox: model.requestInboxOpen = true; return true
        case .copy(let t): model.copySelected(t); return true
        case .beginGoTo: pendingG = true; return true
        case .goTo(let t): model.goTo(t); return true
        case .search: model.searchQuery = ""; return true
        case .help: model.showHelp = true; return true
        case .newShell: if let id = model.selectedId { _Concurrency.Task { await model.newShell(id) } }; return true
        case .closeFrontmost: model.closeFrontmost(); return true
        }
    }
}
```

- [ ] **Step 2: Add the FocusBridge helper** (AppKit focus moves; edge-aware passthrough for terminal)

```swift
import AppKit
import OrchestraCore

enum FocusBridge {
    /// Move keyboard first-responder to the agent terminal, if present.
    static func enterTerminal() {
        guard let root = NSApp.keyWindow?.contentView else { return }
        if let term = firstTerminal(in: root) { term.window?.makeFirstResponder(term) }
    }
    /// Eject to the board (drop first responder off any terminal).
    static func ejectToBoard(_ model: BoardModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.focusZone = .board
    }

    /// Returns true if consumed. Edge-aware: from a terminal, only .left ejects (board is left);
    /// other directions with no neighbour pass through (return false → the pty gets the key).
    static func movePane(_ dir: Direction, model: BoardModel, from ctx: KeyContext) -> Bool {
        switch ctx {
        case .board:
            switch dir {
            case .right: if model.selectedId != nil { enterTerminal(); model.focusZone = .terminal; return true }; return false
            case .down:  if !model.freeformTasks.isEmpty { model.selectedId = model.freeformTasks.first?.id; return true }; return false
            default: return false
            }
        case .terminal:
            if dir == .left { ejectToBoard(model); return true }
            return false          // up/down/right: no neighbour beyond → pass through to pty
        default: return false
        }
    }

    private static func firstTerminal(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("ScrollableTerminalView") { return view }
        for sub in view.subviews { if let t = firstTerminal(in: sub) { return t } }
        return nil
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add App/KeyboardController.swift
git commit -m "feat(app): KeyboardController NSEvent monitor + FocusBridge"
```

### Task 6: Wire the controller + Cmd menu + inspector mode/inbox hooks

**Files:**
- Modify: `App/OrchestraApp.swift`, `App/Views/InspectorView.swift`

- [ ] **Step 1: Install the controller and add the menu commands.** In `OrchestraApp`:

```swift
@StateObject private var model = BoardModel()
@State private var keyboard: KeyboardController? = nil
```

In the `Window` content `.task`/`.onAppear`, install once:

```swift
.onAppear {
    if keyboard == nil { let k = KeyboardController(model: model); k.install(); keyboard = k }
}
```

Add a `.commands` block to the `Window` scene:

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("New Card") { model.spawnDefaultColumn = .plan; model.showSpawn = true }
            .keyboardShortcut("n", modifiers: .command)
        Button("New Shell") { if let id = model.selectedId { _Concurrency.Task { await model.newShell(id) } } }
            .keyboardShortcut("t", modifiers: .command)
        Button("Close") { model.closeFrontmost() }
            .keyboardShortcut("w", modifiers: .command)
    }
}
```

(The `.commands` menu items double as discoverability and a redundant path; the `KeyboardController` also handles Cmd-* for when focus is in a terminal. Keep both — the menu wins when a menu is key.)

- [ ] **Step 2: Drive InspectorView's mode from the model + open inbox on request.** Replace `@State private var mode` with `model.inspectorMode`:

```swift
// InspectorView
if model.inspectorMode == .diff { DiffInspectorView(task: t) } else { AgentChrome(task: t) }
// HeaderBar Picker binds to $model.inspectorMode (pass the binding down)
```

In `HeaderBar`, observe `model.requestInboxOpen` to open the popover:

```swift
.onChange(of: model.requestInboxOpen) { _, open in if open { showInbox = true; model.requestInboxOpen = false } }
```

- [ ] **Step 3: Build + drive the isolated instance to verify core nav.**

Run: `scripts/build-app.sh`
Then drive via the isolated harness (never the live app), e.g. `ORCH_SHOW=shells scripts/orch-ui-shot.sh` to confirm the app launches with the new controller and screenshot the board; manually confirm `j`/`k`/`h`/`l` move the selection highlight, `Enter` opens the inspector, `c` opens spawn, `a` archives, `Ctrl-l` focuses the terminal, `Ctrl-h` ejects.
Expected: build succeeds; selection moves with hjkl; terminal focus round-trips.

- [ ] **Step 4: Commit**

```bash
git add App/OrchestraApp.swift App/Views/InspectorView.swift
git commit -m "feat(app): install KeyboardController, Cmd menu, inspector mode/inbox hooks"
```

### Task 7: Context chip + selection highlight + scroll-to-selection

**Files:**
- Create: `App/Views/ContextChip.swift`
- Modify: `App/Views/ToolbarView.swift` (mount the chip in `ControlsRow`), `App/Views/BoardView.swift` (ScrollViewReader → scroll to `model.selectedId`).

- [ ] **Step 1: ContextChip** — a small pill reading `model.focusZone` (`BOARD` / `● TERMINAL` / `INSPECTOR` / `SHELL`), amber dot when terminal.

```swift
struct ContextChip: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    private var label: String {
        switch model.focusZone { case .board: return "BOARD"; case .inspector: return "INSPECTOR"
                                 case .terminal: return "● TERMINAL"; case .shell: return "● SHELL" }
    }
    var body: some View {
        Text(label).font(F.mono(9.5, .semibold)).foregroundStyle(theme.text2)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(theme.chip))
    }
}
```

Mount it in `ControlsRow` before `mcpChip`.

- [ ] **Step 2: Scroll-to-selection** in `ColumnView.content`: wrap the `VStack` in a `ScrollViewReader` and `.onChange(of: model.selectedId)` call `proxy.scrollTo(id, anchor: .center)`.

- [ ] **Step 3: Build + screenshot.**

Run: `scripts/build-app.sh` then `ORCH_SHOW=shells scripts/orch-ui-shot.sh`
Expected: chip renders; selecting a card scrolls it into view.

- [ ] **Step 4: Commit**

```bash
git add App/Views/ContextChip.swift App/Views/ToolbarView.swift App/Views/BoardView.swift
git commit -m "feat(app): context chip + scroll-to-selection"
```

### Task 8: Help overlay (`?`)

**Files:**
- Create: `App/Views/KeyboardHelpView.swift`
- Modify: `App/OrchestraApp.swift` (present it when `model.showHelp`).

- [ ] **Step 1:** A modal sheet listing the keymap grouped by context (Board / Inspector / Terminal / Modals), styled with `theme.*`. `Esc` closes (routes through `closeFrontmost`). Present as an overlay in `ContentView` like the spawn sheet (`if model.showHelp { … }`).

- [ ] **Step 2: Build + screenshot** (`ORCH_SHOW` + trigger `?`), confirm it lists the bindings.

- [ ] **Step 3: Commit**

```bash
git add App/Views/KeyboardHelpView.swift App/OrchestraApp.swift
git commit -m "feat(app): ? keyboard-help overlay"
```

---

## Deferred (documented, not implemented this plan)

Tracked for a follow-up plan; each is additive and non-blocking:

- **`/` search / filter** — a search field over cards, `n`/`N` to cycle matches (the intent + `searchQuery` state exist; the UI is deferred).
- **Shell-tab switching** (`Ctrl-h/l` across tabs) + `x` close from ribbon focus, and agent↔shell `Ctrl-j/k` inside the inspector.
- **Combo-box `Ctrl-j/k`** highlight movement in the spawn sheet (repo/branch) and progressive `Esc`.
- **`Ctrl-Shift-hjkl` resize** + `z` collapse (drives the existing drag-handle @AppStorage values).
- **`f` link-hints** and **`x` multi-select** — explicitly out of scope per the user.
- **`:` command palette.**

---

## Self-Review

- **Spec coverage:** board nav (Task 2,4), pane focus/eject (Task 5), verbs incl. inspector chrome (Task 4,6), go-to (Task 3,4), Cmd accelerators (Task 3,6), context chip (Task 7), help (Task 8). Search / resize / shell-tab / combo-box / palette / hints explicitly deferred above.
- **Type consistency:** `Direction`, `KeyIntent`, `GoTarget`, `CopyTarget`, `KeyContext` defined in Task 1 and used unchanged in Tasks 2–7. `InspectorMode` stays App-side; `BoardModel.inspectorMode` is the single source (Task 4/6). `FocusZone` App-side only.
- **Placeholder scan:** none — all steps carry concrete code.
- **Testability:** pure logic (Tasks 1–3) is XCTest-covered; App wiring (Tasks 4–8) is build- + isolated-instance-verified per the project's UI-check method (never the live app).
</content>
