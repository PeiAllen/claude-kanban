import Foundation

/// The pure keyboard dispatch table: given a chord, the current context, and whether a `g` go-to
/// sequence is in flight, return the intent to execute (or nil to let the key pass through to the
/// terminal / text field / overlay). No UI, no state — the App holds the `awaitingGoTo` flag and the
/// `y`-yank prefix, and executes whatever intent this returns.
public enum KeyMap {
    public static func intent(for chord: KeyChord, in ctx: KeyContext, awaitingGoTo: Bool) -> KeyIntent? {
        // Cmd accelerators apply in every context (terminals ignore Cmd, so these never collide).
        if chord.mods.contains(.command) {
            switch chord.key {
            case "n": return .newCard
            case "t": return .newShell
            case "w": return .closeFrontmost
            default:  return nil
            }
        }
        // Ctrl-Shift-hjkl: resize the focused pane's edge (board / terminal only).
        if chord.mods.contains(.control), chord.mods.contains(.shift), let dir = direction(chord.key) {
            return (ctx == .board || ctx == .terminal) ? .resize(dir) : nil
        }
        // Ctrl-hjkl: pane focus on the board / in a terminal; only vertical (form/dropdown) in a field.
        if chord.mods.contains(.control), let dir = direction(chord.key) {
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
            return chord.key == "\u{1B}" ? .closeOrClear : nil
        case .board:
            return boardIntent(chord, awaitingGoTo: awaitingGoTo)
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
        case "o": return .openInZed
        case "d": return .toggleDiff
        case "t": return .newShell
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
