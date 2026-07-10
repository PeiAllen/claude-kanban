import Foundation
import OrchestraKit

/// Durable persistence for the F2/F3 watch registry (watcher card → the children it is watching).
/// Atomic-JSON `[String: [String]]` beside the inbox, mirroring `WorktreeRegistry`'s borrow persistence
/// (`replaceItemAt`, load-fail distinguished from absent). The in-memory `watchRegistry` on
/// `OrchestraService` is the working copy; EVERY mutation writes through `save`, and boot reloads via
/// `load` so a watcher survives a daemon restart (carry #4).
///
/// A plain `Sendable` struct (not an actor): all IO is synchronous and every call already runs on the
/// `OrchestraService` actor, so serialization comes for free from the actor mailbox — same shape as
/// `WorktreeRegistry`'s `loadBorrows`/`persistBorrows`.
public struct WatchRegistryStore: Sendable {
    private let path: String

    public init(path: String = Config.watchRegistryPath) { self.path = path }

    /// Load the persisted map. Returns `loadFailed = true` when the file EXISTS but is unreadable/corrupt
    /// (distinct from genuinely absent → empty map, which is fine) so a caller can refuse to treat an
    /// unreadable registry as "no watchers".
    public func load() -> (map: [UUID: Set<UUID>], loadFailed: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return ([:], false) }   // absent ⇒ empty, OK
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? OrchestraJSON.decoder.decode([String: [String]].self, from: data) else {
            return ([:], true)   // present but unreadable/corrupt ⇒ AMBIGUOUS
        }
        var map: [UUID: Set<UUID>] = [:]
        for (k, vs) in raw {
            guard let watcher = UUID(uuidString: k) else { continue }
            let children = Set(vs.compactMap { UUID(uuidString: $0) })
            if !children.isEmpty { map[watcher] = children }
        }
        return (map, false)
    }

    /// Atomically persist the full map (write temp + `replaceItemAt`). Best-effort — a persist hiccup
    /// leaves the prior file intact; the in-memory copy stays authoritative until the next successful save.
    @discardableResult
    public func save(_ map: [UUID: Set<UUID>]) -> Bool {
        let raw = Dictionary(uniqueKeysWithValues:
            map.map { ($0.key.uuidString, $0.value.map(\.uuidString).sorted()) })
        guard let data = try? OrchestraJSON.pretty.encode(raw) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return false }
        if FileManager.default.fileExists(atPath: path) {
            if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) == nil {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
        } else if (try? FileManager.default.moveItem(at: tmp, to: url)) == nil {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }
}
