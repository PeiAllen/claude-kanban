import XCTest
import SwiftUI
@testable import OrchestraUI

/// Layer-2 seam tests: the no-op defaults are inert, and `PlatformUI` faithfully round-trips the
/// members it is handed. Consumer wiring (BoardModel routing through these) is exercised in Layer 3
/// via `FakePlatform`.

/// Recording spies. `@MainActor` (the protocols are main-actor) — which also makes them Sendable —
/// so the mutable call logs are safe to read back in the test.
@MainActor final class SpyClipboard: Clipboard {
    private(set) var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
}

@MainActor final class SpyOpener: SystemOpener {
    private(set) var openSettingsCount = 0
    func openSettings() { openSettingsCount += 1 }
}

@MainActor final class SpyWindow: WindowConfig {
    private(set) var resignCount = 0
    private(set) var enterCount = 0
    var enterReturns = true
    func resignInputFocus() { resignCount += 1 }
    func enterTerminalFocus() -> Bool { enterCount += 1; return enterReturns }
}

@MainActor
final class PlatformProtocolTests: XCTestCase {

    func testNoopDefaultsAreInert() {
        // No crash, no observable effect — the point is that iOS-before-F3 / previews can construct them.
        let c = NoopClipboard(); c.copy("x")
        let o = NoopSystemOpener(); o.openSettings()
        let w = NoopWindowConfig(); w.resignInputFocus()
        XCTAssertTrue(w.enterTerminalFocus())   // benign default: "focus succeeded"
    }

    func testPlatformUIRoundTripsMembers() {
        let clip = SpyClipboard()
        let open = SpyOpener()
        let win = SpyWindow()
        let ui = PlatformUI(clipboard: clip, opener: open, window: win)

        ui.clipboard.copy("hello")
        ui.opener.openSettings()
        _ = ui.window.enterTerminalFocus()
        ui.window.resignInputFocus()

        XCTAssertEqual(clip.copied, ["hello"])
        XCTAssertEqual(open.openSettingsCount, 1)
        XCTAssertEqual(win.enterCount, 1)
        XCTAssertEqual(win.resignCount, 1)
    }

    func testNoopBundleIsInert() {
        // The shared `.noop` bundle used as BoardModel's default.
        PlatformUI.noop.clipboard.copy("ignored")
        PlatformUI.noop.opener.openSettings()
        PlatformUI.noop.window.resignInputFocus()
    }
}
