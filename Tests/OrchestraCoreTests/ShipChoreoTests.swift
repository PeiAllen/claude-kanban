import Foundation
import Testing
@testable import OrchestraCore

@Suite("Ship choreography — shipped notify + retarget + idempotence")
struct ShipChoreoTests {

    /// A repo on main with `parent`, plus a `child` branch off parent's tip. Returns (repo, parent tip).
    static func repoWithChild(_ base: String) throws -> (repo: String, parentTip: String) {
        let repo = try TreeStatTests.repoWithParent(base)   // main + parent
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "child", "parent")
        try TreeStatTests.write(repo, "c.txt", "child\n")
        try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "child work")
        try TreeStatTests.git(repo, "checkout", "-q", "main")
        let parentTip = try TreeStatTests.git(repo, "rev-parse", "parent")
        return (repo, parentTip)
    }

    // (a) live parent card gets an inbox message + wake
    @Test("live parent card is notified when its child ships")
    func liveParentNotified() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        try await env.svc.shipped(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text.contains("child") == true)
        #expect(msgs.first?.text.contains("merged into you") == true)
        // shipped clears the child's own lineage (idempotency key)
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    // (a) bare parent (no card) ⇒ warning activity, no throw
    @Test("bare parent (no card) yields a warning activity, not a throw")
    func bareParentActivity() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        try await env.svc.shipped(ref: child.ref())   // must not throw (no parent card)

        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.contains { $0.text.contains("parent") })
    }

    // (b) two children retargeted to grandparent, base preserved, restackNeeded, nudged; idempotent
    @Test("shipping a mid branch retargets its two children onto the grandparent (base kept), once")
    func retargetsGrandchildren() async throws {
        let env = TestEnv.make()
        // Tree: main → grandparent → mid → {c1, c2}. Ship `mid`.
        let repo = TestEnv.repo(env.base)
        try TreeStatTests.git(repo, "init", "-q", "-b", "main")
        try TreeStatTests.git(repo, "config", "user.email", "t@t")
        try TreeStatTests.git(repo, "config", "user.name", "t")
        try TreeStatTests.write(repo, "a.txt", "0\n")
        try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "base")
        try TreeStatTests.git(repo, "branch", "grandparent")
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "mid", "grandparent")
        try TreeStatTests.write(repo, "m.txt", "m\n"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "mid work")
        let midTip = try TreeStatTests.git(repo, "rev-parse", "mid")
        try TreeStatTests.git(repo, "branch", "c1", "mid")
        try TreeStatTests.git(repo, "branch", "c2", "mid")
        try TreeStatTests.git(repo, "checkout", "-q", "main")
        let grandparentTip = try TreeStatTests.git(repo, "rev-parse", "grandparent")

        let mid = try await env.svc.spawn(SpawnInput(prompt: "mid", repo: repo, branch: "mid"))
        let c1 = try await env.svc.spawn(SpawnInput(prompt: "c1", repo: repo, branch: "c1"))
        let c2 = try await env.svc.spawn(SpawnInput(prompt: "c2", repo: repo, branch: "c2"))
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "mid",
                          link: ParentLink(parent: "grandparent", base: grandparentTip))
        try await lin.set(repo: repo, branch: "c1", link: ParentLink(parent: "mid", base: midTip))
        try await lin.set(repo: repo, branch: "c2", link: ParentLink(parent: "mid", base: midTip))

        try await env.svc.shipped(ref: mid.ref())

        // repointed to grandparent, base KEPT (== midTip)
        let l1 = try #require(await lin.read(repo: repo, branch: "c1"))
        let l2 = try #require(await lin.read(repo: repo, branch: "c2"))
        #expect(l1.parent == "grandparent" && l1.base == midTip)
        #expect(l2.parent == "grandparent" && l2.base == midTip)
        // treeStat restackNeeded on the cards
        #expect(await env.svc.list().first { $0.id == c1.id }?.treeStat?.state == .restackNeeded)
        #expect(await env.svc.list().first { $0.id == c2.id }?.treeStat?.state == .restackNeeded)
        // nudged with the rebase --onto command + recorded base
        let n1 = try await env.svc.inboxPeek(c1.id)
        #expect(n1.count == 1)
        #expect(n1.first?.text.contains("rebase --onto grandparent \(midTip)") == true)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)

        // idempotent re-run: mid's link cleared + children already repointed ⇒ no new nudges
        try await env.svc.shipped(ref: mid.ref())
        #expect(try await env.svc.inboxPeek(c1.id).count == 1)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)
    }
}
