import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Unit-converted (Task 10, merge-collab): the parent/child/grandchild commit graphs are modelled over
/// FakeProc/RepoGraph (TestSupport/RepoScripts.swift, pinned to real git by
/// ContractTests/Git/GitRevContractTests) and lineage lives in GitConfigEmulator (pinned by
/// GitConfigContractTests). The one genuine real-git effect — that shipped's notify+retarget+clear runs
/// end-to-end when a REAL merge advanced the parent — is distilled into
/// ContractTests/Git/ShipChoreoContractTests. No real git here.
@Suite("Ship choreography — shipped notify + retarget + idempotence")
struct ShipChoreoTests {

    // (LEGACY real-git fixture `repoWithChild` DELETED in Task 10 card-lifecycle: its only remaining
    // consumer, ServiceTeardownTests, converted to RepoScripts.withChild over FakeProc.)

    /// A FakeProc-backed env with main + parent + child modelled over RepoGraph (parent tip recorded),
    /// lineage in the config emulator. The unit analogue of `repoWithChild`.
    private func setup() -> (env: TreeStatTests.Env, fake: FakeProc, graph: RepoGraph, repo: String, parentTip: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withChild(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)
        return (env, fake, graph, repo, graph.tip("parent")!)
    }

    // (a) live parent card gets an inbox message + wake
    @Test("live parent card is notified when its child ships")
    func liveParentNotified() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)   // simulate the parent agent's squash-merge (S2-2 gate)

        try await env.svc.shipped(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text.contains("child") == true)
        #expect(msgs.first?.text.contains("merged into you") == true)
        // shipped clears the child's own lineage (idempotency key)
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "child") == nil)
    }

    // (a) bare parent (no card) ⇒ neutral activity (S3-1: NOT a warning — it's the documented success
    // path where the child borrowed + merged the bare parent), no throw.
    @Test("bare parent (no card) yields a neutral (non-warning) activity, not a throw")
    func bareParentActivity() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)   // simulate the merge (S2-2 gate)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        try await env.svc.shipped(ref: child.ref())   // must not throw (no parent card)

        try await pollUntil("bare-parent notice delivered") {
            await collector.activities.contains { $0.text.contains("bare parent") }
        }
        await yieldBriefly()   // settle so a wrongful ownership warning would also have landed
        let acts = await collector.activities
        #expect(acts.contains { $0.text.contains("bare parent") })
        #expect(!acts.contains { $0.kind == .warning && $0.text.contains("no active card owns") })
    }

    // S2-2: shipped must refuse when the parent tip hasn't advanced past the recorded base (nothing was
    // merged) — otherwise a mistaken/aborted call rebases grandchildren toward data loss. --force overrides.
    @Test("S2-2: shipped refuses when nothing was merged; force overrides")
    func shippedRefusesWhenNothingMerged() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        // Parent has NOT advanced — nothing merged. Refuse, and leave the lineage intact.
        await #expect(throws: OrchestraError.self) { try await env.svc.shipped(ref: child.ref()) }
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "child") != nil)
        // slice 4: the zero-commit false-positive guard (S2-2) fires BEFORE the removal funnel, so a
        // no-merge ship never bumps the counter (the guard is the merge-classification for this path).
        #expect(await BranchLineage(proc: fake).mergedCount(repo: repo, branch: "parent") == 0)
        // Force overrides (a genuinely empty squash).
        _ = try await env.svc.shipped(ref: child.ref(), force: true)
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "child") == nil)
    }

    // slice 4: a merge-classified ship increments the parent's merged-count, broadcasts it on the parent
    // card's treeStat, and drains the parent when the shipped child was the last one.
    @Test("shipped counts on the parent + broadcasts mergedChildren + drains when it was the last child")
    func shippedCountsAndDrains() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)   // simulate the squash-merge (S2-2 gate)

        try await env.svc.shipped(ref: child.ref())

        #expect(await lin.mergedCount(repo: repo, branch: "parent") == 1)
        let pStat = try #require(await env.svc.list().first { $0.id == parentCard.id }?.treeStat)
        #expect(pStat.mergedChildren == 1)
        #expect(pStat.drained == true)   // the child was the only lineage child → wave done by merges
    }

    // Provenance: `drained` must NOT set while another live child remains (only the merge-removal that
    // EMPTIES the lineage drains it), and the count increments exactly once per merge.
    @Test("shipped does not drain the parent while a sibling remains; counts once")
    func shippedNoDrainWithSibling() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentTip))
        try await lin.set(repo: repo, branch: "sibling", link: ParentLink(parent: "parent", base: parentTip))  // stays behind
        RepoScripts.advanceParent(graph, 1)

        try await env.svc.shipped(ref: child.ref())

        #expect(await lin.mergedCount(repo: repo, branch: "parent") == 1)
        let pStat = try #require(await env.svc.list().first { $0.id == parentCard.id }?.treeStat)
        #expect(pStat.mergedChildren == 1)
        #expect(pStat.drained == false)   // `sibling` still points at parent
    }

    // Dual-observer / restart re-detection at the service level: re-shipping the same child never
    // double-counts (its lineage entry is gone the second time).
    @Test("shipping the same child twice counts once (entry-existence idempotency)")
    func shippedCountsOnce() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)

        try await env.svc.shipped(ref: child.ref())
        try await env.svc.shipped(ref: child.ref())   // second observer / re-run — link already gone

        #expect(await BranchLineage(proc: fake).mergedCount(repo: repo, branch: "parent") == 1)
    }

    // Provenance guard (the sharpest plan-review catch): removing the LAST child by a NON-merge path
    // (abandoned-branch cleanup / re-parent) must NOT drain the parent, even though childCount hits 0 with
    // merged>0 — the condition a naive level-derivation would drain on.
    @Test("a non-merge removal of the last child never drains the parent (provenance, not level-derived)")
    func nonMergeRemovalNeverDrains() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentTip))
        try await lin.set(repo: repo, branch: "extra", link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)
        try await env.svc.shipped(ref: child.ref())   // merges `child`: mergedCount 1, `extra` remains → not drained
        #expect(await env.svc.list().first { $0.id == parentCard.id }?.treeStat?.drained == false)

        // Remove the LAST live child by a NON-merge path, then recompute: childCount is now 0 ∧ merged==1,
        // yet a plain recompute preserves drained==false — only a merge-removal that empties ever sets it.
        try await lin.clear(repo: repo, branch: "extra")
        await env.svc.recomputeChildProgress(parentCard.id)
        let pStat = try #require(await env.svc.list().first { $0.id == parentCard.id }?.treeStat)
        #expect(pStat.drained == false)
        #expect(pStat.mergedChildren == 1)
    }

    // carryChildProgress at a direct treeStat writer: a card that is BOTH a child (re-pointed by set-parent)
    // AND a parent (has its own child-progress) must keep its wave counters across the re-point.
    @Test("carryChildProgress: a set-parent re-point preserves the card's own child-progress")
    func setParentPreservesChildProgress() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let lin = BranchLineage(proc: fake)
        // `child` has merged 2 of a planned 3 of its OWN children.
        try await lin.setPlanned(repo: repo, branch: "child", n: 3)
        for gc in ["gc1", "gc2"] {
            try await lin.set(repo: repo, branch: gc, link: ParentLink(parent: "child", base: parentTip))
            _ = await lin.recordMergedChild(repo: repo, child: gc, expectedParent: "child")
        }
        await env.svc.recomputeChildProgress(card.id)
        #expect(await env.svc.list().first { $0.id == card.id }?.treeStat?.mergedChildren == 2)

        // Re-point `child` onto `parent` — the direct TreeStat write carries the child dimension forward.
        try await env.svc.setParent(ref: card.ref(), parent: "parent")
        let s = try #require(await env.svc.list().first { $0.id == card.id }?.treeStat)
        #expect(s.mergedChildren == 2)
        #expect(s.plannedChildren == 3)
    }

    // A new child lineage entry under a drained parent clears `drained` (the wave is live again), while
    // the merged count is preserved across the clear.
    @Test("adding a child link under a drained parent clears drained; merged count preserved")
    func newChildClearsDrained() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)
        try await env.svc.shipped(ref: child.ref())
        #expect(await env.svc.list().first { $0.id == parentCard.id }?.treeStat?.drained == true)

        // Re-parent the (still-live) child card back onto `parent`: a fresh lineage child appears.
        try await env.svc.setParent(ref: child.ref(), parent: "parent")
        let pStat = try #require(await env.svc.list().first { $0.id == parentCard.id }?.treeStat)
        #expect(pStat.drained == false)
        #expect(pStat.mergedChildren == 1)   // carried across the drained-clear
    }

    // S2-5 (minimal): archiving a worktree card must nudge its live children — the parent branch is now
    // bare, and a stopped child would otherwise wait on a rotted inbox forever.
    @Test("archiving a parent card nudges its live children (parent branch now bare)")
    func archiveNudgesLiveChildren() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        // Intent-only archive: the child nudge is a TeardownStepper actor-duty (PR4b Task 4) — drive it.
        try await TestEnv.archiveAndTeardown(env.svc, parentCard.id)

        let msgs = try await env.svc.inboxPeek(child.id)
        #expect(msgs.contains { $0.text.contains("archived") })
    }

    // slice 4: set-planned broadcasts plannedChildren on a worktree card and rejects a branchless one.
    @Test("set-planned sets plannedChildren on a worktree card; 0 clears; a branchless card is rejected")
    func setPlannedSemantics() async throws {
        let (env, _, _, repo, _) = setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        _ = try await env.svc.setPlanned(ref: card.ref(), n: 5)
        #expect(await env.svc.list().first { $0.id == card.id }?.treeStat?.plannedChildren == 5)
        _ = try await env.svc.setPlanned(ref: card.ref(), n: 0)   // clears
        #expect((await env.svc.list().first { $0.id == card.id }?.treeStat?.plannedChildren ?? 0) == 0)

        // A branchless (freeform cwd) card has no branch to store the count on → rejected.
        let freeform = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", cwd: repo, access: .readWrite))
        await #expect(throws: OrchestraError.self) { try await env.svc.setPlanned(ref: freeform.ref(), n: 3) }
    }

    // S3-5: an archived card must not get a post-archive treeStat rewrite even if a recompute fires.
    @Test("recompute on an archived card is a no-op")
    func archivedCardNoRecompute() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        try await env.svc.archive(card.id)
        await env.svc.recomputeTreeStat(card.id)
        #expect(await env.svc.list(includeArchived: true).first { $0.id == card.id }?.treeStat == nil)
    }

    // S1-3: the shipped child (a stopped card waiting on its live parent) must be TOLD its merge
    // landed — else it's a zombie card forever. And the parent that performed the merge must not get
    // a wasted self-echo.
    @Test("live-parent ship notifies+wakes the child; parent self-echo skipped when caller is the parent")
    func shippedNotifiesChild() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        RepoScripts.advanceParent(graph, 1)   // simulate the parent's squash-merge (S2-2 gate)

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
        // main → A → B; A is a ROOT (no parent link), ships to main.
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoGraph()
        graph.commit(on: "main")                          // base
        graph.branch("A", at: "main"); graph.commit(on: "A")   // A work
        let aTip = graph.tip("A")!
        graph.branch("B", at: "A")
        graph.install(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)

        let a = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "A", repo: repo, branch: "A"))   // no link
        let b = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "B", repo: repo, branch: "B"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "B", link: ParentLink(parent: "A", base: aTip))

        try await env.svc.shipped(ref: a.ref())

        // B retargeted onto the default branch (main), recorded base KEPT, restackNeeded + nudged.
        let lB = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "B"))
        #expect(lB.parent == "main")
        #expect(lB.base == aTip)
        #expect(await env.svc.list().first { $0.id == b.id }?.treeStat?.state == .restackNeeded)
        let nB = try await env.svc.inboxPeek(b.id)
        #expect(nB.first?.text.contains("rebase --onto refs/heads/main \(aTip)") == true)
    }

    // (b) two children retargeted to grandparent, base preserved, restackNeeded, nudged; idempotent
    @Test("shipping a mid branch retargets its two children onto the grandparent (base kept), once")
    func retargetsGrandchildren() async throws {
        // Tree: main → grandparent → mid → {c1, c2}. Ship `mid`.
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoGraph()
        graph.commit(on: "main")                          // base
        graph.branch("grandparent", at: "main")
        graph.branch("mid", at: "grandparent"); graph.commit(on: "mid")   // mid work
        let midTip = graph.tip("mid")!
        graph.branch("c1", at: "mid")
        graph.branch("c2", at: "mid")
        let grandparentTip = graph.tip("grandparent")!
        graph.install(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)

        let mid = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "mid", repo: repo, branch: "mid"))
        let c1 = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c1", repo: repo, branch: "c1"))
        let c2 = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c2", repo: repo, branch: "c2"))
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: repo, branch: "mid",
                          link: ParentLink(parent: "grandparent", base: grandparentTip))
        try await lin.set(repo: repo, branch: "c1", link: ParentLink(parent: "mid", base: midTip))
        try await lin.set(repo: repo, branch: "c2", link: ParentLink(parent: "mid", base: midTip))
        // Simulate mid's squash-merge into grandparent so grandparent advances past mid's base (S2-2 gate).
        graph.commit(on: "grandparent")

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
