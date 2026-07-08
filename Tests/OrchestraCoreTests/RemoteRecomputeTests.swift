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
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.recomputeTreeStat(card.id)                 // the funnel's ~750ms recompute, run directly
        let ts = try #require(await treeStat(svc, card.id))
        #expect(ts.state == .inSync)                          // was a false .restackNeeded before the fix
        #expect(ts.behind == 0)
        #expect(ts.parentIsRemote == true)                   // was dropped before the fix
    }

    @Test("synced on a pr# parent card resolves the private ref (no 'parent ref not found')")
    func syncedRemoteParent() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        _ = try await svc.synced(ref: card.ref())            // must not throw for a remote parent
        #expect(await treeStat(svc, card.id)?.state == .inSync)
    }
}
