import AppKit
import OrchestraCore

/// The app's single keyboard router. Installs one `NSEvent` keyDown local monitor (mirroring the
/// shared scroll monitor in AgentTerminalView), derives the current `KeyContext` from the first
/// responder + model state, asks the pure `KeyMap` what to do, and executes the resulting intent
/// against `BoardModel`. Returns `nil` from the monitor to swallow a consumed key; anything it doesn't
/// consume returns the event untouched so SwiftTerm / text fields / SwiftUI see it normally.
@MainActor
final class KeyboardController {
    private let model: BoardModel
    /// A `g` go-to sequence is in flight (waiting for the second key).
    private var pendingG = false
    /// A `y` yank sequence is in flight (waiting for c/t/p).
    private var pendingY = false

    init(model: BoardModel) { self.model = model }

    func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    // MARK: context

    private func context() -> KeyContext {
        if model.showSpawn || model.showDone || model.showActivity || model.showHelp { return .overlay }
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
        let ctx = context()

        // `y`-prefix yank state machine (board only) — kept out of KeyMap to avoid a second prefix arg.
        if ctx == .board, pendingY {
            pendingY = false
            switch ch.key {
            case "c": model.copySelected(.chatLink); return true
            case "t": model.copySelected(.tmux);     return true
            case "p": model.copySelected(.path);     return true
            default:  return true                       // abort the yank, swallow the stray key
            }
        }
        if ctx == .board, ch.key == "y", ch.mods.isEmpty { pendingY = true; return true }

        let wasAwaitingG = pendingG
        guard let intent = KeyMap.intent(for: ch, in: ctx, awaitingGoTo: wasAwaitingG) else {
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
        case .openInspector:        model.focusZone = .inspector; return true
        case .closeOrClear:         model.closeFrontmost(); return true
        case .enterTerminal:        model.focusZone = .terminal; FocusBridge.enterTerminal(); return true
        case .focusPane(let d):     return FocusBridge.movePane(d, model: model, from: ctx)
        case .carry(let d):         model.carrySelected(d); return true
        case .spawn, .newCard:      model.spawnDefaultColumn = .plan; model.showSpawn = true; return true
        case .archive:              model.archiveSelected(); return true
        case .openInZed:            model.openZedSelected(); return true
        case .toggleDiff:           model.inspectorMode = (model.inspectorMode == .agent ? .diff : .agent); return true
        case .openInbox:            model.requestInboxOpen = true; return true
        case .copy(let t):          model.copySelected(t); return true
        case .beginGoTo:            pendingG = true; return true
        case .goTo(let t):          model.goTo(t); return true
        case .search:               model.searchQuery = ""; return true
        case .help:                 model.showHelp = true; return true
        case .newShell:             if let id = model.selectedId { _Concurrency.Task { await model.newShell(id) } }; return true
        case .closeFrontmost:       model.closeFrontmost(); return true
        }
    }
}

/// AppKit focus moves for the pane-focus intents. Kept separate from the controller so the
/// first-responder walking is in one place. MainActor-isolated: it touches `NSApp`, `NSView`, and
/// the `@MainActor BoardModel`.
@MainActor
enum FocusBridge {
    /// Move keyboard focus into the agent terminal, if one is mounted.
    static func enterTerminal() {
        guard let root = NSApp.keyWindow?.contentView, let term = firstTerminal(in: root) else { return }
        term.window?.makeFirstResponder(term)
    }

    /// Eject focus back to the board (drop first responder off any terminal).
    static func ejectToBoard(_ model: BoardModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.focusZone = .board
    }

    /// Execute a spatial pane-focus move. Returns true if consumed. Edge-aware: from a terminal only
    /// `.left` ejects (the board is to the left); other directions have no neighbour, so they return
    /// false and the key passes through to the pty (e.g. Ctrl-l clear-screen in the shell).
    static func movePane(_ dir: Direction, model: BoardModel, from ctx: KeyContext) -> Bool {
        switch ctx {
        case .board:
            switch dir {
            case .right:
                guard model.selectedId != nil else { return false }
                model.focusZone = .terminal; enterTerminal(); return true
            case .down:
                guard !model.freeformTasks.isEmpty else { return false }
                model.selectedId = model.freeformTasks.first?.id; model.focusZone = .board; return true
            default:
                return false
            }
        case .terminal:
            if dir == .left { ejectToBoard(model); return true }
            return false                    // up/down/right → no neighbour, pass through to pty
        default:
            return false
        }
    }

    private static func firstTerminal(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("ScrollableTerminalView") { return view }
        for sub in view.subviews { if let t = firstTerminal(in: sub) { return t } }
        return nil
    }
}
