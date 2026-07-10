import Foundation
import Testing
@testable import OrchestraCore

@Suite("Archive — switch on Task.origin")
struct ArchiveOriginTests {
    // The `.worktree` arm of the origin switch: co-located `.worktree` cards share one tree, and the
    // sibling refcount (keyed on `cwd`) keeps it until the last card leaves.
    @Test("archiving one of two co-located .worktree cards keeps the tree; last one out removes it")
    func refcountKeyedOnCwdAmongWorktreeCards() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Two cards on the SAME branch resolve to the SAME worktree (ensure is idempotent on the path).
        let a = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "a", repo: repo, branch: "feat"))
        let b = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "b", repo: repo, branch: "feat"))
        #expect(a.cwd == b.cwd)              // idempotent ensure → shared tree
        #expect(a.origin == .worktree)       // spawn only ever produces .worktree in this PR
        #expect(b.origin == .worktree)

        // Archiving the first must NOT remove the tree — b still lives there. (Intent-only archive +
        // reconciler-driven TeardownStepper — PR4b Task 4.)
        try await TestEnv.archiveAndTeardown(env.svc, a.id, source: .app)
        #expect(!env.worktrees.removed.contains(a.cwd))

        // Archiving the last card on the tree removes it.
        try await TestEnv.archiveAndTeardown(env.svc, b.id, source: .app)
        #expect(env.worktrees.removed.contains(b.cwd))
    }
}
