import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, branch-tree). Churn derivation reads the parent link from `git config`
/// (the service's proc seam) — modelled here by GitConfigEmulator over FakeProc; StubWorktrees reports
/// branch pre-existence via `markBranchExists`. No real git.
@Suite("Spawn churn-derivation — parentBranch re-derived from git config")
struct LineageSpawnTests {

    /// A FakeProc-backed env with the config emulator; `repo` is a bare dir under reposRoot.
    static func setup() -> (env: TreeStatTests.Env, fake: FakeProc, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let env = TestEnv.make(proc: fake)
        return (env, fake, TestEnv.repo(env.base))
    }

    @Test("re-spawning onto a PRE-EXISTING branch with lineage config derives parentBranch")
    func derivesParentFromConfig() async throws {
        let (env, fake, repo) = Self.setup()
        // Pre-seed durable lineage for branch "child" (as if a prior card set it, then archived).
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        env.worktrees.markBranchExists("child")   // the branch survived the prior card's archival
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        #expect(t.parentBranch == "parent")
    }

    @Test("spawning a brand-new branch leaves parentBranch nil")
    func freshBranchNoParent() async throws {
        let (env, _, repo) = Self.setup()
        // Not marked existing ⇒ brand-new branch ⇒ no lineage to derive.
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
    }

    /// The gating contract: churn derivation runs ONLY for a pre-existing branch. Even if stale lineage
    /// config happens to be present, a spawn that CREATES the branch must not adopt it (and must not
    /// pay for the `git config` read on the hot path).
    @Test("a brand-new branch does not adopt stale lineage config")
    func freshBranchIgnoresStaleConfig() async throws {
        let (env, fake, repo) = Self.setup()
        try await BranchLineage(proc: fake).set(repo: repo, branch: "ghost",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        // "ghost" is NOT marked existing ⇒ ensure reports branchExisted=false ⇒ churn is skipped.
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "ghost"))
        #expect(t.parentBranch == nil)
    }
}
