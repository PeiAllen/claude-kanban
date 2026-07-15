import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

/// Regression coverage for `sweepOrphanScratch` deleting LIVE cards' scratch dirs.
///
/// All tests run against an ISOLATED temp root (`root:` injection), never the real
/// `~/.orchestra/scratch` — a stub-sessions harness has no view of the real daemon's live tmux
/// sessions, so a sweep pointed at the real root would happily `rm -rf` the user's live cards. The
/// old test pointed the sweep at `Config.scratchRoot`; that was the landmine this bug is about.
@Suite("Sweep — orphan scratch dirs: liveness + fail-safe")
struct ScratchSweepTests {
    private let fm = FileManager.default

    /// Seed a minimal non-archived `.scratch` card so the store is non-empty (past the empty-store
    /// guard) and its `cwd` is a real reference the sweep can match on.
    private func seedScratchCard(_ store: TaskStore, id: UUID = UUID(), cwd: String) async throws {
        try await store.create(Task(
            id: id, title: "t", repo: "", branch: "", cwd: cwd, origin: .scratch,
            model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0, initialPrompt: ""))
    }

    private func mkdir(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @Test("removes a store/session-orphaned dir but keeps the store-matched live card")
    func removesOrphanKeepsStoreMatched() async throws {
        let env = TestEnv.make()
        let root = env.base + "/scratch"
        let liveId = UUID()
        let liveDir = "\(root)/\(liveId.uuidString.lowercased())"
        let orphanDir = "\(root)/\(UUID().uuidString.lowercased())"
        try mkdir(liveDir); try mkdir(orphanDir)
        try await seedScratchCard(env.svc.store, id: liveId, cwd: liveDir)   // cwd match keeps it

        await env.svc.sweepOrphanScratch(root: root, graceInterval: 0)

        #expect(fm.fileExists(atPath: liveDir))     // in the store → kept
        #expect(!fm.fileExists(atPath: orphanDir))  // no card, no session → swept
    }

    @Test("never deletes a dir whose tmux session is live, even when absent from the store snapshot")
    func keepsDirWithLiveSessionMissingFromStore() async throws {
        let env = TestEnv.make()
        let root = env.base + "/scratch"
        // Store is non-empty (so the empty-store guard doesn't trivially save everything) but does NOT
        // contain this card — the split-brain / lagging-tasks.json case.
        try await seedScratchCard(env.svc.store, cwd: "\(root)/\(UUID().uuidString.lowercased())")

        let liveId = UUID()
        let liveDir = "\(root)/\(liveId.uuidString.lowercased())"
        let orphanDir = "\(root)/\(UUID().uuidString.lowercased())"
        try mkdir(liveDir); try mkdir(orphanDir)
        env.sessions.setAlive(liveId, true)   // tmux session live, but no store entry

        await env.svc.sweepOrphanScratch(root: root, graceInterval: 0)

        #expect(fm.fileExists(atPath: liveDir))     // live session → kept despite store miss
        #expect(!fm.fileExists(atPath: orphanDir))  // proves the sweep actually ran
    }

    @Test("no-ops entirely on an empty store (a failed/empty load must not read as 'all orphaned')")
    func noOpsOnEmptyStore() async throws {
        let env = TestEnv.make()   // fresh: store is empty
        let root = env.base + "/scratch"
        let orphanA = "\(root)/\(UUID().uuidString.lowercased())"
        let orphanB = "\(root)/\(UUID().uuidString.lowercased())"
        try mkdir(orphanA); try mkdir(orphanB)

        await env.svc.sweepOrphanScratch(root: root, graceInterval: 0)

        #expect(fm.fileExists(atPath: orphanA))   // empty store → nothing deleted
        #expect(fm.fileExists(atPath: orphanB))
    }
}
