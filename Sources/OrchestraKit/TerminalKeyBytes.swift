import Foundation

/// Canonical byte sequences for the special keys a soft keyboard lacks — what the phone takeover
/// accessory bar (PR T4) sends into the live PTY. Pure and platform-neutral (no UIKit), so it is the one
/// source of truth for these encodings and is unit-tested by `swift test`. Provider-neutral: these are
/// standard xterm/VT sequences the agent's TUI (Claude or Codex) already understands — no `agent==` fork.
///
/// The encodings match what a real `xterm-256color` PTY delivers (the `TERM` the iOS SSH PTY requests),
/// so a tapped `Up` is indistinguishable from a hardware arrow key to the agent.
public enum TerminalKey: String, CaseIterable, Sendable {
    case esc, tab, enter
    case up, down, left, right
    case pageUp, pageDown, home, end

    /// The raw bytes to write to the PTY for this key.
    public var bytes: [UInt8] {
        switch self {
        case .esc:      return [0x1b]
        case .tab:      return [0x09]
        case .enter:    return [0x0d]           // CR — the Return key (tmux/agents translate as needed)
        case .up:       return [0x1b, 0x5b, 0x41]   // ESC [ A
        case .down:     return [0x1b, 0x5b, 0x42]   // ESC [ B
        case .right:    return [0x1b, 0x5b, 0x43]   // ESC [ C
        case .left:     return [0x1b, 0x5b, 0x44]   // ESC [ D
        case .pageUp:   return [0x1b, 0x5b, 0x35, 0x7e]   // ESC [ 5 ~
        case .pageDown: return [0x1b, 0x5b, 0x36, 0x7e]   // ESC [ 6 ~
        case .home:     return [0x1b, 0x5b, 0x48]   // ESC [ H
        case .end:      return [0x1b, 0x5b, 0x46]   // ESC [ F
        }
    }
}

/// Apply a "sticky Ctrl" modifier to a run of typed bytes: a printable ASCII byte becomes its control
/// code (`byte & 0x1f`), so Ctrl + `c` → 0x03 (SIGINT), Ctrl + `d` → 0x04 (EOF), Ctrl + `[` → 0x1b (Esc).
///
/// - Only the standard control range is transformed: letters `@`(0x40)…`_`(0x5f) and lowercase `a`…`z`
///   (folded up first, matching a real terminal, so Ctrl+`c` and Ctrl+`C` both give 0x03). Anything
///   outside that range (digits, arrows-as-escape-sequences, multi-byte input) passes through untouched,
///   which is what a hardware Ctrl does too.
/// - Applied to the first byte of the run only — the modifier is one keystroke, matching one-shot Ctrl.
public func applyControlModifier(to bytes: [UInt8]) -> [UInt8] {
    guard let first = bytes.first else { return bytes }
    let upper = (first >= 0x61 && first <= 0x7a) ? first - 0x20 : first   // fold a…z → A…Z
    guard upper >= 0x40 && upper <= 0x5f else { return bytes }            // only @…_ have a control code
    return [upper & 0x1f] + bytes.dropFirst()
}
