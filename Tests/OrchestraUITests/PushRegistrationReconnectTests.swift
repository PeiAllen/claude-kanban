import XCTest
import OrchestraKit
@testable import OrchestraUI

/// #7: the phone must re-register for push on reconnect. The APNs token routinely arrives before the
/// link is live, and the F3 dev transport can drop and rebuild `client` against a fresh socket; if a
/// registration lands while disconnected it was silently lost for the whole session (`registerForPush`
/// is best-effort `try?`). The fix RETAINS the token so the `connectionState → .live` edge can re-assert
/// it. These run daemon-free: a never-activated `BoardModel` has no transport, so `registerDevice` fails
/// fast (io error, swallowed) — only the retention/guard logic is exercised, never a live daemon.
@MainActor
final class PushRegistrationReconnectTests: XCTestCase {

    func testRegisterForPushRetainsTokenForReconnect() async {
        let model = BoardModel(platform: .noop)   // never activated → no transport
        XCTAssertNil(model.pushToken)
        await model.registerForPush(token: "deadbeef")
        // Retained even though the best-effort RPC couldn't reach a daemon — this is exactly what lets the
        // `.live` edge re-register instead of dropping the registration for the session (the #7 regression).
        XCTAssertEqual(model.pushToken, "deadbeef")
    }

    func testReregisterOnConnectIsNoOpWithoutToken() {
        let model = BoardModel(platform: .noop)
        // No token yet (macOS, or before the phone registers) → the reconnect hook is a guarded no-op.
        model.reregisterPushOnConnect()
        XCTAssertNil(model.pushToken)
    }

    func testReregisterOnConnectKeepsToken() async {
        let model = BoardModel(platform: .noop)
        await model.registerForPush(token: "cafe")
        model.reregisterPushOnConnect()        // spawns a best-effort re-register; token stays put
        XCTAssertEqual(model.pushToken, "cafe")
    }

    /// #1: writing a notification pref must RE-REGISTER the device with the fresh snapshot — otherwise the
    /// daemon keeps the scope/sound snapshot from the original registration and pushes a trigger the user
    /// just turned Off. The Settings screen posts `.orchNotificationPrefsChanged`; `BoardModel` observes
    /// it and re-registers. `lastRegisteredPrefs` records the snapshot handed over (even offline), so the
    /// re-register is observable without a live daemon.
    func testPrefChangeReregistersWithFreshSnapshot() async {
        let prefs = NotificationPrefs()
        let original = prefs.scope(.permission)
        defer { prefs.setScope(original, for: .permission) }   // don't leak into other tests

        let model = BoardModel(platform: .noop)
        await model.registerForPush(token: "cafe")
        XCTAssertEqual(model.lastRegisteredPrefs?.permission.scope, original)

        // Flip a pref and fire the same notification the Settings binding posts.
        let flipped: NotifyScope = (original == .off) ? .always : .off
        prefs.setScope(flipped, for: .permission)
        NotificationCenter.default.post(name: .orchNotificationPrefsChanged, object: nil)

        // The observer hops to the MainActor and spawns the re-register; give it a moment to run.
        for _ in 0..<20 where model.lastRegisteredPrefs?.permission.scope != flipped {
            try? await _Concurrency.Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.lastRegisteredPrefs?.permission.scope, flipped,
                       "a pref write must re-register with the updated snapshot")
    }
}
