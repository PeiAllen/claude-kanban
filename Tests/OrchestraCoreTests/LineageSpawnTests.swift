import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn churn-derivation — parentBranch re-derived from git config")
struct LineageSpawnTests {

    /// git-init a real repo under the env's reposRoot so `git config` reads succeed (StubWorktrees
    /// still cuts the fake worktree — churn derivation reads config from the repo, not the worktree).
    static func gitRepo(_ base: String, _ name: String = "app") throws -> String {
        let p = TestEnv.repo(base, name)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        return p
    }

    @Test("re-spawning onto a PRE-EXISTING branch with lineage config derives parentBranch")
    func derivesParentFromConfig() async throws {
        let env = TestEnv.make()
        let repo = try Self.gitRepo(env.base)
        // Pre-seed durable lineage for branch "child" (as if a prior card set it, then archived).
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        env.worktrees.markBranchExists("child")   // the branch survived the prior card's archival
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "child"))
        #expect(t.parentBranch == "parent")
    }

    @Test("spawning a brand-new branch leaves parentBranch nil")
    func freshBranchNoParent() async throws {
        let env = TestEnv.make()
        let repo = try Self.gitRepo(env.base)
        // Not marked existing ⇒ brand-new branch ⇒ no lineage to derive.
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
    }

    /// The gating contract: churn derivation runs ONLY for a pre-existing branch. Even if stale lineage
    /// config happens to be present, a spawn that CREATES the branch must not adopt it (and must not
    /// pay for the `git config` read on the hot path).
    @Test("a brand-new branch does not adopt stale lineage config")
    func freshBranchIgnoresStaleConfig() async throws {
        let env = TestEnv.make()
        let repo = try Self.gitRepo(env.base)
        try await BranchLineage().set(repo: repo, branch: "ghost",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        // "ghost" is NOT marked existing ⇒ ensure reports branchExisted=false ⇒ churn is skipped.
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "ghost"))
        #expect(t.parentBranch == nil)
    }
}
