import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Unit-converted (Task 10, branch-tree) — the parent commit graph is modelled by RepoGraph over
/// FakeProc (fidelity pinned by GitRevContractTests); the lineage link lives in GitConfigEmulator.
@Suite("Stale nudge — inSync→stale transition only")
struct StaleNudgeTests {

    @Test("inSync → stale enqueues exactly one nudge; stale → stale is silent")
    func transitionOnly() async throws {
        let (env, fake, graph, repo) = TreeStatTests.setup()
        let base0 = graph.tip("parent")!
        let card = try await TreeStatTests.linkedChild(env, fake: fake, repo: repo, base: base0)

        await env.svc.recomputeTreeStat(card.id)                    // inSync established — no nudge
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)

        RepoScripts.advanceParent(graph, 1)                         // parent moves
        await env.svc.recomputeTreeStat(card.id)                    // inSync → stale ⇒ nudge
        let after1 = try await env.svc.inboxPeek(card.id)
        #expect(after1.count == 1)
        #expect(after1.first?.text.contains("moved ahead") == true)
        #expect(after1.first?.text.contains("git merge") == true)   // names the literal runnable command
        #expect(after1.first?.text.contains("orchestra synced") == true)

        RepoScripts.advanceParent(graph, 1)                         // parent moves again
        await env.svc.recomputeTreeStat(card.id)                    // stale → stale (behind changes) — silent
        #expect(try await env.svc.inboxPeek(card.id).count == 1)    // still exactly one
    }

    @Test("first-ever compute landing on stale does NOT nudge (transition edge only)")
    func noNudgeWithoutInSyncPredecessor() async throws {
        let (env, fake, graph, repo) = TreeStatTests.setup()
        let base0 = graph.tip("parent")!
        let card = try await TreeStatTests.linkedChild(env, fake: fake, repo: repo, base: base0)
        RepoScripts.advanceParent(graph, 1)                         // parent already ahead at first compute
        await env.svc.recomputeTreeStat(card.id)                    // nil → stale, no inSync predecessor
        #expect(await env.svc.list().first { $0.id == card.id }?.treeStat?.state == .stale)
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)       // no nudge without the inSync→stale edge
    }

    @Test("a parent card's report fans out ⇒ its live child recomputes, goes stale, and is nudged")
    func funnelStalesLiveChild() async throws {
        let (env, fake, graph, repo) = TreeStatTests.setup()
        let base0 = graph.tip("parent")!
        // A live parent card owning branch "parent", plus the linked child.
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TreeStatTests.linkedChild(env, fake: fake, repo: repo, base: base0)
        await env.svc.recomputeTreeStat(child.id)                   // inSync baseline
        RepoScripts.advanceParent(graph, 1)                         // parent tip moves

        // The parent card reports activity → funnel schedules the child's TreeStat recompute. The path
        // debounces twice (fan-out 750ms → child recompute 750ms) on the service's production-default
        // ContinuousClock, so the condition converges in ~1.5s; the poll itself is yield-based, not a sleep.
        try await env.svc.report(parentCard.id, StatusReport(desc: "did work", run: .running))
        try await pollUntil("the funnel's staleness nudge reached the child") {
            (try? await env.svc.inboxPeek(child.id))?.isEmpty == false
        }
        let msgs = try await env.svc.inboxPeek(child.id)
        #expect(msgs.count == 1)                                    // fan-out coalesced ⇒ exactly one nudge
        #expect(msgs.first?.text.contains("moved ahead") == true)
    }
}
