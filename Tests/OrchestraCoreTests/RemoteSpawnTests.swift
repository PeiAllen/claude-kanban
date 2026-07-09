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
        let wm = WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let out = try await wm.ensure(repo: repo, branch: "childR", cardId: UUID(), base: "refs/orch/parents/pr/7")
        #expect(out.created)
        let head = try Proc.run(["git", "-C", out.path, "rev-parse", "HEAD"]).stdout
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
        let wm = WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        await #expect(throws: (any Error).self) {
            _ = try await wm.ensure(repo: repo, branch: "childX", cardId: UUID(), base: "refs/orch/parents/pr/999")
        }
        #expect(!FileManager.default.fileExists(atPath: wm.path(repo: repo, branch: "childX")))
    }

    @Test("spawn(base: pr#7) fetches, starts the child at the PR tip, records remote lineage")
    func spawnRemoteBase() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let prTip = try await RemoteParents().fetch(repo: repo, .pullRequest(7))  // expected OID
        let t = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(t.parentBranch == "pr#7")                    // canonical remote form stored
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "pr#7")
        #expect(link.prNumber == 7)
        #expect(link.watch == true)                          // auto-watch on a remote-base spawn
        #expect(link.base == prTip)                          // recorded base = fetched PR tip
        // The child worktree HEAD equals the PR tip (start-point equality).
        let head = try Proc.run(["git", "-C", t.cwd, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == prTip)
    }

    @Test("spawn(base: origin/feature-b) records a remote branch parent (no pr number)")
    func spawnRemoteBranchBase() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let t = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childB", base: "origin/feature-b"))
        #expect(t.parentBranch == "origin/feature-b")
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childB"))
        #expect(link.prNumber == nil)
        #expect(link.watch == true)
    }
}
