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
        try TreeStatTests.advanceParent(repo, 1)   // simulate the parent agent's squash-merge (S2-2 gate)

        try await env.svc.shipped(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text.contains("child") == true)
        #expect(msgs.first?.text.contains("merged into you") == true)
        // shipped clears the child's own lineage (idempotency key)
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    // (a) bare parent (no card) ⇒ neutral activity (S3-1: NOT a warning — it's the documented success
    // path where the child borrowed + merged the bare parent), no throw.
    @Test("bare parent (no card) yields a neutral (non-warning) activity, not a throw")
    func bareParentActivity() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        try TreeStatTests.advanceParent(repo, 1)   // simulate the merge (S2-2 gate)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        try await env.svc.shipped(ref: child.ref())   // must not throw (no parent card)

        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let acts = await collector.activities
        #expect(acts.contains { $0.text.contains("bare parent") })
        #expect(!acts.contains { $0.kind == .warning && $0.text.contains("no active card owns") })
    }

    // S2-2: shipped must refuse when the parent tip hasn't advanced past the recorded base (nothing was
    // merged) — otherwise a mistaken/aborted call rebases grandchildren toward data loss. --force overrides.
    @Test("S2-2: shipped refuses when nothing was merged; force overrides")
    func shippedRefusesWhenNothingMerged() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        // Parent has NOT advanced — nothing merged. Refuse, and leave the lineage intact.
        await #expect(throws: OrchestraError.self) { try await env.svc.shipped(ref: child.ref()) }
        #expect(await BranchLineage().read(repo: repo, branch: "child") != nil)
        // Force overrides (a genuinely empty squash).
        _ = try await env.svc.shipped(ref: child.ref(), force: true)
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    // S2-5 (minimal): archiving a worktree card must nudge its live children — the parent branch is now
    // bare, and a stopped child would otherwise wait on a rotted inbox forever.
    @Test("archiving a parent card nudges its live children (parent branch now bare)")
    func archiveNudgesLiveChildren() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        try await env.svc.archive(parentCard.id)

        let msgs = try await env.svc.inboxPeek(child.id)
        #expect(msgs.contains { $0.text.contains("archived") })
    }

    // S3-5: an archived card must not get a post-archive treeStat rewrite even if a recompute fires.
    @Test("recompute on an archived card is a no-op")
    func archivedCardNoRecompute() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let tip = try TreeStatTests.git(repo, "rev-parse", "parent")
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: tip))
        try await env.svc.archive(card.id)
        await env.svc.recomputeTreeStat(card.id)
        #expect(await env.svc.list(includeArchived: true).first { $0.id == card.id }?.treeStat == nil)
    }

    // S1-3: the shipped child (a stopped card waiting on its live parent) must be TOLD its merge
    // landed — else it's a zombie card forever. And the parent that performed the merge must not get
    // a wasted self-echo.
    @Test("live-parent ship notifies+wakes the child; parent self-echo skipped when caller is the parent")
    func shippedNotifiesChild() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try Self.repoWithChild(env.base)
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        try TreeStatTests.advanceParent(repo, 1)   // simulate the parent's squash-merge (S2-2 gate)

        // The PARENT agent performed the squash-merge and calls `orchestra shipped <child>` — caller = parent.
        try await env.svc.shipped(ref: child.ref(), by: parentCard.ref())

        // (d) the child is told its branch landed.
        let childMsgs = try await env.svc.inboxPeek(child.id)
        #expect(childMsgs.contains { $0.text.contains("landed") })
        // parent self-echo skipped (the caller IS the parent — it just did the merge).
        #expect(try await env.svc.inboxPeek(parentCard.id).isEmpty)
    }

    // S1-2 goal-4: a ROOT card (no parent link) shipping to main must still retarget its children
    // onto the default branch — otherwise the child shows inSync-forever against a dead parent.
    @Test("root ship (no parent link) retargets children onto the default branch — goal-4")
    func rootShipRetargetsChildren() async throws {
        let env = TestEnv.make()
        // main → A → B; A is a ROOT (no parent link), ships to main.
        let repo = TestEnv.repo(env.base)
        try TreeStatTests.git(repo, "init", "-q", "-b", "main")
        try TreeStatTests.git(repo, "config", "user.email", "t@t")
        try TreeStatTests.git(repo, "config", "user.name", "t")
        try TreeStatTests.write(repo, "a.txt", "0\n"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "base")
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "A", "main")
        try TreeStatTests.write(repo, "A.txt", "a\n"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "A work")
        let aTip = try TreeStatTests.git(repo, "rev-parse", "A")
        try TreeStatTests.git(repo, "branch", "B", "A")
        try TreeStatTests.git(repo, "checkout", "-q", "main")

        let a = try await env.svc.spawn(SpawnInput(prompt: "A", repo: repo, branch: "A"))   // no link
        let b = try await env.svc.spawn(SpawnInput(prompt: "B", repo: repo, branch: "B"))
        try await BranchLineage().set(repo: repo, branch: "B", link: ParentLink(parent: "A", base: aTip))

        try await env.svc.shipped(ref: a.ref())

        // B retargeted onto the default branch (main), recorded base KEPT, restackNeeded + nudged.
        let lB = try #require(await BranchLineage().read(repo: repo, branch: "B"))
        #expect(lB.parent == "main")
        #expect(lB.base == aTip)
        #expect(await env.svc.list().first { $0.id == b.id }?.treeStat?.state == .restackNeeded)
        let nB = try await env.svc.inboxPeek(b.id)
        #expect(nB.first?.text.contains("rebase --onto refs/heads/main \(aTip)") == true)
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
        // Simulate mid's squash-merge into grandparent so grandparent advances past mid's base (S2-2 gate).
        try TreeStatTests.git(repo, "checkout", "-q", "grandparent")
        try TreeStatTests.write(repo, "gp-merge.txt", "merged"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "merge mid")
        try TreeStatTests.git(repo, "checkout", "-q", "main")

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
        #expect(n1.first?.text.contains("rebase --onto refs/heads/grandparent \(midTip)") == true)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)

        // idempotent re-run: mid's link cleared + children already repointed ⇒ no new nudges
        try await env.svc.shipped(ref: mid.ref())
        #expect(try await env.svc.inboxPeek(c1.id).count == 1)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)
    }
}
