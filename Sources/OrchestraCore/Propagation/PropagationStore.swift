import Foundation
import OrchestraKit

/// One repo's propagation policy: named overrides beating the global default, and any items a user
/// declared that aren't in an adapter's own list. Both maps are keyed by item name — the SAME key an
/// adapter's `PropagationItem.name` carries — so a lookup never has to trust an embedded `name` that
/// could disagree with the map's own key.
public struct PropagationRepoPolicy: Codable, Sendable, Equatable {
    public var overrides: [String: PropagationPolicy]
    public var userItems: [String: PropagationItem]

    public init(overrides: [String: PropagationPolicy] = [:], userItems: [String: PropagationItem] = [:]) {
        self.overrides = overrides
        self.userItems = userItems
    }

    /// The single default every item falls back to absent an override — not an adapter-specific one.
    /// `PropagationItem` carries no policy field of its own, so one constant is the only shape PR1's
    /// types allow; `shared` matches today's Claude and Codex declarations. A future per-adapter
    /// default is a Kit type change, not a silent addition here.
    public static let defaultPolicy: PropagationPolicy = .shared

    /// An override beats the default.
    public func policy(for itemName: String) -> PropagationPolicy {
        overrides[itemName] ?? Self.defaultPolicy
    }

    /// A user item beats an adapter item of the same name. The result is sorted by name: Swift's
    /// dictionary/set iteration order is randomized per process, and a caller (PR2's `DeclaredSet`)
    /// turns this list directly into git argv — an unstable order would make two syncs of the same
    /// input emit different commands.
    public func mergedItems(withAdapterItems adapterItems: [PropagationItem]) -> [PropagationItem] {
        var byName = Dictionary(adapterItems.map { ($0.name, $0) }, uniquingKeysWith: { _, later in later })
        for (key, item) in userItems { byName[key] = item }
        return byName.values.sorted { $0.name < $1.name }
    }
}

/// The result of loading the propagation policy table: absent (empty, fine) is distinguished from
/// present-but-corrupt (empty, `loadFailed`) so a caller can stand every item down rather than treat
/// corruption as "nobody configured anything".
public struct PropagationLoadResult: Sendable {
    public let table: [String: PropagationRepoPolicy]
    public let loadFailed: Bool

    public init(table: [String: PropagationRepoPolicy], loadFailed: Bool) {
        self.table = table
        self.loadFailed = loadFailed
    }

    /// Looks up a repo's policy by canonical path, so `/tmp/x` and `/private/tmp/x` (or any other
    /// alias) resolve to the same row regardless of how the caller spelled it. A repo with no row gets
    /// an empty policy — every item falls back to `PropagationRepoPolicy.defaultPolicy`.
    ///
    /// Returns `nil` when the whole load failed, distinct from a healthy empty policy for an
    /// unconfigured repo: a caller that forgets to branch on `loadFailed` before calling this would
    /// otherwise get `PropagationRepoPolicy()` either way, silently treating corruption as "nobody
    /// configured anything" and resuming the permissive `.shared` default.
    public func repoPolicy(for repoPath: String) -> PropagationRepoPolicy? {
        guard !loadFailed else { return nil }
        return table[PathResolver.canonical(repoPath)] ?? PropagationRepoPolicy()
    }
}

/// The propagation policy table: a sidecar JSON file at `Config.defaultPropagationPath`, keyed by
/// canonical repo path. A `Config` field would be wiped by `ControlServer.setConfig`'s wholesale
/// replace (`ControlServer.swift:129`); a standalone file is untouched by it.
///
/// `load` never mutates the file. A corrupt file is reported via `loadFailed` and left exactly where
/// it is, so every later `load` — including one on a fresh sync, or after a daemon restart — keeps
/// reporting `loadFailed` until a human or a legitimate `save` repairs it. Moving the corrupt file
/// aside on `load` (matching `TrustLedger`'s idiom literally) was tried and rejected: `TrustLedger`'s
/// empty-on-corrupt is fail-safe (nothing trusted), but this table's empty-on-corrupt is fail-OPEN
/// (`PropagationRepoPolicy.defaultPolicy == .shared`), so moving the file away made the SECOND `load`
/// silently report a healthy empty table and resume propagating everything one call after the
/// corruption was detected.
///
/// `save` is the one place content can be lost, so it is the one place that protects against it: if
/// the file on disk currently holds bytes that fail to decode, `save` preserves them as `.bak` before
/// writing its own table over them.
public enum PropagationStore {
    public static func load(path: String = Config.defaultPropagationPath) -> PropagationLoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return PropagationLoadResult(table: [:], loadFailed: false)
        }
        guard let table = decodedTable(atPath: path) else {
            return PropagationLoadResult(table: [:], loadFailed: true)
        }
        return PropagationLoadResult(table: table, loadFailed: false)
    }

    @discardableResult
    public static func save(_ table: [String: PropagationRepoPolicy], path: String = Config.defaultPropagationPath) -> Bool {
        // Every key is canonicalized here — the one place a table is written — so `repoPolicy(for:)`'s
        // canonical lookup can never miss a row a writer stored under a non-canonical alias (e.g.
        // `/tmp/x` vs. `/private/tmp/x`).
        let canonicalTable = Dictionary(
            table.map { (PathResolver.canonical($0.key), $0.value) }, uniquingKeysWith: { _, later in later })
        guard let data = try? OrchestraJSON.pretty.encode(canonicalTable) else { return false }

        if FileManager.default.fileExists(atPath: path), decodedTable(atPath: path) == nil {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
        }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return false }
        if FileManager.default.fileExists(atPath: path) {
            guard (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
        } else {
            guard (try? FileManager.default.moveItem(at: tmp, to: url)) != nil else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
        }
        return true
    }

    private static func decodedTable(atPath path: String) -> [String: PropagationRepoPolicy]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? OrchestraJSON.decoder.decode([String: PropagationRepoPolicy].self, from: data)
    }
}
