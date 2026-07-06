import Foundation
import Crypto
import Security
@preconcurrency import NIOSSH

/// Trust-on-first-use (TOFU) host-key **pinning** for the iOS SSH-PTY terminal. Closes the "accept any
/// host key" hole in `SSHPTYChannel`'s server-auth delegate: the terminal carries agent output *and*
/// your keystrokes, so an unpinned host key makes the channel MITM-able on any non-Tailscale path.
///
/// Model — mirrors `SSHKeyStore`: the pin is the **SHA-256 of the server key's canonical OpenSSH
/// representation** (`String(openSSHPublicKey:)`, a stable "algorithm-id base64" string), stored as a
/// per-host generic-password item in the Keychain with the device-only, non-syncing accessibility flag
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. First connect *pins*; every later connect
/// *compares*; a changed key is `.changed` (surfaced as a distinct "possible MITM" state, never a silent
/// accept). `reset(host:)` clears one pin so a legitimate server re-key isn't a dead end.
///
/// The persistence is behind `HostKeyPinStorage` so the TOFU logic is unit-testable without a live
/// Keychain (the test-bundle can't reach one); production uses `KeychainHostKeyPinStorage`.

/// Outcome of evaluating a presented host key against the pin record.
enum HostKeyPinResult: Equatable {
    /// No prior pin for this host — the presented key was just pinned (trust-on-first-use).
    case pinnedFirstUse
    /// The presented key matches the stored pin — safe to proceed.
    case matched
    /// The presented key DIFFERS from the pin — reject; possible man-in-the-middle.
    case changed
}

/// Thrown when a connection is refused because the host key changed. Its message is what the terminal
/// banner shows, so it names the host and points at the Settings reset for a deliberate re-key.
struct HostKeyChangedError: Error, CustomStringConvertible {
    let host: String
    var description: String {
        "host key changed for \(host) — possible MITM; connection refused "
            + "(reset the trusted key in Settings if you deliberately re-keyed this server)"
    }
}

/// Where host-key pins live. Abstracted so the TOFU logic is testable with an in-memory fake.
protocol HostKeyPinStorage: Sendable {
    func loadPin(host: String) throws -> Data?
    func savePin(_ pin: Data, host: String) throws
    func deletePin(host: String) throws
    func deleteAllPins() throws
}

/// The TOFU policy engine: fingerprint a key, then pin / match / detect-change against storage.
struct SSHHostKeyPinStore: Sendable {
    private let storage: HostKeyPinStorage

    init(storage: HostKeyPinStorage = KeychainHostKeyPinStorage()) {
        self.storage = storage
    }

    // MARK: - Fingerprinting

    /// SHA-256 of a canonical OpenSSH key string (`"ssh-ed25519 AAAA…"`). Kept string-based so it is
    /// deterministic and testable without constructing a `NIOSSHPublicKey`.
    static func fingerprint(openSSHKey: String) -> Data {
        Data(SHA256.hash(data: Data(openSSHKey.utf8)))
    }

    /// SHA-256 of the server key's canonical OpenSSH representation. `String(openSSHPublicKey:)` is a
    /// public NIOSSH API that renders the stable "algorithm-id base64" form (comment-free) — a proper
    /// per-key fingerprint, no private API needed.
    static func fingerprint(of key: NIOSSHPublicKey) -> Data {
        fingerprint(openSSHKey: String(openSSHPublicKey: key))
    }

    // MARK: - TOFU

    /// Pin on first use, else compare. Never overwrites an existing pin (a MITM must not silently
    /// re-pin itself). Throws only on a storage failure — the caller fails the connection closed.
    func evaluate(host: String, fingerprint: Data) throws -> HostKeyPinResult {
        guard let pinned = try storage.loadPin(host: host) else {
            try storage.savePin(fingerprint, host: host)
            return .pinnedFirstUse
        }
        return pinned == fingerprint ? .matched : .changed
    }

    /// Clear the pin for one host — the explicit user action that unblocks a legitimate re-key.
    func reset(host: String) throws { try storage.deletePin(host: host) }

    /// Clear every pin (a "forget all trusted host keys" affordance).
    func resetAll() throws { try storage.deleteAllPins() }

    /// Whether a pin exists for this host (drives the Settings affordance's enabled state).
    func hasPin(host: String) throws -> Bool { try storage.loadPin(host: host) != nil }
}

/// Keychain-backed pin storage — one generic-password item per host, keyed by the host string, with the
/// same device-only non-syncing accessibility (`AfterFirstUnlockThisDeviceOnly`) as `SSHKeyStore`.
struct KeychainHostKeyPinStorage: HostKeyPinStorage {
    /// Thrown when a Keychain operation fails (carries the `OSStatus` for diagnosis, like `SSHKeyStore`).
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    /// Distinct from `SSHKeyStore`'s service so pins and the device identity never collide.
    private let service = "com.orchestra.ios.ssh.hostkey"

    func loadPin(host: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
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

    func savePin(_ pin: Data, host: String) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: pin,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Overwrite the stored bytes (used only after an explicit reset — evaluate() never re-pins).
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: host,
            ]
            let update = [kSecValueData as String: pin]
            let us = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard us == errSecSuccess else { throw KeychainError(status: us) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deletePin(host: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    func deleteAllPins() throws {
        // No account → matches every pin under this service (never touches SSHKeyStore's identity item).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
