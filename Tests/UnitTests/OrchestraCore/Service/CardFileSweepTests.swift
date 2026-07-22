import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

/// Coverage for `sweepCardFiles` liveness + fail-safe gates. All tests inject specs pointed at an
/// ISOLATED temp dir (`env.base`), never the real `~/Library/Application Support/Orchestra` or `~/.codex`
/// — a stub harness has no view of the real daemon's live cards, so a sweep pointed at the real dirs
/// would delete the user's live launch configs (the ScratchSweepTests landmine, same class here).
@Suite("Sweep — orphan card-files: liveness + fail-safe")
struct CardFileSweepTests {
    private let fm = FileManager.default

    @discardableResult
    private func seedCard(_ store: TaskStore, id: UUID = UUID(), cwd: String, archived: Bool = false) async throws -> Task {
        var t = Task(id: id, title: "t", repo: "", branch: "b", cwd: cwd, origin: .worktree,
                     model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0, initialPrompt: "")
        t.archived = archived
        try await store.create(t)
        return t
    }

    /// Write a file for `spec` at `token`, back-dated well past any grace window so it is a sweep candidate.
    @discardableResult
    private func writeFile(_ spec: CardFileSpec, token: String, dir: String) throws -> String {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = spec.path(token: token)
        try "x".write(toFile: p, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10_000)], ofItemAtPath: p)
        return p
    }

    @Test("a live card's file is kept; an archived card's file is swept")
    func livenessGates() async throws {
        let env = TestEnv.make()
        let dir = "\(env.base)/cardfiles"
        let spec = CardFileSpec(directory: dir, prefix: "card-settings-", suffix: ".json", key: .cwdHash)
        let live = try await seedCard(env.svc.store, cwd: "/wt/live")
        let dead = try await seedCard(env.svc.store, cwd: "/wt/dead", archived: true)
        let liveFile = try writeFile(spec, token: spec.token(for: live), dir: dir)
        let deadFile = try writeFile(spec, token: spec.token(for: dead), dir: dir)

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(fm.fileExists(atPath: liveFile))   // in store, not archived → kept
        #expect(!fm.fileExists(atPath: deadFile))  // archived → swept
    }

    @Test("two live cards sharing a cwd keep their shared file even when one is archived")
    func sharedCwdKept() async throws {
        let env = TestEnv.make()
        let dir = "\(env.base)/cardfiles"
        let spec = CardFileSpec(directory: dir, prefix: "card-settings-", suffix: ".json", key: .cwdHash)
        let a = try await seedCard(env.svc.store, cwd: "/wt/shared")
        _ = try await seedCard(env.svc.store, cwd: "/wt/shared", archived: true)   // B archived, same cwd
        let shared = try writeFile(spec, token: spec.token(for: a), dir: dir)

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(fm.fileExists(atPath: shared))   // A still live → shared file kept despite B archived
    }

    @Test("unrecognized sibling files and subdirectories are never touched")
    func siblingsUntouched() async throws {
        let env = TestEnv.make()
        let dir = "\(env.base)/cardfiles"
        let spec = CardFileSpec(directory: dir, prefix: "card-settings-", suffix: ".json", key: .cwdHash)
        _ = try await seedCard(env.svc.store, cwd: "/wt/live")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stranger = "\(dir)/borrows.json"
        try "keep me".write(toFile: stranger, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10_000)], ofItemAtPath: stranger)
        try fm.createDirectory(atPath: "\(dir)/media", withIntermediateDirectories: true)  // subdir neighbor

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(fm.fileExists(atPath: stranger))            // wrong name → never a candidate
        #expect(fm.fileExists(atPath: "\(dir)/media"))      // subdir → non-recursive, untouched
    }

    @Test("a user-authored file sharing prefix/suffix but not the token shape is never swept")
    func userAuthoredFileKept() async throws {
        let env = TestEnv.make()
        let dir = "\(env.base)/codexhome"
        let spec = CardFileSpec(directory: dir, prefix: "orch-", suffix: ".config.toml", key: .cwdHash)
        _ = try await seedCard(env.svc.store, cwd: "/wt/live")   // store non-empty (past the evidence gate)
        // A profile the USER hand-wrote for `codex -p orch-research` — shares the prefix/suffix, but its
        // token "research" is not a generated hash, so it must never become a sweep candidate.
        let userFile = try writeFile(spec, token: "research", dir: dir)

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(fm.fileExists(atPath: userFile))
    }

    @Test("with an ownership marker set, only files that CARRY it are swept (a user's hash-named file is safe)")
    func ownershipMarkerRequired() async throws {
        let env = TestEnv.make()
        let dir = "\(env.base)/codexhome"
        let marker = "# orchestra-managed"
        let spec = CardFileSpec(directory: dir, prefix: "orch-", suffix: ".config.toml",
                                key: .cwdHash, ownershipMarker: marker)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try await seedCard(env.svc.store, cwd: "/wt/live")   // store non-empty (past the evidence gate)

        // (a) An ARCHIVED card's profile that ORCHESTRA wrote — carries the marker → reaped.
        let dead = try await seedCard(env.svc.store, cwd: "/wt/dead", archived: true)
        let ours = spec.path(token: spec.token(for: dead))
        try "\(marker)\ntrust_level = \"trusted\"\n".write(toFile: ours, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10_000)], ofItemAtPath: ours)

        // (b) A USER's own profile with a valid-hash-shaped name but NO marker → never reaped.
        let userFile = spec.path(token: CardFileSpec.cwdHash("/some/user/cwd"))   // passes the shape check
        try "trust_level = \"trusted\"\n".write(toFile: userFile, atomically: true, encoding: .utf8)  // no marker
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10_000)], ofItemAtPath: userFile)

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(!fm.fileExists(atPath: ours))       // marked + archived → swept
        #expect(fm.fileExists(atPath: userFile))    // hash-shaped but unmarked → kept (the user's own file)
    }

    // NOTE: the partial-load fail-safe (a non-empty but incomplete store ⇒ prune nothing) is covered by
    // its two halves — `TaskStoreTests.partialLoadFlagged` pins `loadWasComplete() == false` on an
    // element-wise drop, and `OrphanSweepTests.incompleteEvidenceKeepsAll` pins `evidenceIsComplete:false`
    // ⇒ []. `sweepCardFiles` composes them as `!cards.isEmpty && loadWasComplete()`.

    @Test("empty store ⇒ sweep nothing (a failed/empty load is not 'all orphaned')")
    func emptyStoreSweepsNothing() async throws {
        let env = TestEnv.make()   // no cards seeded
        let dir = "\(env.base)/cardfiles"
        let spec = CardFileSpec(directory: dir, prefix: "card-settings-", suffix: ".json", key: .cwdHash)
        let orphan = try writeFile(spec, token: CardFileSpec.cwdHash("/wt/whatever"), dir: dir)

        await env.svc.sweepCardFiles(specs: [spec], grace: 0)

        #expect(fm.fileExists(atPath: orphan))   // empty store → evidence incomplete → keep
    }

    @Test("CardFileSpec.all collects one spec per adapter-with-cardFile plus the readonly spec")
    func allCollectsSpecs() {
        let specs = CardFileSpec.all(adapters: [ClaudeCodeAdapter(), CodexAdapter()],
                                     runtimeStateDir: "/rt")
        #expect(specs.contains { $0.prefix == "card-settings-" })
        #expect(specs.contains { $0.prefix == "orch-" })
        #expect(specs.contains { $0.prefix == "readonly-" && $0.directory == "/rt" })
    }
}
