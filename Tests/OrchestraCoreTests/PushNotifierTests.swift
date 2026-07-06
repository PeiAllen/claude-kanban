import XCTest
import OrchestraKit
@testable import OrchestraCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Async counterpart to `XCTAssertThrowsError` — fails if the async expression does not throw.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error to be thrown" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

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

    /// A sender that always throws a preset error — exercises the deliver loop's failure handling
    /// (410/400 dead-token → unregister vs. transient error → keep the token).
    actor FailingPushSender: PushSender {
        let error: Error
        private(set) var attempts = 0
        init(_ error: Error) { self.error = error }
        func send(payload: JSONValue, to token: String) async throws {
            attempts += 1
            throw error
        }
        func attemptCount() -> Int { attempts }
    }

    /// A syntactically valid 64-hex APNs device token, seeded by `n` so tests can tell devices apart.
    private func validToken(_ n: Int) -> String { String(format: "%064x", n) }

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
        let tokA = validToken(0xA)
        try await service.registerDevice(DeviceRegistration(token: tokA, clientId: "cA", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))          // first sighting: no fire
        await notifier.handle(.taskUpserted(card(id: id, status: .waiting, wait: .permission)))  // running→waiting

        let sends = await mock.recorded()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.token, tokA)
        XCTAssertEqual(sends.first?.payload["trigger"]?.stringValue, "permission")
        XCTAssertEqual(sends.first?.payload["aps"]?["sound"]?.stringValue, "Glass.aiff")
    }

    func testOffScopeDeviceGetsNoPush() async throws {
        let service = makeService()
        let tokOff = validToken(0x0FF), tokOn = validToken(0x0)
        try await service.registerDevice(DeviceRegistration(token: tokOff, clientId: "cOff", prefs: prefs(.off)))
        try await service.registerDevice(DeviceRegistration(token: tokOn, clientId: "cOn", prefs: prefs(.always)))
        let mock = MockPushSender()
        let notifier = PushNotifier(service: service, sender: mock)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .dead, dead: .agentExited)))

        let sends = await mock.recorded()
        XCTAssertEqual(sends.map(\.token), [tokOn], "the .off device must be dropped at source")
    }

    func testBackgroundWaitProducesNoPush() async throws {
        let service = makeService()
        try await service.registerDevice(DeviceRegistration(token: validToken(1), clientId: "c", prefs: prefs(.always)))
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
        try await service.registerDevice(DeviceRegistration(token: validToken(1), clientId: "c", prefs: prefs(.always)))
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

    // MARK: Fix #1 — malformed device token is rejected at registration (never reaches URL(string:))

    func testMalformedTokenIsRejectedAtRegistration() async throws {
        let service = makeService()
        // A token with a space is exactly what makes `URL(string:)` return nil and the old force-unwrap
        // trap — it must be rejected up front so it can never reach the sender.
        await XCTAssertThrowsErrorAsync(
            try await service.registerDevice(
                DeviceRegistration(token: "ab cd\n0123", clientId: "cBad", prefs: prefs(.always))))
        // And a non-hex / too-short token is rejected too.
        await XCTAssertThrowsErrorAsync(
            try await service.registerDevice(
                DeviceRegistration(token: "not-hex-!!", clientId: "cBad2", prefs: prefs(.always))))
        await XCTAssertThrowsErrorAsync(
            try await service.registerDevice(
                DeviceRegistration(token: "abcd", clientId: "cShort", prefs: prefs(.always))))
        // The rejected registrations left no entry behind.
        let all = await service.registeredDevices()
        XCTAssertTrue(all.isEmpty)
    }

    func testWellFormedTokenIsAccepted() async throws {
        let service = makeService()
        try await service.registerDevice(
            DeviceRegistration(token: validToken(1), clientId: "cOK", prefs: prefs(.always)))
        let all = await service.registeredDevices()
        XCTAssertEqual(all.map(\.clientId), ["cOK"])
    }

    // MARK: Fix #4 — APNs 410/400 dead-token is unregistered; transient errors are not

    func testDeadTokenUnregisteredOn410() async throws {
        let service = makeService()
        try await service.registerDevice(
            DeviceRegistration(token: validToken(1), clientId: "cA", prefs: prefs(.always)))
        let sender = FailingPushSender(PushError.badStatus(410, "Unregistered"))
        let notifier = PushNotifier(service: service, sender: sender)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .waiting, wait: .permission)))

        let remaining = await service.registeredDevices()
        XCTAssertTrue(remaining.isEmpty, "a 410 Unregistered must drop the dead token")
    }

    func testDeadTokenUnregisteredOn400BadDeviceToken() async throws {
        let service = makeService()
        try await service.registerDevice(
            DeviceRegistration(token: validToken(1), clientId: "cA", prefs: prefs(.always)))
        let sender = FailingPushSender(PushError.badStatus(400, "{\"reason\":\"BadDeviceToken\"}"))
        let notifier = PushNotifier(service: service, sender: sender)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .dead, dead: .agentExited)))

        let remaining = await service.registeredDevices()
        XCTAssertTrue(remaining.isEmpty, "a 400 BadDeviceToken must drop the dead token")
    }

    func testTransientErrorKeepsToken() async throws {
        let service = makeService()
        try await service.registerDevice(
            DeviceRegistration(token: validToken(1), clientId: "cA", prefs: prefs(.always)))
        let sender = FailingPushSender(PushError.badStatus(500, "InternalServerError"))
        let notifier = PushNotifier(service: service, sender: sender)

        let id = UUID()
        await notifier.handle(.taskUpserted(card(id: id, status: .running)))
        await notifier.handle(.taskUpserted(card(id: id, status: .waiting, wait: .permission)))

        let remaining = await service.registeredDevices()
        XCTAssertEqual(remaining.map(\.clientId), ["cA"], "a transient 500 must NOT drop the token")
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

    // Fix #1(b) — `makeRequest` must NEVER trap on a malformed token (the old `URL(string:)!`). The
    // behaviour is platform-dependent: Darwin's URL parser percent-encodes the odd char and builds a
    // request; swift-corelibs-foundation (the Linux daemon) returns nil and we throw `.badToken`. Either
    // outcome is acceptable — a fatal trap that crashes the daemon is not. This asserts the anti-trap
    // guarantee on whichever parser is present.
    func testMakeRequestNeverTrapsOnMalformedToken() {
        let cfg = APNsConfig(keyPath: "/k.p8", keyId: "KID", teamId: "TID", topic: "t", production: true)
        let sender = APNsHTTPSender(config: cfg)
        do {
            let req = try sender.makeRequest(payload: .object([:]), token: "ab cd\n\u{7f}")
            XCTAssertNotNil(req.url, "if it didn't throw, it must have built a (percent-encoded) URL")
        } catch PushError.badToken {
            // strict parser: threw instead of trapping — also correct.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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

    // Fix #6 — the provider JWT is cached and reused within the TTL, re-signed only once it's stale.
    func testProviderTokenIsCachedWithinTTLAndReSignedAfter() async throws {
        let key = P256.Signing.PrivateKey()
        let path = NSTemporaryDirectory() + "authkey-\(UUID().uuidString).p8"
        try key.pemRepresentation.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = APNsConfig(keyPath: path, keyId: "KID", teamId: "TID", topic: "t", production: false)
        let sender = APNsHTTPSender(config: cfg)
        let ttl = APNsHTTPSender.tokenTTLSeconds
        let t0 = 1_700_000_000

        let a = try await sender.providerToken(now: t0)
        // A later call still inside the TTL must return the SAME cached token — if it had re-minted, the
        // newer `iat` alone would change the JWT, so equality proves reuse regardless of ECDSA nonces.
        let b = try await sender.providerToken(now: t0 + ttl - 1)
        XCTAssertEqual(a, b, "within the TTL the provider token is reused, not re-minted")
        // Past the TTL it re-signs → a different token.
        let c = try await sender.providerToken(now: t0 + ttl + 1)
        XCTAssertNotEqual(a, c, "past the TTL the provider token is re-signed")
    }
    #endif
}
