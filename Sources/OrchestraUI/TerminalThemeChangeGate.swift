/// The RGB values that make up a terminal's default theme, quantized to SwiftTerm's 16-bit channels.
/// Keeping this value type independent of a platform color lets the desktop and future terminal hosts
/// avoid a costly redraw when unrelated task state refreshes their representable.
public struct TerminalThemeColor: Equatable, Sendable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The two application-controlled colors SwiftTerm exposes as the terminal's defaults.
public struct TerminalThemeSignature: Equatable, Sendable {
    public let background: TerminalThemeColor
    public let foreground: TerminalThemeColor

    public init(background: TerminalThemeColor, foreground: TerminalThemeColor) {
        self.background = background
        self.foreground = foreground
    }
}

/// Suppresses redundant terminal-theme application between SwiftUI updates.
///
/// Board telemetry can update while a terminal is rendering. Reassigning the same default colors makes
/// SwiftTerm clear its cached attributes and schedule a full display, so only a real palette change should
/// take that path.
public struct TerminalThemeChangeGate: Sendable {
    private var lastApplied: TerminalThemeSignature?

    public init() {}

    public mutating func shouldApply(_ signature: TerminalThemeSignature) -> Bool {
        guard lastApplied != signature else { return false }
        lastApplied = signature
        return true
    }
}
