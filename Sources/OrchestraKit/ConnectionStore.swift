import Foundation

/// Client-local persistence for the connection list + which one is active. Stored in UserDefaults so it
/// is per-device (choosing WHICH daemon is a client concern, never the daemon's config). The built-in
/// local connection ("this machine's daemon") is synthesized, never stored, and always first — but it
/// only exists on **macOS**. A phone has no local daemon, so on iOS the list is just the saved remotes
/// and the active/default connection resolves to a remote, never the (meaningless) local one.
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
    /// The full selectable list. macOS: built-in local first, then the persisted remotes. iOS: just the
    /// remotes — a phone has no local daemon, so a `.local` entry would be a phantom (and its transport
    /// would fall back to a nonexistent local UDS).
    public var all: [Connection] {
        #if os(macOS)
        return [.local] + remotes
        #else
        return remotes
        #endif
    }

    /// The id to fall back to when none is persisted (or the persisted/active one was just deleted).
    /// macOS: the built-in local. iOS: the first remote (there is no local daemon on a phone) — or, only
    /// when no remote is configured yet, the local id as an inert last resort (`active` still resolves it
    /// through `all`, which is empty, so nothing is offered until the user adds their Mac).
    private var defaultActiveId: UUID {
        #if os(macOS)
        return Connection.localId
        #else
        return remotes.first?.id ?? Connection.localId
        #endif
    }

    public var activeId: UUID {
        get {
            guard let s = defaults.string(forKey: activeKey), let id = UUID(uuidString: s) else { return defaultActiveId }
            return id
        }
        set { defaults.set(newValue.uuidString, forKey: activeKey) }
    }
    /// The active connection, resolving a stale/unknown id to the first available (macOS: the built-in
    /// local, which is always first; iOS: the first remote). Falls back to `.local` only when the list is
    /// empty (iOS, no remote configured) — an inert placeholder, not shown anywhere.
    public var active: Connection { all.first { $0.id == activeId } ?? all.first ?? .local }

    public func upsert(_ c: Connection) {
        guard !c.isLocal else { return }   // local is synthesized, never stored
        var list = remotes
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        persist(list)
    }

    public func delete(_ id: UUID) {
        persist(remotes.filter { $0.id != id })
        // Deleting the active one falls back to the platform default (macOS: local; iOS: another remote).
        if activeId == id { activeId = defaultActiveId }
    }

    private func persist(_ list: [Connection]) {
        if let data = try? OrchestraJSON.wire.encode(list) { defaults.set(data, forKey: key) }
    }
}
