import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, branch-tree). The commit graph the real repo used to hold is modelled by
/// `RepoGraph` (TestSupport/RepoScripts.swift), whose `rev-parse`/`rev-list --count`/`merge-base
/// --is-ancestor` answers are pinned to real git by ContractTests/Git/GitRevContractTests. The service's
/// tree probes run over `FakeProc`; the lineage link is stored in `GitConfigEmulator`. No real git.
@Suite("TreeStat compute — child lineage state vs a modelled parent branch")
struct TreeStatTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)

    /// A service whose git seam is a FakeProc carrying the config emulator + a RepoGraph seeded with one
    /// base commit on `main` and a `parent` branch at that tip. Returns everything a case needs.
    static func setup() -> (env: Env, fake: FakeProc, graph: RepoGraph, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withParent(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)   // a bare dir (no git) — the fake answers every git verb
        return (env, fake, graph, repo)
    }

    /// Spawn a `.worktree` card on `child` linked to `parent` with the given recorded base, storing the
    /// link through the SAME fake (so the service's `lineage.read` sees it).
    static func linkedChild(_ env: Env, fake: FakeProc, repo: String, base recorded: String) async throws -> Task {
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: card.repo, branch: "child",
                                                link: ParentLink(parent: "parent", base: recorded))
        return card
    }

    private func treeStat(_ env: Env, _ id: UUID) async -> TreeStat? {
        await env.svc.list().first { $0.id == id }?.treeStat
    }

    // (MARK: LEGACY real-git fixtures — repoWithParent / advanceParent / git / write / the real-git
    // linkedChild overload — DELETED in Task 10 card-lifecycle. Their last consumer,
    // ShipChoreoTests.repoWithChild, was itself deleted when ServiceTeardownTests converted to
    // RepoScripts.withChild; TreeStatTests's own cases already use RepoScripts + the `fake:` linkedChild.)

    // MARK: compute cases

    @Test("base == parent tip ⇒ inSync, behind 0")
    func inSync() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let tip = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: tip)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .inSync)
        #expect(ts.behind == 0)
    }

    @Test("parent 2 commits ahead of the recorded base ⇒ stale, behind 2")
    func staleBehindTwo() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let base0 = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: base0)
        RepoScripts.advanceParent(graph, 2)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .stale)
        #expect(ts.behind == 2)
    }

    @Test("recorded base no longer an ancestor (amended parent) ⇒ restackNeeded")
    func restackOnAmend() async throws {
        let (env, fake, graph, repo) = Self.setup()
        RepoScripts.advanceParent(graph, 1)
        let base1 = graph.tip("parent")!                 // record this tip
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: base1)
        graph.amend("parent")                            // rewrite the tip so base1 is orphaned
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("parent branch deleted ⇒ restackNeeded")
    func restackOnDeletedParent() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let tip = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: tip)
        graph.deleteBranch("parent")
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("a card with no parent link stays treeStat nil")
    func noLinkNoStat() async throws {
        let (env, _, _, repo) = Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "solo", repo: repo, branch: "solo"))
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id) == nil)
    }

    @Test("an empty recorded base ⇒ restackNeeded (can't validate the anchor)")
    func emptyBaseRestack() async throws {
        let (env, fake, _, repo) = Self.setup()
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: "")
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    // MARK: synced round-trip

    @Test("synced records the parent tip as the base ⇒ back to inSync, base advanced")
    func syncedRoundTrip() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let base0 = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: base0)
        let tip2 = RepoScripts.advanceParent(graph, 2)             // parent 2 ahead
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .stale)

        _ = try await env.svc.synced(ref: card.ref())              // "I merged the parent down"
        #expect(await treeStat(env, card.id)?.state == .inSync)
        #expect(await treeStat(env, card.id)?.behind == 0)
        let link = try #require(await BranchLineage(proc: fake).read(repo: card.repo, branch: "child"))
        #expect(link.base == tip2)                                 // recorded base advanced to parent tip
    }

    // S2-9: the inSync→stale nudge is edge-triggered. Two recomputes racing across the lineage.read
    // suspension must not each see the pre-edge `inSync` and fire a duplicate nudge — the edge is
    // computed against the freshly-persisted value, so exactly ONE nudge lands.
    @Test("S2-9: concurrent recomputes on the inSync→stale edge fire exactly one nudge")
    func noDuplicateStaleNudge() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let base0 = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: base0)
        await env.svc.recomputeTreeStat(card.id)                 // establish persisted inSync
        #expect(await treeStat(env, card.id)?.state == .inSync)
        RepoScripts.advanceParent(graph, 1)                      // parent now ahead → next recompute = stale

        async let a: Void = env.svc.recomputeTreeStat(card.id)
        async let b: Void = env.svc.recomputeTreeStat(card.id)
        _ = await (a, b)

        let nudges = try await env.svc.inboxPeek(card.id).filter { $0.text.contains("moved ahead") }
        #expect(nudges.count == 1)
    }

    // S4: an organic inSync→restackNeeded (parent amended/rebased with no shipped/set-parent) must
    // nudge — it was the one restack path with no notifier.
    @Test("S4: organic inSync→restackNeeded (parent amended) fires a restack nudge")
    func organicRestackNudge() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let tip = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: tip)
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .inSync)
        graph.amend("parent")                                    // rewrite tip → recorded base orphaned
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
        let msgs = try await env.svc.inboxPeek(card.id)
        #expect(msgs.contains { $0.text.contains("changed history") && $0.text.contains("rebase --onto") })
    }

    @Test("synced on a card with no parent link throws invalidParams")
    func syncedNoLink() async throws {
        let (env, _, _, repo) = Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "solo", repo: repo, branch: "solo"))
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.synced(ref: card.ref())
        }
    }

    @Test("synced when the parent ref is gone throws invalidParams")
    func syncedMissingParent() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let tip = graph.tip("parent")!
        let card = try await Self.linkedChild(env, fake: fake, repo: repo, base: tip)
        graph.deleteBranch("parent")
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.synced(ref: card.ref())
        }
    }
}
