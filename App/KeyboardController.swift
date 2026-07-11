import AppKit
import OrchestraUI
import OrchestraCore

/// The app's single keyboard router. Installs one `NSEvent` keyDown local monitor (mirroring the
/// shared scroll monitor in AgentTerminalView), derives the current `KeyContext` from the first
/// responder + model state, asks the active `Keybindings` what to do, and executes the resulting
/// intent against `BoardModel`. Returns `nil` from the monitor to swallow a consumed key; anything it
/// doesn't consume returns the event untouched so SwiftTerm / text fields / SwiftUI see it normally.
@MainActor
final class KeyboardController {
    private let model: BoardModel
    /// The two keybinding strategies, selected per keypress by the "Vim keyboard" setting. Both are
    /// stateless value types, so a single shared instance of each is all we need.
    private static let vim: Keybindings = VimKeybindings()
    private static let command: Keybindings = CommandKeybindings()
    /// A `g` go-to sequence is in flight (waiting for the second key).
    private var pendingG = false
    /// A `y` yank sequence is in flight (waiting for c/t/p).
    private var pendingY = false
    /// Accumulated keystrokes while `f` hint mode is active (for 2-char labels).
    private var hintBuffer = ""

    init(model: BoardModel) { self.model = model }

    func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    // MARK: context

    private func context() -> KeyContext {
        if model.showSpawn || model.showDone || model.showActivity || model.showHelp || model.showPalette || model.archiveConfirm != nil { return .overlay }
        let fr = NSApp.keyWindow?.firstResponder
        var v = fr as? NSView
        while let cur = v {
            if String(describing: type(of: cur)).contains("ScrollableTerminalView") { return .terminal }
            v = cur.superview
        }
        // A focused text field/editor: keys must type, not navigate.
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

    // MARK: dispatch

    /// Returns true if the event was consumed (swallowed).
    private func handle(_ e: NSEvent) -> Bool {
        guard let ch = chord(from: e) else { return false }

        // Command palette owns its navigation (letters still reach the search field → return false).
        if model.showPalette {
            if ch.key == "\r" || ch.key == "\n" { model.runPaletteSelection(); return true }
            if ch.key == "\u{1B}" { model.showPalette = false; return true }
            if ch.mods.contains(.control), ch.key.lowercased() == "j" { model.paletteMove(1); return true }
            if ch.mods.contains(.control), ch.key.lowercased() == "k" { model.paletteMove(-1); return true }
            return false
        }

        // Archive-confirm dialog owns ⏎ (archive) — esc / ⌘W fall through to closeFrontmost, which
        // peels the dialog first; every other key is inert while it's up.
        if model.archiveConfirm != nil {
            if ch.key == "\r" || ch.key == "\n" { model.confirmArchive(); return true }
            let isClose = ch.key == "\u{1B}" || (ch.mods.contains(.command) && ch.key.lowercased() == "w")
            if !isClose { return true }
        }

        // f link-hint mode captures all keys until a label resolves, an invalid prefix aborts, or Esc.
        if model.hintActive {
            if ch.key == "\u{1B}" { hintBuffer = ""; model.endHint(); return true }
            hintBuffer.append(Character(ch.key.lowercased()))
            if let id = model.hintTarget(hintBuffer) {
                model.selectedId = id; model.focusZone = .board
                hintBuffer = ""; model.endHint(); return true
            }
            // Still a viable prefix of some label? keep buffering; else abort.
            if !model.hintLabels.values.contains(where: { $0.hasPrefix(hintBuffer) }) {
                hintBuffer = ""; model.endHint()
            }
            return true
        }

        let ctx = context()

        // Pick the strategy once — the "Vim keyboard" setting (on by default). CommandKeybindings
        // resolves only ⌘ accelerators + Esc; VimKeybindings adds the whole single-key layer. Read
        // live so a Settings toggle takes effect on the very next keystroke.
        let bindings: Keybindings = UserDefaults.standard.bool(forKey: "orch_vim_keys") ? Self.vim : Self.command

        // `y`-prefix yank state machine (board only) — resolving the c/t/p second key stays here
        // rather than in the pure layer, to avoid a second prefix arg. It's self-gating: `pendingY`
        // is only ever set by the `.beginYank` intent, which only VimKeybindings emits.
        if ctx == .board, pendingY {
            pendingY = false
            switch ch.key {
            case "c": model.copySelected(.chatLink); return true
            case "t": model.copySelected(.tmux);     return true
            case "p": model.copySelected(.path);     return true
            default:  return true                       // abort the yank, swallow the stray key
            }
        }

        let wasAwaitingG = pendingG
        guard let intent = bindings.intent(for: ch, in: ctx, awaitingGoTo: wasAwaitingG) else {
            pendingG = false
            return false
        }
        // Clear the g-sequence unless this key *starts* one.
        if case .beginGoTo = intent { /* keep pendingG set below */ } else { pendingG = false }
        return execute(intent, ctx: ctx)
    }

    private func execute(_ intent: KeyIntent, ctx: KeyContext) -> Bool {
        switch intent {
        case .moveSelection(let d): model.selectMove(d); model.focusZone = .board; return true
        case .selectEnd(let f):     model.selectEnd(first: f); return true
        // Enter and `i` are the same verb: descend the keyboard into the selected card's terminal.
        case .openInspector:        model.enterTerminalZone(); return true
        case .closeOrClear:         model.closeFrontmost(); return true
        case .enterTerminal:        model.enterTerminalZone(); return true
        case .focusPane(let d):     return FocusBridge.movePane(d, model: model, from: ctx)
        case .historyBack:          model.navigateCardHistoryBack(fromTerminal: ctx == .terminal); return true
        case .historyForward:       model.navigateCardHistoryForward(fromTerminal: ctx == .terminal); return true
        case .carry(let d):         model.carrySelected(d); return true
        case .spawn, .newCard:      model.spawnDefaultColumn = .plan; model.showSpawn = true; return true
        case .archive:              model.requestArchiveSelected(); return true
        case .openInZed:            model.openZedSelected(); return true
        case .openNotes:            model.openNotesSelected(); return true
        case .toggleDiff:           model.inspectorMode = (model.inspectorMode == .agent ? .diff : .agent); return true
        case .openInbox:            model.requestInboxOpen = true; return true
        case .copy(let t):          model.copySelected(t); return true
        case .beginYank:            pendingY = true; return true
        case .beginGoTo:            pendingG = true; return true
        case .goTo(let t):          model.goTo(t); return true
        case .search:               model.searchQuery = ""; return true
        case .help:                 model.showHelp = true; return true
        case .newShell:             if let id = model.selectedId { _Concurrency.Task { await model.newShell(id) } }; return true
        case .closeFrontmost:       model.closeFrontmost(); return true
        case .searchNext:           model.searchNext(); return true
        case .searchPrev:           model.searchPrev(); return true
        case .resize(let d):        model.resizeFocusedPane(d); return true
        case .toggleCollapse:       model.toggleCollapseFocused(); return true
        case .hint:                 model.beginHint(); return true
        case .palette:              model.openPalette(); return true
        }
    }
}

/// AppKit focus moves for the pane-focus intents. Kept separate from the controller so the
/// first-responder walking is in one place. MainActor-isolated: it touches `NSApp`, `NSView`, and
/// the `@MainActor BoardModel`.
@MainActor
enum FocusBridge {
    /// Move keyboard focus into the agent terminal, if one is mounted. Returns whether it succeeded.
    @discardableResult
    static func enterTerminal() -> Bool { focusTerminal(window: "agent") }

    /// Focus the mounted terminal view attached to `window` ("agent" / "shell-N"). Returns false when
    /// no such terminal is mounted (e.g. a dead card showing RecoveryView), so callers can reconcile.
    @discardableResult
    static func focusTerminal(window: String) -> Bool {
        guard let root = NSApp.keyWindow?.contentView,
              let term = terminal(in: root, window: window) else { return false }
        term.window?.makeFirstResponder(term)
        return true
    }

    /// Eject focus back to the board (drop first responder off any terminal).
    static func ejectToBoard(_ model: BoardModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.focusZone = .board
    }

    /// The `window` of the terminal that currently holds first responder ("agent" / "shell-N" / nil).
    static func focusedTerminalWindow() -> String? {
        var v = NSApp.keyWindow?.firstResponder as? NSView
        while let cur = v {
            if isTerminal(cur) { return terminalWindow(cur) }
            v = cur.superview
        }
        return nil
    }

    /// Execute a spatial pane-focus move. Returns true if consumed; false = pass the key through to
    /// the pty (edge with no neighbour, e.g. Ctrl-l clear-screen in a shell).
    static func movePane(_ dir: Direction, model: BoardModel, from ctx: KeyContext) -> Bool {
        switch ctx {
        case .board:
            let onFreeform = model.selectedId.map { id in model.freeformTasks.contains { $0.id == id } } ?? false
            switch dir {
            case .right:
                guard model.selectedId != nil else { return false }
                model.focusZone = .terminal; enterTerminal(); return true
            case .down:
                // Descend from the columns into the freeform dock. Already in the dock → passthrough.
                guard !model.freeformTasks.isEmpty, !onFreeform else { return false }
                model.selectedId = model.freeformTasks.first?.id; model.focusZone = .board; return true
            case .up:
                // Climb back out of the freeform dock into the board columns.
                guard onFreeform, let target = BoardNavigator.firstBoardCard(model.tasks) else { return false }
                model.selectedId = target; model.focusZone = .board; return true
            default:
                return false
            }
        case .terminal:
            return moveWithinInspector(dir, model: model)
        default:
            return false
        }
    }

    /// Focus moves while a terminal owns the keyboard: agent ↕ shell, shell tabs ↔, eject to the board.
    private static func moveWithinInspector(_ dir: Direction, model: BoardModel) -> Bool {
        let cur = focusedTerminalWindow() ?? "agent"
        guard let id = model.selectedId else {
            if dir == .left { ejectToBoard(model); return true }
            return false
        }
        let shells = model.shellWindows[id] ?? []
        let shellOpen = model.shellOpen.contains(id) && !shells.isEmpty

        if cur == "agent" {
            switch dir {
            case .left: ejectToBoard(model); return true                 // board is to the left
            case .down:                                                  // into the shell panel
                guard shellOpen else { return false }
                let w = model.selectedShell[id] ?? shells.first!
                model.selectedShell[id] = w; model.focusZone = .shell
                focusTerminal(window: w); return true
            default: return false                                        // up/right → passthrough
            }
        } else {
            // A shell tab is focused. Tabs are horizontal; the agent terminal is above.
            let idx = shells.firstIndex(of: cur) ?? 0
            switch dir {
            case .up:                                                    // back to the agent terminal
                model.focusZone = .terminal; focusTerminal(window: "agent"); return true
            case .left:
                if idx > 0 { switchShell(model, id, shells[idx - 1]); return true }
                ejectToBoard(model); return true                         // first tab → eject to board
            case .right:
                if idx < shells.count - 1 { switchShell(model, id, shells[idx + 1]); return true }
                return false                                             // last tab → passthrough
            case .down: return false                                     // bottom → passthrough
            }
        }
    }

    /// Switch the visible shell tab and refocus it once the new terminal has mounted.
    private static func switchShell(_ model: BoardModel, _ id: UUID, _ window: String) {
        model.selectedShell[id] = window
        model.focusZone = .shell
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            focusTerminal(window: window)
        }
    }

    private static func isTerminal(_ v: NSView) -> Bool {
        String(describing: type(of: v)).contains("ScrollableTerminalView")
    }
    /// The `termWindow` tag set by AgentTerminalView, read via KVC to avoid importing SwiftTerm here.
    private static func terminalWindow(_ v: NSView) -> String? {
        v.value(forKey: "termWindow") as? String
    }
    private static func terminal(in view: NSView, window: String) -> NSView? {
        if isTerminal(view), terminalWindow(view) == window { return view }
        for sub in view.subviews { if let t = terminal(in: sub, window: window) { return t } }
        return nil
    }
}
