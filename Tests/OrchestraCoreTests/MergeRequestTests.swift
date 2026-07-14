import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// O2: the first-class `merge-request` op — the daemon composes the canonical prose once (instead of
/// two skill paraphrases), records a `mergeRequested` waiting state on the child, dedups re-sends, and
/// is cleared by `shipped`.
///
/// Unit-converted (Task 10, merge-collab): the parent/child commit graph is modelled over
/// `FakeProc`/`RepoGraph` (TestSupport/RepoScripts.swift, pinned to real git by
/// ContractTests/Git/GitRevContractTests) and the lineage link lives in `GitConfigEmulator`
/// (pinned by GitConfigContractTests). Every assertion is an inbox-nudge / treeStat-state fact — no
/// real-git effect — so this is a clean 1:1 conversion. No real git.
@Suite("merge-request — first-class request/response (O2, S2-2)")
struct MergeRequestTests {

    private func treeState(_ svc: OrchestraService, _ id: UUID) async -> TreeState? {
        await svc.list().first { $0.id == id }?.treeStat?.state
    }

    /// A FakeProc-backed env with main + parent + child (parent tip recorded).
    private func setup() -> (env: TreeStatTests.Env, fake: FakeProc, graph: RepoGraph, repo: String, parentTip: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withChild(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)
        return (env, fake, graph, repo, graph.tip("parent")!)
    }

    @Test("merge-request nudges the parent card with canonical prose + sets child mergeRequested")
    func requestNudgesParentSetsState() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        _ = try await env.svc.mergeRequest(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.contains { $0.text.contains("merge-request") && $0.text.contains("child") })
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
    }

    @Test("re-sending merge-request dedups — the parent gets one request, not two")
    func requestDedups() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        _ = try await env.svc.mergeRequest(ref: child.ref())
        _ = try await env.svc.mergeRequest(ref: child.ref())   // re-send: already pending

        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("merge-request") }
        #expect(requests.count == 1)
    }

    @Test("recompute preserves mergeRequested (the waiting badge is sticky until shipped/synced)")
    func recomputePreservesMergeRequested() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.recomputeTreeStat(child.id)              // a funnel recompute must not clobber it
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
    }

    @Test("shipped clears the child's mergeRequested state")
    func shippedClearsMergeRequested() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        RepoScripts.advanceParent(graph, 1)                    // simulate the merge (S2-2 gate)
        try await env.svc.shipped(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == nil)     // cleared with the lineage
    }
}
