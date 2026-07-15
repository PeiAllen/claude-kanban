//
// Whole-suite contract candidate (Task 10, remote-git): every case is a REAL-worktree effect — a real
// `RemoteParents.fetch` lands a private ref, then `WorktreeRegistry.ensure(base:)` cuts a real worktree
// whose HEAD must EQUAL the fetched OID (start-point equality), an unknown start-point throws and leaves
// no worktree dir, and the `origin/feature-b` branch case needs the repo's REAL configured remotes
// (`gitRemotes` shells real git, not the seam) to classify. None of that is a decision a FakeProc could
// stand in for, so the suite stays real git (over `makeReal`) and relocates verbatim at the flip.

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
        let oid = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
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
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
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
        let prTip = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))  // expected OID
        let t = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
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
        let t = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childB", base: "origin/feature-b"))
        #expect(t.parentBranch == "origin/feature-b")
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childB"))
        #expect(link.prNumber == nil)
        #expect(link.watch == true)
    }
}
