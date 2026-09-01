#if os(macOS)
import XCTest
import UserNotifications
@testable import OrchestraUI
import OrchestraKit

/// Part B (Lens-1 HIGH #2): the macOS `AgentNotifier` now consumes the shared push core instead of
/// duplicating it. These lock the two things that decide a banner — the fire gate and the body text —
/// to the shared core (so a Mac banner can't drift from a phone push), plus the ONE macOS-specific
/// mapping the notifier still owns: `NotifySound` → `UNNotificationSound`.
///
/// (The notifier itself installs a `UNUserNotificationCenter.current().delegate` in `init`, which needs
/// an app bundle a headless test process lacks — so these exercise the pure/static decision surface,
/// which is exactly where the de-duplicated logic lives.)
final class AgentNotifierTests: XCTestCase {

    /// `.none` → silent (nil); every audible pref → a real sound. This is the one piece of behavior the
    /// client-safe core can't express, so it's the piece worth pinning here.
    func testSoundMappingHonorsNoneVsAudible() {
        XCTAssertNil(AgentNotifier.sound(for: .none), "None must be silent (nil sound)")
        XCTAssertNotNil(AgentNotifier.sound(for: .systemDefault))
        XCTAssertNotNil(AgentNotifier.sound(for: .hero))
        XCTAssertNotNil(AgentNotifier.sound(for: .basso))
        XCTAssertNotNil(AgentNotifier.sound(for: .submarine))
    }

    /// The notifier fires per `PushGate` (shared) — `.always` always, `.background` only when the app is
    /// backgrounded, `.off` never — the exact semantics the old private `shouldFire` hard-coded.
    func testFireGateComesFromSharedPushGate() {
        XCTAssertTrue(PushGate.shouldPresent(scope: .always, appForeground: true))
        XCTAssertTrue(PushGate.shouldPresent(scope: .always, appForeground: false))
        XCTAssertFalse(PushGate.shouldPresent(scope: .background, appForeground: true))
        XCTAssertTrue(PushGate.shouldPresent(scope: .background, appForeground: false))
        XCTAssertFalse(PushGate.shouldPresent(scope: .off, appForeground: true))
        XCTAssertFalse(PushGate.shouldPresent(scope: .off, appForeground: false))
    }

    /// The banner body is the shared `APNsPayload.body` wording (what `content.body` is set to) — the same
    /// strings the old private `body(for:)` returned, now single-sourced with the phone push.
    func testBodyTextComesFromSharedPayload() {
        XCTAssertEqual(APNsPayload.body(for: .humanRequired), "Agent needs you — open harness")
        XCTAssertEqual(APNsPayload.body(for: .died), "Agent session ended — needs recovery")
    }

    /// The per-Mac defaults the notifier reads (via `NotificationPrefs`) match the historically-shipped
    /// scheme: human-required always/Hero, died always/Basso.
    func testDefaultsMatchShippedNotifierScheme() {
        XCTAssertEqual(NotificationPrefs.defaultScope(.humanRequired), .always)
        XCTAssertEqual(NotificationPrefs.defaultSound(.humanRequired), .hero)
        XCTAssertEqual(NotificationPrefs.defaultScope(.died), .always)
        XCTAssertEqual(NotificationPrefs.defaultSound(.died), .basso)
    }
}
#endif
