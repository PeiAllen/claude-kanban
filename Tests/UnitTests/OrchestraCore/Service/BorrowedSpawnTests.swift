import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn — borrowed cards")
struct BorrowedSpawnTests {
    @Test("borrowed spawn skips the worktree and archive never removes the dir")
    func borrowedSpawnSkipsWorktreeAndNeverRemovesOnArchive() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/data"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "process", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(t.cwd == dir)
        #expect(env.worktrees.ensured.isEmpty)        // never cut a worktree

        try await env.svc.archive(t.id, source: .app)
        #expect(env.worktrees.removed.isEmpty)        // borrowed dir untouched
    }
}
