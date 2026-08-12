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

    /// `#rrggbb` — for colors the stylesheet uses opaquely.
    var cssHex: String {
        let (r, g, b, _) = rgbaComponents()
        return String(format: "#%02x%02x%02x",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// `rgba(r, g, b, a)` with an explicit alpha — for the selection tint and the change flash, which
    /// must let the text under them stay readable.
    func cssRGBA(_ alpha: Double) -> String {
        let (r, g, b, _) = rgbaComponents()
        return "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), "
             + "\(Int((b * 255).rounded())), \(alpha))"
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
