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

    // MARK: - unowned targets: accept and RECORD (slice 3a)
    //
    // `merge-request` is the single declaration a card makes when its work is ready, so it never refuses
    // on the shape of the target. With no owning agent to consume the request the daemon records the same
    // sticky badge and stops: no inbox message (there is no one to send it to), no re-nudge loop, and so
    // no `mergeStalled` escalation either. The human reads the badge and merges however they choose.

    /// The `parent` branch exists in the graph and is linked, but NO card owns it.
    private func unownedChild(_ env: TreeStatTests.Env, _ fake: FakeProc, _ repo: String,
                              _ parentTip: String) async throws -> Task {
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                                link: ParentLink(parent: "parent", base: parentTip))
        return child
    }

    @Test("a BARE local parent records the badge, nudges nobody, and arms no loop")
    func bareLocalParentRecords() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let child = try await unownedChild(env, fake, repo, parentTip)

        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(await treeState(env.svc, child.id) == .mergeRequested)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false)
        // Nothing was enqueued anywhere — not to the child (that would re-invoke an agent told to STOP),
        // and there is no parent card to enqueue to.
        #expect(try await env.svc.inboxPeek(child.id).isEmpty)
    }

    @Test("a card with NO parent link records against the default branch instead of refusing")
    func linklessRootRecords() async throws {
        let (env, _, _, repo) = TreeStatTests.setup()
        let solo = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "solo", repo: repo, branch: "solo"))

        _ = try await env.svc.mergeRequest(ref: solo.ref())

        #expect(await treeState(env.svc, solo.id) == .mergeRequested)
        #expect(await env.svc.mergeRequestNudgeActive(solo.id) == false)
    }

    @Test("an ARCHIVED parent card counts as unowned — the lookup excludes it")
    func archivedParentIsUnowned() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await unownedChild(env, fake, repo, parentTip)
        _ = try await env.svc.store.update(parentCard.id) { $0.archived = true }

        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(await treeState(env.svc, child.id) == .mergeRequested)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false)
        #expect(try await env.svc.inboxPeek(parentCard.id).isEmpty)   // never nudge an archived card
    }

    @Test("an owner disappearing mid-flight keeps the badge and stops the loop (owned → unowned)")
    func ownerLossKeepsTheBadge() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await unownedChild(env, fake, repo, parentTip)
        await env.svc.setMergeRequestNudgeInterval(.milliseconds(30))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)

        _ = try await env.svc.store.update(parentCard.id) { $0.archived = true }

        // The next tick finds no owner: the loop stops, but the DECLARATION stands — it is now the
        // human's to resolve, not something the daemon may retract on the child's behalf.
        try await pollUntil("the nudge loop observed the owner loss and stopped") {
            await env.svc.mergeRequestNudgeActive(child.id) == false
        }
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
    }

    /// The real owner-gain path: the parent card is ARCHIVED when the request is made (so it records
    /// unowned), and comes back — a `reopen`. Spawning a fresh card onto the parent branch cannot be the
    /// scenario: a spawn that CREATES the branch deliberately clears stale children links first
    /// (`+Converge`), so there would be no request left to hand over.
    @Test("an owner APPEARING later takes the request over — exactly once")
    func ownerGainHandsOver() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await unownedChild(env, fake, repo, parentTip)
        _ = try await env.svc.store.update(parentCard.id) { $0.archived = true }

        _ = try await env.svc.mergeRequest(ref: child.ref())          // recorded, unowned
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false)
        #expect(try await env.svc.inboxPeek(parentCard.id).isEmpty)

        // The owner comes back. The funnel recompute is what notices.
        _ = try await env.svc.store.update(parentCard.id) { $0.archived = false }
        await env.svc.recomputeTreeStat(child.id)

        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("merge-request") }
        #expect(requests.count == 1)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)
        #expect(await treeState(env.svc, child.id) == .mergeRequested)

        // Idempotent: a second funnel pass must not re-send to an owner that already holds it.
        await env.svc.recomputeTreeStat(child.id)
        #expect(try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("merge-request") }.count == 1)
    }

    /// The production trigger for the handover above. `reopen` un-archives the owner and `spawn` creates
    /// one, and `derivedCard` counts either the instant it exists — but neither path re-derives the routing
    /// of requests already aimed at that branch. Making the `.live` LANDING schedule the child fan-out is
    /// what turns "an owner appeared" into an explicit edge, instead of leaving the handover to depend on
    /// the new owner happening to file a field-changing report.
    @Test("reopening the owner hands the request over with no other prompting")
    func reopenedOwnerTakesOver() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let parentCard = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await unownedChild(env, fake, repo, parentTip)
        let sid = try #require(parentCard.agentSessionId)
        env.adapter.writeTranscript(for: sid)                    // resumable → reopen resumes it
        try await TestEnv.archiveAndTeardown(env.svc, parentCard.id)

        _ = try await env.svc.mergeRequest(ref: child.ref())     // recorded while nobody owns `parent`
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false)

        // The branch outlives the archived card in production (only its worktree is removed), so `ensure`
        // reports it as pre-existing — which is what stops `materialize` from clearing the "stale" children
        // links of what it would otherwise take for a brand-new branch.
        env.worktrees.markBranchExists("parent")
        _ = try await env.svc.reopen(parentCard.id)
        _ = try await TestEnv.reconcileToLive(env.svc, parentCard.id)

        // Nothing else is driven here — no report, no manual recompute. The landing's own fan-out is what
        // has to carry the request to the owner that just came back. Poll on ARMING, which the reconcile
        // does LAST: polling the inbox instead would let this assertion land in the window between the
        // enqueue and the arm.
        try await pollUntil("the reopened owner took over the pending merge-request") {
            await env.svc.mergeRequestNudgeActive(child.id)
        }
        #expect(try await env.svc.inboxPeek(parentCard.id)
            .filter { $0.text.contains("merge-request") }.count == 1)
    }

    @Test("synced clears an UNOWNED badge, exactly as it clears an owned one")
    func syncedClearsUnownedBadge() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let child = try await unownedChild(env, fake, repo, parentTip)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == .mergeRequested)

        RepoScripts.advanceParent(graph, 1)
        _ = try await env.svc.synced(ref: child.ref())
        #expect(await treeState(env.svc, child.id) != .mergeRequested)
    }

    @Test("shipped clears an UNOWNED badge")
    func shippedClearsUnownedBadge() async throws {
        let (env, fake, graph, repo, parentTip) = setup()
        let child = try await unownedChild(env, fake, repo, parentTip)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        RepoScripts.advanceParent(graph, 1)
        try await env.svc.shipped(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == nil)
    }

    @Test("re-parenting clears an UNOWNED badge")
    func setParentClearsUnownedBadge() async throws {
        let (env, fake, _, repo, parentTip) = setup()
        let child = try await unownedChild(env, fake, repo, parentTip)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        _ = try await env.svc.setParent(ref: child.ref(), parent: nil)
        #expect(await treeState(env.svc, child.id) == nil)
    }
}
