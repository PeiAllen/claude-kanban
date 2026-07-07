import Foundation

/// Client-local persistence for the connection list + which one is active. Stored in UserDefaults so it
/// is per-Mac (choosing WHICH daemon is a client concern, never the daemon's config). The built-in local
/// connection is synthesized, never stored, and always first.
public final class ConnectionStore {
    private let defaults: UserDefaults
    private let key: String
    private let activeKey: String

    public init(defaults: UserDefaults = .standard,
                key: String = "orch_connections",
                activeKey: String = "orch_active_connection") {
        self.defaults = defaults; self.key = key; self.activeKey = activeKey
    }

    /// Persisted remotes (the built-in local is never stored — `upsert` refuses it).
    public var remotes: [Connection] {
        guard let data = defaults.data(forKey: key),
              let list = try? OrchestraJSON.decoder.decode([Connection].self, from: data) else { return [] }
        return list
    }
    /// The full selectable list: built-in local first, then the persisted remotes.
    public var all: [Connection] { [.local] + remotes }

    public var activeId: UUID {
        get {
            guard let s = defaults.string(forKey: activeKey), let id = UUID(uuidString: s) else { return Connection.localId }
            return id
        }
        set { defaults.set(newValue.uuidString, forKey: activeKey) }
    }
    /// The active connection, resolving a stale/unknown id back to the built-in local.
    public var active: Connection { all.first { $0.id == activeId } ?? .local }

    public func upsert(_ c: Connection) {
        guard !c.isLocal else { return }   // local is synthesized, never stored
        var list = remotes
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        persist(list)
    }

    public func delete(_ id: UUID) {
        persist(remotes.filter { $0.id != id })
        if activeId == id { activeId = Connection.localId }
    }

    private func persist(_ list: [Connection]) {
        if let data = try? OrchestraJSON.wire.encode(list) { defaults.set(data, forKey: key) }
    }
}
