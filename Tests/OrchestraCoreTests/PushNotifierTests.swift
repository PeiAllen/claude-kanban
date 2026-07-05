import XCTest
import OrchestraKit
@testable import OrchestraCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The daemon push emitter (N1) end-to-end through a mock sender: the transition→intent→gate→send path,
/// per-device scope gating, background-wait suppression, and the APNs JWT/request construction. No real
/// APNs, no network.
final class PushNotifierTests: XCTestCase {

    /// Records every (payload, token) a sender was asked to deliver.
    actor MockPushSender: PushSender {
        private(set) var sends: [(payload: JSONValue, token: String)] = []
        func send(payload: JSONValue, to token: String) async throws {
            sends.append((payload, token))
        }
        func recorded() -> [(payload: JSONValue, token: String)] { sends }
    }

    private func tempPath() -> String { NSTemporaryDirectory() + "pn-\(UUID().uuidString).json" }

    private func card(id: UUID = UUID(), status: AgentStatus, wait: WaitReason? = nil,
                      dead: DeadReason? = nil) -> Task {
        Task(id: id, title: "Card", repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
             status: status, deadReason: dead, waitReason: wait, ctxPct: 0, initialPrompt: "Card")
    }

    private func prefs(_ scope: NotifyScope) -> NotifyPrefsSnapshot {
        let e = NotifyPrefsSnapshot.Entry(scope: scope, sound: .glass)
        return NotifyPrefsSnapshot(permission: e, needsYou: e, died: e)
    }

    private func makeService() -> OrchestraService {
        OrchestraService(config: Config(), store: TaskStore(path: tempPath()),
                         devices: DeviceTokenStore(path: tempPath()))
    }

    func testTransitionFansOutToRegisteredDevice() async throws {
        let service = makeService()
        try await service.registerDevice(DeviceRegistration(token: "tokA", clientId: "cA", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))          // first sighting: no fire
        await notifier.handle(.taskUpserted(card(id: id, status: .waiting, wait: .permission)))  // running→waiting

        let sends = await mock.recorded()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.token, "tokA")
        XCTAssertEqual(sends.first?.payload["trigger"]?.stringValue, "permission")
        XCTAssertEqual(sends.first?.payload["aps"]?["sound"]?.stringValue, "Glass.aiff")
    }

    func testOffScopeDeviceGetsNoPush() async throws {
        let service = makeService()
        try await service.registerDevice(DeviceRegistration(token: "off", clientId: "cOff", prefs: prefs(.off)))
        try await service.registerDevice(DeviceRegistration(token: "on", clientId: "cOn", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .dead, dead: .agentExited)))

        let sends = await mock.recorded()
        XCTAssertEqual(sends.map(\.token), ["on"], "the .off device must be dropped at source")
    }

    func testBackgroundWaitProducesNoPush() async throws {
        let service = makeService()
        try await service.registerDevice(DeviceRegistration(token: "t", clientId: "c", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        // A card on a background task stays .running across snapshots — never a .waiting transition.
        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))

        let sends = await mock.recorded()
        XCTAssertTrue(sends.isEmpty, "a background-waiting (still-running) card must never push")
    }

    func testRemovedCardIsForgotten() async throws {
        let service = makeService()
        try await service.registerDevice(DeviceRegistration(token: "t", clientId: "c", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskRemoved(id))
        // Re-created with the same id is a fresh card (prev == nil) — the first waiting sighting won't fire.
        await notifier.handle(.taskUpserted(card(id: id, status: .waiting, wait: .humanTurn)))
        let sends = await mock.recorded()
        XCTAssertTrue(sends.isEmpty)
    }

    // MARK: APNs request + JWT construction

    func testAPNsConfigFromEnv() {
        XCTAssertNil(APNsConfig.from(env: [:]))
        let env = ["ORCH_APNS_KEY_PATH": "/k.p8", "ORCH_APNS_KEY_ID": "KID",
                   "ORCH_APNS_TEAM_ID": "TID", "ORCH_APNS_TOPIC": "com.orchestra.ios"]
        let cfg = APNsConfig.from(env: env)
        XCTAssertEqual(cfg?.host, "api.sandbox.push.apple.com")   // default env is sandbox
        XCTAssertEqual(APNsConfig.from(env: env.merging(["ORCH_APNS_ENV": "production"]) { $1 })?.host,
                       "api.push.apple.com")
    }

    func testAPNsRequestShape() throws {
        let cfg = APNsConfig(keyPath: "/k.p8", keyId: "KID", teamId: "TID",
                             topic: "com.orchestra.ios", production: true)
        let sender = APNsHTTPSender(config: cfg)
        let intent = NotificationIntent(trigger: .died, cardId: UUID(), cardTitle: "x", cardRef: "x")
        let payload = APNsPayload.build(intent: intent, sound: .basso)
        let req = try sender.makeRequest(payload: payload, token: "abc123")
        XCTAssertEqual(req.url?.absoluteString, "https://api.push.apple.com/3/device/abc123")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apns-topic"), "com.orchestra.ios")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertNotNil(req.httpBody)
    }

    func testJWTUnsignedTokenIsTwoBase64urlSegments() throws {
        let unsigned = try APNsJWT.unsignedToken(keyId: "KID", teamId: "TID", iat: 1_700_000_000)
        let parts = unsigned.split(separator: ".")
        XCTAssertEqual(parts.count, 2)
        // base64url alphabet only (no +/=).
        XCTAssertFalse(unsigned.contains("+") || unsigned.contains("/") || unsigned.contains("="))
    }

    #if canImport(CryptoKit)
    func testES256SigningRoundTrip() throws {
        // Generate a P-256 key, write its PEM as a stand-in .p8, and verify the sender signs a valid,
        // verifiable ES256 provider token. (This exercises the signing path; the live APNs POST is the
        // deferred part.)
        let key = P256.Signing.PrivateKey()
        let path = NSTemporaryDirectory() + "authkey-\(UUID().uuidString).p8"
        try key.pemRepresentation.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = APNsConfig(keyPath: path, keyId: "KID", teamId: "TID", topic: "t", production: false)
        let jwt = try APNsHTTPSender(config: cfg).signedProviderToken(iat: 1_700_000_000)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "a signed JWT has header.claims.signature")

        // Verify the signature over header.claims with the public key.
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        func unb64url(_ s: Substring) -> Data {
            var t = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)!
        }
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: unb64url(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: signingInput))
    }
    #endif
}
