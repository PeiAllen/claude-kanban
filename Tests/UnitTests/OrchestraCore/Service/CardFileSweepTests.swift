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
