// Client-safe key-input value model for the constrained `send-keys` RPC. Lives in OrchestraKit
// alongside the rest of the keyboard vocabulary (KeyChord/Direction/…) so the iOS client can build
// chords; it stays free of process-spawning, AppKit, and daemon types. Only the daemon's
// SessionManager reads `tmuxToken`.

/// A named special key in the constrained send-keys vocabulary. The rawValue is the wire name the
/// phone sends; `tmuxToken` is the corresponding `tmux send-keys` key name.
public enum KeyName: String, Sendable, Codable, CaseIterable, Equatable {
    case esc      = "Esc"
    case up       = "Up"
    case down     = "Down"
    case left     = "Left"
    case right    = "Right"
    case tab      = "Tab"
    case enter    = "Enter"
    case ctrlC    = "C-c"
    case pageUp   = "PgUp"
    case pageDown = "PgDn"
    case home     = "Home"
    case end      = "End"

    /// The token passed to `tmux send-keys` (tmux's own key-name vocabulary).
    public var tmuxToken: String {
        switch self {
        case .esc:      return "Escape"
        case .up:       return "Up"
        case .down:     return "Down"
        case .left:     return "Left"
        case .right:    return "Right"
        case .tab:      return "Tab"
        case .enter:    return "Enter"
        case .ctrlC:    return "C-c"
        case .pageUp:   return "PPage"
        case .pageDown: return "NPage"
        case .home:     return "Home"
        case .end:      return "End"
        }
    }

    /// The raw byte sequence to write into a live PTY for this key — the standard xterm/VT encodings an
    /// `xterm-256color` TUI (Claude or Codex — provider-neutral) understands, so a tapped key is
    /// indistinguishable from a hardware key. Used by the iOS takeover accessory bar (PR T4); one
    /// vocabulary with `tmuxToken`/`rawValue` rather than a parallel `TerminalKey` enum. Unit-tested by
    /// `TerminalKeyBytesTests`.
    public var bytes: [UInt8] {
        switch self {
        case .esc:      return [0x1b]
        case .tab:      return [0x09]
        case .enter:    return [0x0d]           // CR — the Return key (tmux/agents translate as needed)
        case .ctrlC:    return [0x03]           // Ctrl-C → SIGINT
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

/// One element of a key chord: either a named special key or a run of literal text. A `send-keys`
/// request is an ordered `[KeyToken]`. There is deliberately no implicit Enter — Enter is `.named(.enter)`.
public enum KeyToken: Sendable, Equatable, Codable {
    case named(KeyName)
    case text(String)

    private enum CodingKeys: String, CodingKey { case key, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decodeIfPresent(KeyName.self, forKey: .key)
        let text = try c.decodeIfPresent(String.self, forKey: .text)
        switch (key, text) {
        case let (k?, nil): self = .named(k)
        case let (nil, t?): self = .text(t)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "each keys[] element needs exactly one of `key` or `text`"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .named(let k): try c.encode(k, forKey: .key)
        case .text(let t):  try c.encode(t, forKey: .text)
        }
    }
}
