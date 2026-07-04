import Foundation
import Crypto
import Security

/// Per-device SSH identity, persisted in the iOS Keychain. The phone authenticates to the Mac with an
/// **Ed25519 public key** (phone-client 01-design: "Auth = SSH keys (per-device) as primary"), so the
/// daemon still proxies no bytes and there is no password prompt inside the app.
///
/// The private key never leaves the Keychain (generic-password item, `AfterFirstUnlockThisDeviceOnly`,
/// non-syncing). `authorizedKeyLine()` gives the one line the user adds to the Mac's
/// `~/.ssh/authorized_keys` to trust this device — that pairing is a one-time setup, documented in the
/// README.
enum SSHKeyStore {
    /// Thrown when a Keychain operation fails (with the underlying `OSStatus` for diagnosis).
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    private static let service = "com.orchestra.ios.ssh"
    private static let account = "ed25519-identity-v1"

    /// Load this device's Ed25519 private key, generating and persisting one on first use. Stable across
    /// launches, so the same public key stays trusted on the Mac.
    static func loadOrCreateIdentity() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try readKey() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        try writeKey(key.rawRepresentation)
        return key
    }

    /// The `authorized_keys` line for this device — `ssh-ed25519 <base64> <comment>`. Add it to the
    /// Mac's `~/.ssh/authorized_keys` once to trust the phone.
    static func authorizedKeyLine(comment: String = "orchestra-ios") throws -> String {
        let pub = try loadOrCreateIdentity().publicKey
        let blob = sshWireString("ssh-ed25519") + sshWireString(pub.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    // MARK: - SSH wire encoding

    /// An SSH `string`: 4-byte big-endian length prefix + the bytes (RFC 4251 §5).
    private static func sshWireString(_ s: String) -> Data { sshWireString(Data(s.utf8)) }
    private static func sshWireString(_ bytes: Data) -> Data {
        var out = Data(count: 4)
        let n = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: n) { out.replaceSubrange(0..<4, with: $0) }
        out.append(bytes)
        return out
    }

    // MARK: - Keychain

    private static func readKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    private static func writeKey(_ data: Data) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError(status: status)
        }
    }
}
