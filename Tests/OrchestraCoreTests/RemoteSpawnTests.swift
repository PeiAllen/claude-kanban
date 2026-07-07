import Foundation
import Testing
@testable import OrchestraCore

@Suite("Remote spawn — ensure(base:) with a fetched private ref + lineage")
struct RemoteSpawnTests {

    @Test("ensure starts a new branch at a fetched refs/orch/parents ref")
    func ensureFromPrivateRef() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        _ = svc
        let repo = base + "/repos/app"
        let (_, _) = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let oid = try await RemoteParents().fetch(repo: repo, .pullRequest(7))
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
        let wm = WorktreeManager(config: config)
        let out = try wm.ensure(repo: repo, branch: "childR", base: "refs/orch/parents/pr-7")
        #expect(out.created)
        let head = try Proc.run(["git", "-C", out.worktree, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == oid)   // new branch starts exactly at the fetched PR tip
    }

    @Test("an unknown refs/ start-point throws and leaves no worktree dir")
    func unknownPrivateRef() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        _ = svc
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
        let wm = WorktreeManager(config: config)
        #expect(throws: (any Error).self) {
            try wm.ensure(repo: repo, branch: "childX", base: "refs/orch/parents/pr-999")
        }
        #expect(!FileManager.default.fileExists(atPath: wm.path(repo: repo, branch: "childX")))
    }
}
