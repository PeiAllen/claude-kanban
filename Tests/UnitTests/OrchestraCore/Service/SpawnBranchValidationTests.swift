import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// A worktree spawn is `repo` + `branch` (the catalog says to omit BOTH for a freeform `cwd` card).
/// `branch` decodes to `""` when a caller omits it, and `Config.worktreePath` is a plain join — so a
/// repo-without-branch spawn silently addressed `<worktreesRoot>/<repoName>/`, the SHARED container
/// holding every live worktree of that repo, and reported it as a stale checkout to delete. Reject the
/// half-specified spawn at the boundary, before any card exists.
@Suite("Spawn — a worktree card requires a branch")
struct SpawnBranchValidationTests {

    @Test("repo + base with no branch is rejected, and creates no card")
    func rejectsWorktreeSpawnWithoutBranch() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let id = UUID()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.spawn(SpawnInput(id: id, prompt: "review it", repo: repo,
                                                   access: .readOnly, base: "some-branch"))
        }
        #expect(await env.svc.list().isEmpty)   // fail-fast: nothing was created to go dead later
    }

    @Test("a whitespace-only branch is rejected too")
    func rejectsBlankBranch() async throws {
        let env = TestEnv.make()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "p",
                                                   repo: TestEnv.repo(env.base), branch: "   "))
        }
        #expect(await env.svc.list().isEmpty)
    }

    @Test("a freeform cwd card still spawns with no repo or branch")
    func freeformSpawnUnaffected() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/freeform"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "look around", cwd: dir, access: .readOnly))
        #expect(t.origin == .borrowed)
        #expect(t.cwd == dir)
    }
}
