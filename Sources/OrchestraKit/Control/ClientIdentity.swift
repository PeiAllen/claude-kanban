import Foundation

/// A stable, per-install identifier a control client stamps on every `RPCRequest` (via
/// `ControlClient.clientId`) so the daemon can attribute ownership (D4) and detect when *this* client
/// disconnects. Generated once and persisted to a file; the SAME id is reused across reconnects and
/// app relaunches. Anonymous callers (CLI, MCP) pass `nil` and never touch this — a missing clientId
/// is always tolerated.
public enum ClientIdentity {
    /// Load the id persisted at `path`, or generate + persist a fresh one and return it.
    ///
    /// Best-effort persistence: if the id can't be written (e.g. a read-only filesystem), a freshly
    /// generated id is still returned for this process — identity just won't survive a relaunch.
    public static func persistentId(at path: String) -> String {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.lowercased()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(fresh.utf8).write(to: URL(fileURLWithPath: path))
        return fresh
    }
}
