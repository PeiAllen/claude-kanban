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

    func testRegisterAndReadBack() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: "aa"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.token, "aa")
    }

    func testReRegisterReplacesSameClient() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: "old"))
        try await store.register(reg(client: "c1", token: "new"))   // same client, new token
        let all = await store.all()
        XCTAssertEqual(all.count, 1, "same clientId must replace, not accumulate")
        XCTAssertEqual(all.first?.token, "new")
    }

    func testDistinctClientsCoexist() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: "a"))
        try await store.register(reg(client: "c2", token: "b"))
        let all = await store.all()
        XCTAssertEqual(Set(all.map(\.clientId)), ["c1", "c2"])
    }

    func testUnregisterIsIdempotent() async throws {
        let store = DeviceTokenStore(path: tempPath())
        try await store.register(reg(client: "c1", token: "a"))
        try await store.unregister(clientId: "c1")
        try await store.unregister(clientId: "c1")   // no-op, no throw
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testPersistsAcrossInstances() async throws {
        let path = tempPath()
        let a = DeviceTokenStore(path: path)
        try await a.register(reg(client: "c1", token: "tok"))
        // A fresh store reading the same file sees the registration.
        let b = DeviceTokenStore(path: path)
        let all = await b.all()
        XCTAssertEqual(all.first?.token, "tok")
    }

    func testServiceRegisterRoundTrips() async throws {
        let service = OrchestraService(config: Config(),
                                       store: TaskStore(path: tempPath()),
                                       devices: DeviceTokenStore(path: tempPath()))
        _ = try await service.registerDevice(reg(client: "c1", token: "tok"))
        let devices = await service.registeredDevices()
        XCTAssertEqual(devices.first?.clientId, "c1")
        try await service.unregisterDevice(clientId: "c1")
        let after = await service.registeredDevices()
        XCTAssertTrue(after.isEmpty)
    }
}
