import XCTest
import SwiftUI
@testable import OrchestraUI

/// Pins the reader's Theme→CSS conversion.
///
/// The regression this exists for: the payload used to convert every color to `#rrggbb`, which drops
/// alpha. Half of `Theme` is translucent OVERLAY colors — `chip` is black at 5%, `hair` black at 9% —
/// so a light-mode reader painted `#000000` behind every inline code span, every fenced block, and
/// every table header. The test asserts the property that prevents it: a translucent color must never
/// come out as an opaque CSS color.
final class DocumentReaderThemeTests: XCTestCase {

    // MARK: - alpha survives

    func testTranslucentColorKeepsItsAlpha() {
        let c = Color(r: 0, g: 0, b: 0, a: 0.05).cssColor
        XCTAssertEqual(c, "rgba(0, 0, 0, 0.05)")
    }

    func testOpaqueColorIsEmittedWithoutAnAlphaChannel() {
        XCTAssertEqual(Color(hex: 0x1D1D1F).cssColor, "rgb(29, 29, 31)")
    }

    /// THE bug, stated as the theme tokens that carried it. Both are overlays in both appearances, so
    /// neither may ever resolve to a solid fill.
    func testChipAndHairAreNeverOpaqueInEitherAppearance() {
        for scheme in [ColorScheme.light, .dark] {
            let theme = Theme(scheme: scheme, accent: .blue)
            for (name, css) in [("chip", theme.chip.cssColor), ("hair", theme.hair.cssColor)] {
                XCTAssertTrue(css.hasPrefix("rgba("),
                              "\(name) in \(scheme) resolved to an opaque \(css) — code blocks and "
                              + "table borders would paint a solid slab over the page")
            }
        }
    }

    // MARK: - alpha formatting

    /// The coordinator skips the render when the serialized payload is byte-identical to the last one,
    /// which is what stops a keystroke in the compose field from rebuilding the DOM and dropping the
    /// user's highlights. A float that printed differently run to run would defeat that.
    func testAlphaFormattingIsStableAndTrimmed() {
        let c = Color(r: 255, g: 255, b: 255, a: 0.1)
        XCTAssertEqual(c.cssColor, c.cssColor)
        XCTAssertEqual(c.cssColor, "rgba(255, 255, 255, 0.1)")
        XCTAssertEqual(Color(r: 1, g: 2, b: 3, a: 0.5).cssColor, "rgba(1, 2, 3, 0.5)")
    }

    /// A fully transparent color still has to round-trip as `rgba(…, 0)` rather than as `rgb(…)`,
    /// or an invisible token becomes a solid one.
    func testFullyTransparentStaysTransparent() {
        XCTAssertEqual(Color(r: 0, g: 0, b: 0, a: 0).cssColor, "rgba(0, 0, 0, 0)")
    }

    // MARK: - explicit alpha

    /// `cssRGBA` OVERRIDES the color's own alpha. The selection tint and the change flash both need a
    /// known alpha so the text under them stays readable, whatever the source color happens to be.
    func testExplicitAlphaOverridesTheColorsOwn() {
        XCTAssertEqual(Color(r: 10, g: 132, b: 255, a: 1).cssRGBA(0.16), "rgba(10, 132, 255, 0.16)")
        XCTAssertEqual(Color(r: 10, g: 132, b: 255, a: 0.2).cssRGBA(0.16), "rgba(10, 132, 255, 0.16)")
    }
}
