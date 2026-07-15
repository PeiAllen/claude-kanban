import XCTest
import OrchestraKit
@testable import OrchestraCore

/// The daemon's device-token store (N1): register/replace-by-clientId, unregister, and durable
/// round-trip. No APNs, no network.
final class DeviceTokenStoreTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "device-tokens-\(UUID().uuidString).json"
    }

    private func reg(client: String, token: String) -> DeviceRegistration {
        DeviceRegistration(token: token, clientId: client,
                           prefs: NotificationPrefs(defaults: UserDefaults(suiteName: "dts-\(UUID().uuidString)")!).snapshot())
    }

    /// A syntactically valid 64-hex APNs device token, seeded by `n` so tests can tell tokens apart.
    private func validToken(_ n: Int) -> String { String(format: "%064x", n) }

    func testRegisterAndReadBack() async throws {
        let store = DeviceTokenStore(path: tempPath())
        let tok = validToken(0xAA)
        try await store.register(reg(client: "c1", token: tok))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.token, tok)
    }

    func testReRegisterReplacesSameClient() async throws {
        let store = DeviceTokenStore(path: tempPath())
        let old = validToken(1), new = validToken(2)
        try await store.register(reg(client: "c1", token: old))
        try await store.register(reg(client: "c1", token: new))   // same client, new token
        let all = await store.all()
        XCTAssertEqual(all.count, 1, "same clientId must replace, not accumulate")
        XCTAssertEqual(all.first?.token, new)
    }

    func testDistinctClientsCoexist() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: validToken(1)))
        try await store.register(reg(client: "c2", token: validToken(2)))
        let all = await store.all()
        XCTAssertEqual(Set(all.map(\.clientId)), ["c1", "c2"])
    }

    func testUnregisterIsIdempotent() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: validToken(1)))
        try await store.unregister(clientId: "c1")
        try await store.unregister(clientId: "c1")   // no-op, no throw
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testPersistsAcrossInstances() async throws {
        let path = tempPath()
        let tok = validToken(1)
        let a = DeviceTokenStore(path: path)
        try await a.register(reg(client: "c1", token: tok))
        // A fresh store reading the same file sees the registration.
        let b = DeviceTokenStore(path: path)
        let all = await b.all()
        XCTAssertEqual(all.first?.token, tok)
    }

    func testServiceRegisterRoundTrips() async throws {
        let base = NSTemporaryDirectory() + "unit-\(UUID().uuidString)"
        let service = OrchestraService(config: Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees",
                                                      allowlist: [base], scratchRoot: base + "/scratch",
                                                      runtimeStateDir: base + "/state"),
                                       store: TaskStore(path: tempPath()),
                                       devices: DeviceTokenStore(path: tempPath()),
                                       proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
        _ = try await service.registerDevice(reg(client: "c1", token: validToken(1)))
        let devices = await service.registeredDevices()
        XCTAssertEqual(devices.first?.clientId, "c1")
        try await service.unregisterDevice(clientId: "c1")
        let after = await service.registeredDevices()
        XCTAssertTrue(after.isEmpty)
    }

    // Fix #1(a) — a malformed token (non-hex / not exactly 64 chars) is rejected at the store boundary,
    // so it can never reach the sender's `URL(string:)`. Only the real APNs format (64 hex) is admitted —
    // the owner's phone is the only registrant, and it always sends 64 hex chars.
    func testRejectsMalformedTokenAtRegistration() async throws {
        let store = DeviceTokenStore(path: tempPath())
        for bad in ["", "xyz", "aa", "g".repeated(64), "abcd ef01" + String(repeating: "0", count: 56),
                    String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                    String(repeating: "a", count: 32), String(repeating: "f", count: 200)] {
            do {
                try await store.register(reg(client: "c", token: bad))
                XCTFail("expected badToken for \(bad.debugDescription)")
            } catch PushError.badToken { /* expected */ }
        }
        let stored = await store.all()
        XCTAssertTrue(stored.isEmpty, "no malformed token was stored")
        // Valid: exactly 64 hex chars (upper- and lower-case both accepted).
        for good in [validToken(0xdeadbeef), String(repeating: "A", count: 64), String(repeating: "f", count: 64)] {
            XCTAssertTrue(DeviceTokenStore.isValidToken(good), "\(good.prefix(8))… should be valid")
        }
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
