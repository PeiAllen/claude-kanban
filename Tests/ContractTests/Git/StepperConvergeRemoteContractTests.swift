import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// Contract movers (extracted from the unit StepperConvergeTests at the Task-9/11 flip, card-lifecycle):
// the two `materializeRemote*` cases assert a REAL worktree HEAD == the fetched PR tip and a REAL
// fetch-failure leaving no worktree dir — real-fetch + real-worktree effects a FakeProc cannot carry.
// They run real git (makeReal + RemoteParentTests.makeOriginWithPR + real `rev-parse HEAD`); their
// worktree-add / remote-fetch essence is also pinned by WorktreeAddContractTests + RemoteFetchContractTests.
@Suite("Contract: MaterializeStepper over a real remote (fetched-tip checkout + fetch-failure)")
struct StepperConvergeRemoteContractTests {

    /// Create a `.creatingWorktree` worktree card directly in a real-git service's store (no spawn), so
    /// `materialize` re-derives everything from the persisted card — mirroring a reconciler-driven walk.
    private func seedRealCreating(_ svc: OrchestraService, base: String, branch: String, spawnBase: String?) async throws -> Task {
        let repo = base + "/repos/app"
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let cwd = WorktreeRegistry(config: config, borrowsPath: base + "/b.json", markersDir: base + "/m")
            .path(repo: repo, branch: branch)
        let t = Task(title: branch, titleProvisional: true, repo: repo, branch: branch, cwd: cwd,
                     origin: .worktree, agentId: "claude-code", model: AgentModel(id: "m1"), startIn: .impl,
                     column: .impl, order: 0, phase: .creatingWorktree, sessionEpoch: 1,
                     spawnBase: spawnBase, agentSessionId: nil, initialPrompt: branch)
        let (created, _) = try await svc.store.create(t)
        return created
    }

    @Test("test_materializeRemoteBaseFromCarrier")   // a persisted remote spawnBase re-fetches + checks out
    func test_materializeRemoteBaseFromCarrier() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let prTip = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))   // expected tip
        let card = try await seedRealCreating(svc, base: base, branch: "childP", spawnBase: "pr#7")
        try await MaterializeStepper().step(card, await svc.convergeContext())

        let after = try #require(await svc.store.get(card.id))
        #expect(after.phase.kind == .launching)
        #expect(after.parentBranch == "pr#7")          // canonical remote form recorded from the carrier
        #expect(after.spawnBase == nil)                // carrier consumed
        let head = try Proc.run(["git", "-C", after.cwd, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == prTip)                         // the child worktree starts at the fetched PR tip
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.prNumber == 7)
    }

    @Test("test_materializeRemoteFetchFailureClassified")   // a bad remote base → dead, no worktree cut
    func test_materializeRemoteFetchFailureClassified() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await seedRealCreating(svc, base: base, branch: "childX", spawnBase: "pr#999")
        try await MaterializeStepper().step(card, await svc.convergeContext())

        let after = try #require(await svc.store.get(card.id))
        #expect(after.phase == .dead(.spawnFailed))
        #expect(!FileManager.default.fileExists(atPath: card.cwd))   // no worktree cut on a fetch failure
    }
}
