import Foundation

/// The core's trust decision for a launch. `needsGrant` means an untrusted, un-ledgered cwd that a
/// human must approve (the grant surfaces land in T2); until then it resolves to `trustCwd = false`.
public enum TrustDecision: Sendable, Equatable { case trusted, needsGrant }

/// Who put an entry in the ledger. `orchestra` = auto-trust of a dir Orchestra made empty (scratch);
/// `repoRegistration` = a worktree's source repo (registering a repo to run agents is the trust act);
/// `human` = an explicit human grant (T2 surfaces).
public enum TrustGrantor: String, Codable, Sendable { case human, orchestra, repoRegistration }

/// Orchestra-owned, provider-agnostic trust source of truth (repo/cwd → trusted). Actor-over-JSON,
/// sibling to `TaskStore`: atomic save (temp + replaceItem), malformed file → `.bak` + empty. This is
/// what makes a repo trusted once carry across agents (Claude, later Codex) — each adapter *mirrors*
/// it into its native flag. Only the CORE reads it (in `resolveTrust`); adapters never do.
public actor TrustLedger {
    struct Entry: Codable, Sendable { var grantedBy: TrustGrantor; var grantedAt: Date }

    private let path: String
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(path: String = Config.trustLedgerPath) { self.path = path }

    /// Read + decode. `[:]` if absent; malformed → `.bak` + `[:]`. Returns the entry count.
    @discardableResult
    public func load() -> Int {
        loaded = true
        guard FileManager.default.fileExists(atPath: path) else { entries = [:]; return 0 }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            entries = try OrchestraJSON.decoder.decode([String: Entry].self, from: data)
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            entries = [:]
        }
        return entries.count
    }

    private func ensureLoaded() { if !loaded { _ = load() } }

    /// True iff `path` (canonicalized) has an entry.
    public func isTrusted(_ path: String) -> Bool {
        ensureLoaded()
        return entries[PathResolver.canonical(path)] != nil
    }

    /// Record `path` (canonicalized) as trusted. No-op (returns false) if already present. Persists.
    @discardableResult
    public func record(_ path: String, grantedBy: TrustGrantor) throws -> Bool {
        ensureLoaded()
        let key = PathResolver.canonical(path)
        if entries[key] != nil { return false }
        entries[key] = Entry(grantedBy: grantedBy, grantedAt: Date())
        try persist()
        return true
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(entries)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
