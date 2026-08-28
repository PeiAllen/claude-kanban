import Foundation

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

    /// The native SwiftTerm point size required beneath an interface canvas. The stored terminal size is
    /// deliberately physical, so the canvas multiplies this value back to the user's chosen 8–32pt font.
    /// At the interface-scale bounds the native rendering range is 4–64pt.
    public static func renderedPointSize(for pointSize: Double?, interfaceScale: Double) -> Double {
        normalized(pointSize) / InterfaceScale.normalized(interfaceScale)
    }
}
