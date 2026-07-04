import Foundation

/// Modifier keys on a `KeyChord`, as a set. Kept AppKit-free (no `NSEvent`) so the keyboard decision
/// logic stays in the pure, offline-testable core; the App maps `NSEvent.modifierFlags` onto this.
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let command = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let option  = KeyModifiers(rawValue: 1 << 3)
}

/// A single key press: the character (already resolved for shift, e.g. `H`) plus its modifier set.
public struct KeyChord: Equatable, Sendable {
    public let key: Character
    public let mods: KeyModifiers
    public init(_ key: Character, _ mods: KeyModifiers = []) { self.key = key; self.mods = mods }
}

/// Which surface currently owns the keyboard — derived from the first responder + model state, never
/// a stored global mode. Determines how a chord is interpreted (or whether it passes through).
public enum KeyContext: Sendable, Equatable { case board, terminal, field, overlay }

/// A spatial direction for selection movement, pane focus, and card carry.
public enum Direction: Sendable, Equatable { case up, down, left, right }

/// A yank (copy) target on the selected card.
public enum CopyTarget: Sendable, Equatable { case chatLink, tmux, path }

/// A `g`-prefixed go-to destination.
public enum GoTarget: String, Sendable, CaseIterable, Equatable {
    case plan, impl, review, freeform, activity, done, settings
}

/// The resolved meaning of a chord in a context — a pure value the App executes against `BoardModel`.
public enum KeyIntent: Equatable, Sendable {
    case moveSelection(Direction)   // bare hjkl — move selection within a pane
    case selectEnd(first: Bool)     // gg / G — first/last card of the column
    case openInspector              // Enter
    case closeOrClear               // Esc — peel the frontmost thing
    case enterTerminal              // i — focus the agent terminal to type
    case focusPane(Direction)       // Ctrl-hjkl — spatial pane focus
    case carry(Direction)           // H/L — carry the selected card across columns
    case spawn                      // c — open the spawn sheet
    case newCard                    // Cmd-N — open the spawn sheet
    case archive                    // a — archive the selected card
    case openInZed                  // o — View changes in Zed
    case openNotes                  // O — open the card's worktree as an Obsidian vault, on its changed notes
    case toggleDiff                 // d — toggle Agent/Diff inspector view
    case openInbox                  // I — open the inbox editor
    case copy(CopyTarget)           // yc/yt/yp — yank
    case beginGoTo                  // g — begin a go-to sequence
    case goTo(GoTarget)             // g<letter> — jump to a region
    case search                     // / — search/filter cards
    case searchNext                 // n — next search match
    case searchPrev                 // N — previous search match
    case help                       // ? — help overlay
    case newShell                   // t / Cmd-T — new shell tab
    case closeFrontmost             // Cmd-W — close the frontmost thing
    case resize(Direction)          // Ctrl-Shift-hjkl — grow/shrink the focused pane's edge
    case toggleCollapse             // z — collapse/expand the focused dock/panel
    case hint                       // f — link-hint overlay (jump to any card)
    case palette                    // : — command palette
}
