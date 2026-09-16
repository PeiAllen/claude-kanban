import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

@Suite("PropagationStore — sidecar policy table")
struct PropagationStoreTests {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "propagation-\(UUID().uuidString)/propagation.json"
    }

    @Test("absent file -> empty table, not loadFailed")
    func absentFile() {
        let result = PropagationStore.load(path: tmpPath())
        #expect(result.table.isEmpty)
        #expect(result.loadFailed == false)
    }

    @Test("corrupt file -> loadFailed, left in place")
    func corruptFile() throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)

        let result = PropagationStore.load(path: path)
        #expect(result.table.isEmpty)
        #expect(result.loadFailed == true)
        // `load` never mutates the file — no .bak yet, and the corrupt bytes are still there.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test("corrupt file keeps reporting loadFailed on every later load, not just the first")
    func repeatedLoadKeepsReportingFailure() throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(PropagationStore.load(path: path).loadFailed == true)
        // A second load — e.g. a later sync, or after a daemon restart — must not see a healthy empty
        // table just because the first load already reported the corruption once.
        #expect(PropagationStore.load(path: path).loadFailed == true)
    }

    @Test("save then load round-trips")
    func saveLoadRoundTrip() {
        let path = tmpPath()
        let table: [String: PropagationRepoPolicy] = [
            "/repo/one": PropagationRepoPolicy(
                overrides: ["claude": .tracked],
                userItems: ["notes": PropagationItem(name: "notes", paths: ["notes.md"], exclusions: [])]
            ),
        ]
        #expect(PropagationStore.save(table, path: path) == true)

        let result = PropagationStore.load(path: path)
        #expect(result.loadFailed == false)
        #expect(result.table == table)
    }

    @Test("save creates a not-yet-existing parent directory")
    func saveCreatesParentDirectory() {
        let path = NSTemporaryDirectory() + "propagation-\(UUID().uuidString)/nested/dir/propagation.json"
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
        #expect(PropagationStore.save([:], path: path) == true)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("save returns false for an unwritable path")
    func saveUnwritablePath() throws {
        let blocker = NSTemporaryDirectory() + "propagation-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: blocker))
        let path = blocker + "/propagation.json"
        #expect(PropagationStore.save([:], path: path) == false)
    }

    @Test("save over a corrupt file preserves it as .bak instead of erasing it")
    func saveOverCorruptFilePreservesBak() throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(PropagationStore.load(path: path).loadFailed == true)

        let table: [String: PropagationRepoPolicy] = ["/repo": PropagationRepoPolicy(overrides: ["claude": .ephemeral])]
        #expect(PropagationStore.save(table, path: path) == true)

        #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8) == "not json")
        let reloaded = PropagationStore.load(path: path)
        #expect(reloaded.loadFailed == false)
        #expect(reloaded.table == table)
    }

    @Test("an override beats the default")
    func overrideBeatsDefault() {
        let withOverride = PropagationRepoPolicy(overrides: ["claude": .tracked])
        #expect(withOverride.policy(for: "claude") == .tracked)
        #expect(withOverride.policy(for: "codex") == .shared)

        let empty = PropagationRepoPolicy()
        #expect(empty.policy(for: "claude") == .shared)
    }

    @Test("a user item beats an adapter item of the same name")
    func userItemBeatsAdapterItem() {
        let adapterItems = [PropagationItem(name: "claude", paths: ["CLAUDE.md"], exclusions: [])]
        let userOverride = PropagationItem(name: "claude", paths: ["CUSTOM.md"], exclusions: [])
        let repoPolicy = PropagationRepoPolicy(userItems: ["claude": userOverride])

        let merged = repoPolicy.mergedItems(withAdapterItems: adapterItems)
        #expect(merged == [userOverride])
    }

    @Test("mergedItems keys by the map key, not the item's own embedded name")
    func mergedItemsTrustsMapKey() {
        // A disagreeing embedded name must not create a second row or hide the intended override —
        // the dictionary key is the one source of truth a `shared-policy` lookup by key can rely on.
        let mismatched = PropagationItem(name: "wrong-name", paths: ["X.md"], exclusions: [])
        let repoPolicy = PropagationRepoPolicy(userItems: ["claude": mismatched])
        let adapterItems = [PropagationItem(name: "claude", paths: ["CLAUDE.md"], exclusions: [])]

        let merged = repoPolicy.mergedItems(withAdapterItems: adapterItems)
        #expect(merged == [mismatched])
    }

    @Test("mergedItems tolerates a duplicate adapter item name without trapping")
    func mergedItemsDeduplicatesAdapterItems() {
        let dupA = PropagationItem(name: "claude", paths: ["A.md"], exclusions: [])
        let dupB = PropagationItem(name: "claude", paths: ["B.md"], exclusions: [])
        let repoPolicy = PropagationRepoPolicy()

        let merged = repoPolicy.mergedItems(withAdapterItems: [dupA, dupB])
        #expect(merged.count == 1)
    }

    @Test("mergedItems returns a stable, name-sorted order")
    func mergedItemsSortedOrder() {
        let items = [
            PropagationItem(name: "zeta", paths: [], exclusions: []),
            PropagationItem(name: "alpha", paths: [], exclusions: []),
            PropagationItem(name: "mid", paths: [], exclusions: []),
        ]
        let repoPolicy = PropagationRepoPolicy()
        let merged = repoPolicy.mergedItems(withAdapterItems: items)
        #expect(merged.map(\.name) == ["alpha", "mid", "zeta"])
    }

    @Test("repoPolicy(for:) canonicalizes the lookup path (/tmp == /private/tmp on macOS)")
    func canonicalRepoLookup() throws {
        let raw = "/tmp/propagation-canon-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let canonical = PathResolver.canonical(raw)
        // Guards the test itself: if this ever equals `raw` (e.g. a platform where /tmp isn't a
        // symlink), the assertion below would pass without exercising canonicalization at all.
        #expect(canonical != raw)

        let result = PropagationLoadResult(
            table: [canonical: PropagationRepoPolicy(overrides: ["claude": .tracked])],
            loadFailed: false
        )
        let policy = try #require(result.repoPolicy(for: raw))
        #expect(policy.policy(for: "claude") == .tracked)
    }

    @Test("repoPolicy(for:) defaults to an empty policy for an unknown repo")
    func unknownRepoDefaultsEmpty() throws {
        let result = PropagationLoadResult(table: [:], loadFailed: false)
        #expect(try #require(result.repoPolicy(for: "/nowhere")) == PropagationRepoPolicy())
    }

    @Test("repoPolicy(for:) returns nil when the load itself failed, never a silent healthy default")
    func repoPolicyNilWhenLoadFailed() {
        let result = PropagationLoadResult(table: [:], loadFailed: true)
        #expect(result.repoPolicy(for: "/anything") == nil)
    }

    @Test("save canonicalizes a non-canonical repo key so repoPolicy(for:) can find it")
    func saveCanonicalizesKeys() throws {
        let raw = "/tmp/propagation-canon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        #expect(PathResolver.canonical(raw) != raw)

        let path = tmpPath()
        let table: [String: PropagationRepoPolicy] = [raw: PropagationRepoPolicy(overrides: ["claude": .tracked])]
        #expect(PropagationStore.save(table, path: path) == true)

        let result = PropagationStore.load(path: path)
        let policy = try #require(result.repoPolicy(for: raw))
        #expect(policy.policy(for: "claude") == .tracked)
    }
}
