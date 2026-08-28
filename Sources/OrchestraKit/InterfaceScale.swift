import Foundation

/// A user-initiated change to either the interface scale or the terminal font size.
public enum ZoomAction: Equatable, Sendable {
    case increase
    case decrease
    case reset
}

/// Source-compatible name for the existing desktop terminal zoom API.
public typealias TerminalZoomAction = ZoomAction

/// The persisted desktop interface-scale policy. This stays free of SwiftUI and AppKit so each window
/// can derive its fitting scale from plain dimensions, and the keyboard/menu behavior stays testable.
public enum InterfaceScale {
    /// A client-safe size used for fitting a logical canvas into a physical viewport.
    public struct Size: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public static let preferenceKey = "orch_interface_scale"
    public static let defaultScale = 1.0
    public static let minimumScale = 0.5
    public static let maximumScale = 2.0
    public static let step = 0.1

    /// Every scale that may be selected by the desktop appearance picker, in display order.
    public static let supportedScales: [Double] = (5...20).map { Double($0) / 10 }

    /// Recovers a persisted preference to the nearest supported tenth. Missing or non-finite data uses
    /// the default, while finite values outside the policy bounds clamp to the nearest legal endpoint.
    public static func normalized(_ scale: Double?) -> Double {
        guard let scale, scale.isFinite else { return defaultScale }
        let bounded = min(max(scale, minimumScale), maximumScale)
        let steps = (bounded / step).rounded()
        return min(max(steps * step, minimumScale), maximumScale)
    }

    /// Returns the next persisted target for a zoom command, safely clamped to the supported range.
    public static func scale(after action: ZoomAction, current: Double?) -> Double {
        switch action {
        case .reset:
            return defaultScale
        case .increase:
            return normalized(normalized(current) + step)
        case .decrease:
            return normalized(normalized(current) - step)
        }
    }

    /// The highest supported scale that fits a logical canvas entirely in its physical viewport.
    /// The enclosing macOS windows enforce their own physical minima, so a pathological viewport below
    /// the 50% minimum still returns the minimum selectable scale rather than inventing another state.
    public static func maximumFittingScale(viewport: Size, minimumLogicalSize: Size) -> Double {
        guard viewport.width.isFinite, viewport.height.isFinite,
              minimumLogicalSize.width.isFinite, minimumLogicalSize.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              minimumLogicalSize.width > 0, minimumLogicalSize.height > 0 else {
            return minimumScale
        }

        let ratio = min(viewport.width / minimumLogicalSize.width,
                        viewport.height / minimumLogicalSize.height)
        let flooredSteps = floor(ratio / step)
        return min(max(flooredSteps * step, minimumScale), maximumScale)
    }

    /// The scale a particular window can apply without overflow. The requested target is retained by
    /// the caller, so a larger viewport can later restore it without changing persisted preferences.
    public static func effectiveScale(requested: Double?, viewport: Size, minimumLogicalSize: Size) -> Double {
        min(normalized(requested),
            maximumFittingScale(viewport: viewport, minimumLogicalSize: minimumLogicalSize))
    }

    /// Converts a global physical drag translation into logical canvas points using the scale captured
    /// at gesture start. This preserves persisted dimensions across interface-scale changes.
    public static func logicalDistance(fromPhysical distance: Double, scale: Double) -> Double {
        distance / normalized(scale)
    }
}
