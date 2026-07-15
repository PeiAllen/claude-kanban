import XCTest
import SwiftUI
@testable import OrchestraUI

/// Proves the `Theme` move into OrchestraUI is lossless: the concrete token values, the status
/// mapping, and the Accent/Density scales are all still exactly what the desktop shipped.
final class ThemeTests: XCTestCase {

    /// Resolve a SwiftUI `Color` to its sRGB components (macOS 14 / iOS 17 API), so we can assert on
    /// exact channel values rather than relying on `Color`'s opaque equality.
    private func rgba(_ c: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let r = c.resolve(in: EnvironmentValues())
        return (Double(r.red), Double(r.green), Double(r.blue), Double(r.opacity))
    }

    func testCoreTokenValuesUnchanged() {
        let dark = Theme(scheme: .dark, accent: .blue)
        // winBg dark == Color(hex: 0x1C1C1E)
        let bg = rgba(dark.winBg)
        XCTAssertEqual(bg.r, 28.0 / 255, accuracy: 0.002)
        XCTAssertEqual(bg.g, 28.0 / 255, accuracy: 0.002)
        XCTAssertEqual(bg.b, 30.0 / 255, accuracy: 0.002)
        XCTAssertEqual(bg.a, 1.0, accuracy: 0.001)

        let light = Theme(scheme: .light, accent: .blue)
        // winBg light == Color(hex: 0xF4F2EF)
        let lbg = rgba(light.winBg)
        XCTAssertEqual(lbg.r, 244.0 / 255, accuracy: 0.002)
        XCTAssertEqual(lbg.g, 242.0 / 255, accuracy: 0.002)
        XCTAssertEqual(lbg.b, 239.0 / 255, accuracy: 0.002)
    }

    func testStatusMappingUnchanged() {
        let t = Theme(scheme: .dark, accent: .blue)
        // running → green dot (0x30D158 in dark)
        let running = rgba(t.statusColor("running").dot)
        XCTAssertEqual(running.r, 48.0 / 255, accuracy: 0.002)
        XCTAssertEqual(running.g, 209.0 / 255, accuracy: 0.002)
        XCTAssertEqual(running.b, 88.0 / 255, accuracy: 0.002)

        XCTAssertEqual(t.statusLabel("running"), "Running")
        XCTAssertEqual(t.statusLabel("waiting"), "Waiting")
        XCTAssertEqual(t.statusLabel("done"), "Done")
        XCTAssertEqual(t.statusLabel("dead"), "Dead")
        XCTAssertEqual(t.statusLabel("anything-else"), "Idle")
    }

    func testAccentAndDensityScales() {
        XCTAssertEqual(Accent.allCases, [.blue, .purple, .graphite])
        XCTAssertEqual(Accent(rawValue: "purple"), .purple)

        XCTAssertEqual(Density.comfortable.cardPad, 12)
        XCTAssertEqual(Density.comfortable.cardGap, 10)
        XCTAssertEqual(Density.comfortable.cardTitle, 13.5)
        XCTAssertEqual(Density.compact.cardPad, 9)
        XCTAssertEqual(Density.compact.cardGap, 7)
        XCTAssertEqual(Density.compact.cardTitle, 12.5)

        // Accent.blue resolves to the documented system blues (dark 0x0A84FF / light 0x007AFF).
        let darkBlue = rgba(Accent.blue.color(dark: true))
        XCTAssertEqual(darkBlue.r, 10.0 / 255, accuracy: 0.002)
        XCTAssertEqual(darkBlue.g, 132.0 / 255, accuracy: 0.002)
        XCTAssertEqual(darkBlue.b, 255.0 / 255, accuracy: 0.002)
    }
}
