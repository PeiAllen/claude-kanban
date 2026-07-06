import Foundation
import OrchestraKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// APNs delivery configuration, resolved from the environment. All fields are required for a real send;
/// if any is missing the daemon falls back to `DisabledPushSender` (push wired, delivery a no-op).
///
///   ORCH_APNS_KEY_PATH  — path to the APNs auth key (.p8, an ES256 private key)
///   ORCH_APNS_KEY_ID    — the auth key's Key ID (10 chars)
///   ORCH_APNS_TEAM_ID   — the Apple Developer Team ID (10 chars)
///   ORCH_APNS_TOPIC     — the app's bundle id (the `apns-topic`)
///   ORCH_APNS_ENV       — "sandbox" (default) or "production"
public struct APNsConfig: Sendable, Equatable {
    public var keyPath: String
    public var keyId: String
    public var teamId: String
    public var topic: String
    public var production: Bool

    public init(keyPath: String, keyId: String, teamId: String, topic: String, production: Bool) {
        self.keyPath = keyPath; self.keyId = keyId; self.teamId = teamId
        self.topic = topic; self.production = production
    }

    /// The APNs HTTP/2 host for this environment.
    public var host: String { production ? "api.push.apple.com" : "api.sandbox.push.apple.com" }

    /// Resolve from `env`; `nil` if any required field is absent/empty (→ push delivery disabled).
    public static func from(env: [String: String]) -> APNsConfig? {
        func v(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
        guard let keyPath = v("ORCH_APNS_KEY_PATH"), let keyId = v("ORCH_APNS_KEY_ID"),
              let teamId = v("ORCH_APNS_TEAM_ID"), let topic = v("ORCH_APNS_TOPIC") else { return nil }
        return APNsConfig(keyPath: keyPath, keyId: keyId, teamId: teamId, topic: topic,
                          production: (v("ORCH_APNS_ENV") ?? "sandbox").lowercased() == "production")
    }
}

public enum PushError: Error, Equatable {
    case unsupportedPlatform          // no CryptoKit (Linux/musl) — ES256 signing unavailable
    case keyUnreadable(String)
    case badStatus(Int, String)
    case badToken(String)             // device token isn't a valid APNs token (would trap URL(string:))
}

/// Provider auth-token (JWT) construction for APNs. The base64url encoding + the unsigned
/// `header.claims` string are pure and unit-tested; the ES256 signature is produced by CryptoKit on
/// Apple platforms (see `APNsHTTPSender`).
public enum APNsJWT {
    /// base64url without padding — the JOSE encoding.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The signing input: `base64url(header) + "." + base64url(claims)`. `iat` is passed in (not read
    /// from the clock) so it stays testable/deterministic.
    public static func unsignedToken(keyId: String, teamId: String, iat: Int) throws -> String {
        let header: [String: String] = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        let claims: [String: Any] = ["iss": teamId, "iat": iat]
        let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let c = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return base64url(h) + "." + base64url(c)
    }
}

/// The real APNs sender: builds the token-authenticated HTTP/2 request and POSTs the payload to Apple's
/// gateway. **The ES256 signing needs CryptoKit (Apple platforms only)** — on Linux/musl (a remote
/// Linux daemon) CryptoKit is unavailable and `send` reports `.unsupportedPlatform`; delivering push
/// from a Linux daemon is a documented follow-on (it needs swift-crypto, which would break the
/// dependency-free offline-build invariant). The request construction is exercised by unit tests; the
/// actual network POST to Apple's gateway is the part that requires a real auth key + device + is
/// deferred (see the N1 architecture note).
public actor APNsHTTPSender: PushSender {
    private let config: APNsConfig
    private let session: URLSession

    #if canImport(CryptoKit)
    /// The cached provider JWT and the unix time (`iat`) it was minted. Apple accepts a provider token
    /// for up to 1h and throttles frequent re-mints (429 TooManyProviderTokenUpdates), so we reuse one
    /// token for `tokenTTLSeconds` (~50 min) instead of signing on every send. Actor-isolated → race-free.
    private var cachedToken: (jwt: String, mintedAt: Int)?
    /// Re-sign only once the cached token is older than this. Well under Apple's 1h ceiling, comfortably
    /// above their ~20-min minimum-reuse guidance.
    static let tokenTTLSeconds = 50 * 60
    #endif

    public init(config: APNsConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Build the APNs `URLRequest` for a payload+token — headers, topic, push-type, priority, body.
    /// `nonisolated` + pure (touches no actor state), so a test can assert the request shape synchronously.
    /// A token that isn't URL-safe (space/newline/control char) would make `URL(string:)` return nil — we
    /// throw `.badToken` rather than force-unwrap, so a malformed token can never trap the daemon (#1).
    public nonisolated func makeRequest(payload: JSONValue, token: String) throws -> URLRequest {
        guard let url = URL(string: "https://\(config.host)/3/device/\(token)") else {
            throw PushError.badToken(token)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(config.topic, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.httpBody = try OrchestraJSON.wire.encode(payload)
        return req
    }

    public func send(payload: JSONValue, to token: String) async throws {
        #if canImport(CryptoKit)
        var req = try makeRequest(payload: payload, token: token)
        let jwt = try providerToken()
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        // The live POST to Apple's gateway. Requires a real auth key + registered token + device;
        // deferred in this environment (no APNs credentials). The path is wired and type-checked.
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw PushError.badStatus(code, String(data: data, encoding: .utf8) ?? "")
        }
        #else
        throw PushError.unsupportedPlatform
        #endif
    }

    #if canImport(CryptoKit)
    /// The provider JWT to authenticate a send: reused from the cache while it's younger than
    /// `tokenTTLSeconds`, re-signed (and re-cached) otherwise. Actor-isolated so the cache is race-free.
    /// `now` is injectable so a test can drive the TTL boundary deterministically.
    func providerToken(now: Int? = nil) throws -> String {
        let t = now ?? Int(Date().timeIntervalSince1970)
        if let c = cachedToken, t - c.mintedAt < Self.tokenTTLSeconds { return c.jwt }
        let jwt = try signedProviderToken(iat: t)
        cachedToken = (jwt, t)
        return jwt
    }

    /// Sign a fresh provider JWT with the .p8 ES256 key. `nonisolated` + pure (touches no actor state),
    /// so the key-load + signing round-trip stays synchronously testable; reuse is handled by
    /// `providerToken`.
    nonisolated func signedProviderToken(iat: Int? = nil) throws -> String {
        let unsigned = try APNsJWT.unsignedToken(keyId: config.keyId, teamId: config.teamId,
                                                 iat: iat ?? Int(Date().timeIntervalSince1970))
        let key = try Self.loadPrivateKey(path: config.keyPath)
        let sig = try key.signature(for: Data(unsigned.utf8))
        return unsigned + "." + APNsJWT.base64url(sig.rawRepresentation)
    }
    #endif
}

#if canImport(CryptoKit)
import CryptoKit

public extension APNsHTTPSender {
    /// Load a P-256 signing key from a PEM `.p8` file (the APNs auth key). Exposed for testing the
    /// key-load + ES256 signing round-trip with a generated key.
    static func loadPrivateKey(path: String) throws -> P256.Signing.PrivateKey {
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw PushError.keyUnreadable(path)
        }
        do { return try P256.Signing.PrivateKey(pemRepresentation: pem) }
        catch { throw PushError.keyUnreadable(path) }
    }
}
#endif
