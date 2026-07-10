import Foundation
import Testing
@testable import OrchestraCore

/// S1-1: TreeStat/`synced` must resolve a remote parent (`pr#N` / `origin/<b>`) to its fetched private
/// ref — the exact case with NO coverage before this round. Before the fix, `rev-parse pr#7` fails so
/// `computeTreeStat` flips to a false `restackNeeded` and drops `parentIsRemote`, and `synced` throws
/// `parent ref not found: pr#7`.
@Suite("Remote-parent recompute + synced (S1-1)")
struct RemoteRecomputeTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    @Test("recompute on a pr# parent card resolves the private ref → inSync, parentIsRemote true")
    func remoteParentRecomputeInSync() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.recomputeTreeStat(card.id)                 // the funnel's ~750ms recompute, run directly
        let ts = try #require(await treeStat(svc, card.id))
        #expect(ts.state == .inSync)                          // was a false .restackNeeded before the fix
        #expect(ts.behind == 0)
        #expect(ts.parentIsRemote == true)                   // was dropped before the fix
    }

    // S2-1: `synced` must record merge-base(child-HEAD, parent), NOT the trusted parent tip. If the
    // parent advances between the child's merge and its `synced` call, over-recording the tip would
    // mask the un-merged parent work (a false inSync). Real worktree so the child branch actually exists.
    @Test("S2-1: synced records merge-base(child,parent) — a racy parent advance isn't over-recorded")
    func syncedRecordsMergeBase() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        try g("init", "-q", "-b", "main"); try g("config", "user.email", "t@t"); try g("config", "user.name", "t")
        try "0\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "base"); try g("branch", "parent")
        let base0 = try Proc.run(["git", "-C", repo, "rev-parse", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "c", repo: repo, branch: "child", base: "parent"))

        // Parent advances to base1 AFTER the child's claimed merge, BEFORE synced (the race).
        try g("checkout", "-q", "parent")
        try "p\n".write(toFile: repo + "/p.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "p1"); try g("checkout", "-q", "main")

        _ = try await svc.synced(ref: card.ref())
        let link = try #require(await svc.lineage.read(repo: repo, branch: "child"))
        #expect(link.base == base0)                                     // merge-base, NOT the advanced tip
        #expect(await treeStat(svc, card.id)?.state == .stale)          // still behind base1
    }

    @Test("synced on a pr# parent card resolves the private ref (no 'parent ref not found')")
    func syncedRemoteParent() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        _ = try await svc.synced(ref: card.ref())            // must not throw for a remote parent
        #expect(await treeStat(svc, card.id)?.state == .inSync)
    }
}
