import Foundation
import OrchestraKit

/// Serializes reads/writes of `device-tokens.json` — the APNs device registrations (N1). Mirrors the
/// `TaskStore` idiom: Codable, atomic save, malformed file → `.bak` + start empty. Keyed by `clientId`
/// so a re-register (new token or changed prefs) REPLACES the prior entry for that install rather than
/// accumulating stale tokens. Client-local, daemon-owned; the phone hands its token over the
/// `registerDevice` RPC.
public actor DeviceTokenStore {
    private let path: String
    private var devices: [DeviceRegistration] = []
    private var loaded = false

    public init(path: String = Config.deviceTokensPath) {
        self.path = path
    }

    @discardableResult
    public func load() -> [DeviceRegistration] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            devices = []; loaded = true; return devices
        }
        do {
            let data = try Data(contentsOf: url)
            devices = try OrchestraJSON.decoder.decode([DeviceRegistration].self, from: data)
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            devices = []
        }
        loaded = true
        return devices
    }

    private func ensureLoaded() { if !loaded { _ = load() } }

    /// All registered devices.
    public func all() -> [DeviceRegistration] {
        ensureLoaded()
        return devices
    }

    /// Register (or update) a device. Replaces any prior entry with the same `clientId`.
    @discardableResult
    public func register(_ reg: DeviceRegistration) throws -> DeviceRegistration {
        ensureLoaded()
        devices.removeAll { $0.clientId == reg.clientId }
        devices.append(reg)
        try persist()
        return reg
    }

    /// Drop the registration for a client (e.g. the phone revoked notifications). Idempotent.
    public func unregister(clientId: String) throws {
        ensureLoaded()
        let before = devices.count
        devices.removeAll { $0.clientId == clientId }
        if devices.count != before { try persist() }
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(devices)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // Device tokens are a push-delivery capability — keep the file owner-only (0600). Set it on the
        // temp file first (closes the umask window before the rename) and again on the final path, since
        // `replaceItemAt` can carry over the destination inode's permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
