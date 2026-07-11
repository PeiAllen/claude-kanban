import Foundation

/// The pure keyboard policy: given a chord, the current context, and whether a `g` go-to sequence is
/// in flight, return the intent to execute (or nil to let the key pass through to the terminal / text
/// field / overlay). Stateless — the App holds the transient prefix flags (`awaitingGoTo`, the yank
/// prefix) and executes whatever intent this returns.
///
/// Two implementations, chosen by the "Vim keyboard" setting (see `KeyboardController`) rather than
/// branched on inline: `CommandKeybindings` — the always-on ⌘ accelerators + Esc — and
/// `VimKeybindings`, which layers the full single-key navigation/command set on top of it.
public protocol Keybindings: Sendable {
    func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent?
}

/// The generic, always-on layer: the ⌘ accelerators (⌘N / ⌘T / ⌘W) plus a bare `Esc` to close or
/// clear the board selection / an overlay. Nothing else is captured — no navigation, no single-key
/// verbs — so every other key passes straight through to the terminal, a text field, or an overlay.
public struct CommandKeybindings: Keybindings {
    public init() {}

    public func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent? {
        // Cmd accelerators apply in every context (terminals ignore Cmd, so these never collide).
        if chord.mods.contains(.command) {
            switch chord.key {
            case "n": return .newCard
            case "t": return .newShell
            case "w": return .closeFrontmost
            default:  return nil
            }
        }
        // A bare Esc closes/clears the board selection or an overlay; it stays sacred to the pty/field.
        if chord.key == "\u{1B}", chord.mods.isEmpty, ctx == .board || ctx == .overlay { return .closeOrClear }
        return nil
    }
}

/// The full vim layer: everything `CommandKeybindings` resolves, plus `hjkl` navigation, spatial pane
/// focus, edge resize, the `g` / `y` / `f` prefixes, and the single-key board verbs. Composed on the
/// generic layer so the ⌘ / Esc handling lives in exactly one place.
public struct VimKeybindings: Keybindings {
    private let command = CommandKeybindings()

    public init() {}

    public func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent? {
        // The generic layer decides first: ⌘ accelerators everywhere, Esc on the board / an overlay.
        if let base = command.intent(for: chord, in: ctx, awaitingGoTo: awaitingGoTo) { return base }
        // Any other ⌘ chord belongs to the command layer alone — never fall through to a board verb
        // (e.g. ⌘D must not read as the bare `d` toggle-diff).
        if chord.mods.contains(.command) { return nil }

        // Vim's jump-list chords traverse card visit history from either app-owned mode. Fields and
        // overlays keep their native Ctrl-I/Ctrl-O behavior, and extra modifiers do not alias these.
        if chord.mods == .control, ctx == .board || ctx == .terminal {
            switch chord.key.lowercased() {
            case "o": return .historyBack
            case "i": return .historyForward
            default: break
            }
        }

        // Ctrl-Shift-hjkl: resize the focused pane's edge (board / terminal only).
        if chord.mods.contains(.control), chord.mods.contains(.shift), let dir = Self.direction(chord.key) {
            return (ctx == .board || ctx == .terminal) ? .resize(dir) : nil
        }
        // Ctrl-hjkl: pane focus on the board / in a terminal; only vertical (form/dropdown) in a field.
        if chord.mods.contains(.control), let dir = Self.direction(chord.key) {
            switch ctx {
            case .field:            return (dir == .up || dir == .down) ? .focusPane(dir) : nil
            case .board, .terminal: return .focusPane(dir)
            case .overlay:          return nil
            }
        }
        switch ctx {
        case .terminal, .field:
            return nil                                  // everything else → pty / text field
        case .overlay:
            return nil                                  // Esc already handled by the command layer
        case .board:
            return Self.boardIntent(chord, awaitingGoTo: awaitingGoTo)
        }
    }

    private static func direction(_ key: Character) -> Direction? {
        // Lowercase so Ctrl-Shift-H (which arrives as "H") still resolves.
        switch Character(key.lowercased()) {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        default:  return nil
        }
    }

    private static func boardIntent(_ chord: KeyChord, awaitingGoTo: Bool) -> KeyIntent? {
        if awaitingGoTo {
            if chord.key == "g" { return .selectEnd(first: true) }        // gg → first card
            if let t = goTarget(chord.key) { return .goTo(t) }
            return nil                                                    // unknown → cancel silently
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
        case "o": return .openNotes
        case "O": return .openInZed
        case "d": return .toggleDiff
        case "t": return .newShell
        case "y": return .beginYank
        case "z": return .toggleCollapse
        case "f": return .hint
        case ":": return .palette
        case "n": return .searchNext
        case "N": return .searchPrev
        case "/": return .search
        case "?": return .help
        default:  return nil
        }
    }

    /// Map a go-to letter to its destination (p→plan, i→impl, r→review, f→freeform, a→activity,
    /// d→done, s→settings). Returns nil for any other key (the sequence cancels).
    private static func goTarget(_ key: Character) -> GoTarget? {
        switch key {
        case "p": return .plan
        case "i": return .impl
        case "r": return .review
        case "f": return .freeform
        case "a": return .activity
        case "d": return .done
        case "s": return .settings
        default:  return nil
        }
    }
}
