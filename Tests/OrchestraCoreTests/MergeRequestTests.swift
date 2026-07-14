import Foundation
import Testing
@testable import OrchestraCore

/// O2: the first-class `merge-request` op — the daemon composes the canonical prose once (instead of
/// two skill paraphrases), records a `mergeRequested` waiting state on the child, dedups re-sends, and
/// is cleared by `shipped`.
@Suite("merge-request — first-class request/response (O2, S2-2)")
struct MergeRequestTests {

    private func treeState(_ svc: OrchestraService, _ id: UUID) async -> TreeState? {
        await svc.list().first { $0.id == id }?.treeStat?.state
    }

    @Test("merge-request nudges the parent card with canonical prose + sets child mergeRequested")
    func requestNudgesParentSetsState() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        _ = try await env.svc.mergeRequest(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.contains { $0.text.contains("merge-request") && $0.text.contains("child") })
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
    }

    @Test("re-sending merge-request dedups — the parent gets one request, not two")
    func requestDedups() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        _ = try await env.svc.mergeRequest(ref: child.ref())
        _ = try await env.svc.mergeRequest(ref: child.ref())   // re-send: already pending

        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("merge-request") }
        #expect(requests.count == 1)
    }

    @Test("recompute preserves mergeRequested (the waiting badge is sticky until shipped/synced)")
    func recomputePreservesMergeRequested() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.recomputeTreeStat(child.id)              // a funnel recompute must not clobber it
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
    }

    @Test("shipped clears the child's mergeRequested state")
    func shippedClearsMergeRequested() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        try TreeStatTests.advanceParent(repo, 1)               // simulate the merge (S2-2 gate)
        try await env.svc.shipped(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == nil)     // cleared with the lineage
    }
}
