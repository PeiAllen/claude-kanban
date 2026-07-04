// Client-safe key-input value model for the constrained `send-keys` RPC. Lives in OrchestraKit
// alongside the rest of the keyboard vocabulary (KeyChord/Direction/…) so the iOS client can build
// chords; it stays free of Foundation.Process / AppKit / daemon types. Only the daemon's
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
