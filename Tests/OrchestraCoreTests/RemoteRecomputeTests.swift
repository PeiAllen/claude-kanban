import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, remote-git). S1-1: TreeStat/`synced` must resolve a remote parent (`pr#N`) to
/// its fetched private ref. The private-ref fetch runs over `FakeProc` (`RemoteRules` lands
/// `refs/orch/parents/pr/7` into the shared `RepoGraph`), so the whole recompute/synced path — resolve →
/// `treeTip`/`treeBehind`/`merge-base` — runs over the seam, pinned to real git by
/// ContractTests/Git/RemoteFetchContractTests (fetch/ls-remote) + GitRevContractTests (rev probes). The
/// S2-1 merge-base case models the child + parent branches in the RepoGraph. No real git in this file.
@Suite("Remote-parent recompute + synced (S1-1)")
struct RemoteRecomputeTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    /// A service whose git seam is a FakeProc carrying the config emulator + a RepoGraph + RemoteRules with
    /// `pr#7` reachable at a minted tip. `gh` is a non-available fake so an auto-started watch never shells
    /// real `gh`. Returns the service + a fake repo dir.
    static func remoteSetup() async -> (svc: OrchestraService, graph: RepoGraph, rules: RemoteRules, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let (graph, rules) = RepoScripts.withRemote(on: fake)
        rules.reachable(remote: "origin", src: "refs/pull/7/head")
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        await svc.setGh(FakeGh(available: false))
        return (svc, graph, rules, TestEnv.repo(base))
    }

    @Test("recompute on a pr# parent card resolves the private ref → inSync, parentIsRemote true")
    func remoteParentRecomputeInSync() async throws {
        let (svc, _, _, repo) = await Self.remoteSetup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.stopRemoteWatch(card.id)                   // drive recompute deterministically
        await svc.recomputeTreeStat(card.id)                 // the funnel's ~750ms recompute, run directly
        let ts = try #require(await treeStat(svc, card.id))
        #expect(ts.state == .inSync)                          // was a false .restackNeeded before the fix
        #expect(ts.behind == 0)
        #expect(ts.parentIsRemote == true)                   // was dropped before the fix
    }

    // S2-1: `synced` must record merge-base(child-HEAD, parent), NOT the trusted parent tip. If the
    // parent advances between the child's merge and its `synced` call, over-recording the tip would
    // mask the un-merged parent work (a false inSync). The child + parent branches are modelled in the
    // RepoGraph so the merge-base is the true fork point (pinned by GitRevContractTests).
    @Test("S2-1: synced records merge-base(child,parent) — a racy parent advance isn't over-recorded")
    func syncedRecordsMergeBase() async throws {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withParent(on: fake)          // main base + `parent` branch at that tip
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(base)
        let base0 = graph.tip("parent")!

        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child", base: "parent"))
        graph.branch("child", at: "parent")                   // the child branch really forks parent@base0

        // Parent advances to base1 AFTER the child's claimed merge, BEFORE synced (the race).
        RepoScripts.advanceParent(graph, 1)

        _ = try await svc.synced(ref: card.ref())
        let link = try #require(await svc.lineage.read(repo: repo, branch: "child"))
        #expect(link.base == base0)                                     // merge-base, NOT the advanced tip
        #expect(await treeStat(svc, card.id)?.state == .stale)          // still behind base1
    }

    @Test("synced on a pr# parent card resolves the private ref (no 'parent ref not found')")
    func syncedRemoteParent() async throws {
        let (svc, _, _, repo) = await Self.remoteSetup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.stopRemoteWatch(card.id)
        _ = try await svc.synced(ref: card.ref())            // must not throw for a remote parent
        #expect(await treeStat(svc, card.id)?.state == .inSync)
    }
}
