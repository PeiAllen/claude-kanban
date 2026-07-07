import Foundation
import Testing
@testable import OrchestraCore

@Suite("Stale nudge — inSync→stale transition only")
struct StaleNudgeTests {

    @Test("inSync → stale enqueues exactly one nudge; stale → stale is silent")
    func transitionOnly() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        let card = try await TreeStatTests.linkedChild(env, repo: repo, base: base0)  // .running card

        await env.svc.recomputeTreeStat(card.id)                    // inSync established — no nudge
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)

        try TreeStatTests.advanceParent(repo, 1)                    // parent moves
        await env.svc.recomputeTreeStat(card.id)                    // inSync → stale ⇒ nudge
        let after1 = try await env.svc.inboxPeek(card.id)
        #expect(after1.count == 1)
        #expect(after1.first?.text.contains("moved ahead") == true)
        #expect(after1.first?.text.contains("orchestra synced") == true)

        try TreeStatTests.advanceParent(repo, 1)                    // parent moves again
        await env.svc.recomputeTreeStat(card.id)                    // stale → stale (behind changes) — silent
        #expect(try await env.svc.inboxPeek(card.id).count == 1)    // still exactly one
    }

    @Test("first-ever compute landing on stale does NOT nudge (transition edge only)")
    func noNudgeWithoutInSyncPredecessor() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        let card = try await TreeStatTests.linkedChild(env, repo: repo, base: base0)
        try TreeStatTests.advanceParent(repo, 1)                    // parent already ahead at first compute
        await env.svc.recomputeTreeStat(card.id)                    // nil → stale, no inSync predecessor
        #expect(await env.svc.list().first { $0.id == card.id }?.treeStat?.state == .stale)
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)       // no nudge without the inSync→stale edge
    }
}
