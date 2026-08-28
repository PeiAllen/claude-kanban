import Foundation

/// A user-initiated change to the shared desktop terminal font size.
public enum TerminalZoomAction: Equatable, Sendable {
    case increase
    case decrease
    case reset
}

/// The persisted desktop terminal zoom policy. Keeping this AppKit-free makes the shortcut and
/// persistence behavior testable without constructing a SwiftTerm view.
public enum TerminalFontSize {
    public static let preferenceKey = "orch_terminal_font_size"
    public static let defaultPointSize = 12.5
    public static let minimumPointSize = 8.0
    public static let maximumPointSize = 32.0
    public static let step = 1.0

    /// Returns the next valid font size for a zoom command, recovering safely from a malformed value
    /// that may have been written to UserDefaults by an older build or external tool.
    public static func pointSize(after action: TerminalZoomAction, current: Double?) -> Double {
        switch action {
        case .reset:
            return defaultPointSize
        case .increase:
            return min(normalized(current) + step, maximumPointSize)
        case .decrease:
            return max(normalized(current) - step, minimumPointSize)
        }
    }

    /// Ensures a stored point size remains usable when a terminal view is first mounted.
    public static func normalized(_ pointSize: Double?) -> Double {
        guard let pointSize, pointSize.isFinite else { return defaultPointSize }
        return min(max(pointSize, minimumPointSize), maximumPointSize)
    }
}
