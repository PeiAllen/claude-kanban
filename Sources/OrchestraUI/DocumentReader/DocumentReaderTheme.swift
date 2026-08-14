import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bridges the app's `Theme` colors into the CSS custom properties the reader's stylesheet consumes.
///
/// Kept here, beside the reader, rather than widened onto `Theme` itself: nothing else in the app needs
/// a color as a CSS string, and `Theme`'s public surface should not grow for one consumer.
extension Color {

    /// THE conversion the payload uses. It keeps the color's OWN alpha: opaque colors become `rgb(…)`
    /// and translucent ones become `rgba(…)`.
    ///
    /// This exists because the obvious `#rrggbb` form silently discards alpha, and half of `Theme` is
    /// built from translucent OVERLAY colors — `chip` is black at 5% over a white card, `hair` is black
    /// at 9%. Sent as hex, those became `#000000`, so every inline code span, every fenced block, and
    /// every table header in the reader painted solid black (solid white in dark mode). One function
    /// that can never drop an alpha is the fix, so there is deliberately no hex variant to reach for.
    var cssColor: String {
        let (r, g, b, a) = rgbaComponents()
        let (r8, g8, b8) = (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        guard a < 0.999 else { return "rgb(\(r8), \(g8), \(b8))" }
        return "rgba(\(r8), \(g8), \(b8), \(Self.css(a)))"
    }

    /// `rgba(r, g, b, a)` with an EXPLICIT alpha, which overrides the color's own — for the selection
    /// tint and the change flash, which must let the text under them stay readable whatever the source
    /// color's alpha happens to be.
    func cssRGBA(_ alpha: Double) -> String {
        let (r, g, b, _) = rgbaComponents()
        return "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), "
             + "\(Int((b * 255).rounded())), \(Self.css(alpha)))"
    }

    /// Three decimals, with no trailing zeros. Keeps the payload stable across renders — the coordinator
    /// compares the serialized payload to decide whether to rebuild the DOM, so a float that prints
    /// differently run to run would rebuild the page and drop the user's highlights.
    private static func css(_ a: Double) -> String {
        let s = String(format: "%.3f", a)
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }

    /// Resolve to concrete components. `Theme` builds its colors from literal RGB rather than asset
    /// catalogs, so this never has to resolve a dynamic appearance — but it falls back to opaque black
    /// rather than trapping if a future color cannot be converted.
    private func rgbaComponents() -> (Double, Double, Double, Double) {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return (0, 0, 0, 1) }
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}
