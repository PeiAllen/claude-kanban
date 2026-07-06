import XCTest
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
}
