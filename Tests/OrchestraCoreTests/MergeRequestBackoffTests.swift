import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

// O2 backoff + give-up cap: the re-nudge loop used to re-prod the parent every 300s forever. It now backs
// off geometrically and, after `mergeRequestNudgeCap` unanswered reminders, gives up — flagging the child
// `mergeStalled` so a human can see it. Design: notes/designs/2026-07-11-merge-request-nudge-backoff.md.

/// Pure — no git, no cards.
@Suite("merge-request re-nudge — model + schedule")
struct MergeRequestBackoffModelTests {

    @Test("TreeStat decodes leniently: pre-change JSON, and an unknown future state, both survive")
    func decodeIsLenient() throws {
        // A card persisted before `nudges`/`mergeStalled` existed must still load.
        let legacy = #"{"state":"mergeRequested","behind":0,"parentIsRemote":false}"#
        let old = try JSONDecoder().decode(TreeStat.self, from: Data(legacy.utf8))
        #expect(old.state == .mergeRequested && old.nudges == 0 && !old.mergeStalled)

        // An unknown rawValue must cost the badge, never the record: `Task` decodes `treeStat` with
        // `decodeIfPresent` (which rethrows) and `TaskStore.FailableTask` DROPS a throwing record — so a
        // throw here silently deletes the whole card (worktree orphaned, no backup). This is why giving up
        // is a Bool flag and not a `TreeState` case.
        let future = #"{"state":"someFutureState","behind":3,"parentIsRemote":false}"#
        let new = try JSONDecoder().decode(TreeStat.self, from: Data(future.utf8))
        #expect(new.state == .inSync && new.behind == 3)
    }

    @Test("mergeStalled round-trips as a flag riding alongside a live tracking state")
    func flagRidesAlongsideState() throws {
        let ts = TreeStat(state: .stale, behind: 30, nudges: 8, mergeStalled: true)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.mergeStalled && back.state == .stale && back.behind == 30)
    }

    @Test("the delay doubles from the base, ceilings at 12x, and never traps")
    func backoffSchedule() {
        let base = Duration.seconds(300)
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 0) == .seconds(300))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 1) == .seconds(600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 3) == .seconds(2400))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 4) == .seconds(3600))   // ceiling
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 5) == .seconds(3600))
        // Base-relative, so an injected fast base stays fast.
        #expect(OrchestraService.nudgeDelay(base: .milliseconds(20), attempt: 9) == .milliseconds(240))
        // A corrupt persisted count must not overflow the shift.
        #expect(OrchestraService.nudgeDelay(base: base, attempt: .max) == .seconds(3600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: -5) == .seconds(300))
    }
}

/// The loop. These cut a real git repo + cards, so each one earns its keep: one test per guarantee.
@Suite("merge-request re-nudge — give up, and don't be defeatable")
struct MergeRequestCapTests {

    private func stat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A parent card + a child card whose branch is parented to it.
    private func pair(_ env: (svc: OrchestraService, base: String),
                      _ repo: String, _ parentTip: String) async throws -> (parent: Task, child: Task) {
        let p = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let c = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        return (p, c)
    }

    @Test("the cap fires: N reminders, then it gives up, tells both parties, and goes quiet")
    func capFiresAndStalls() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parent, child) = try await pair((env.svc, env.base), repo, tip)
        let collector = EventCollector()          // activity items are ephemeral — subscribe before arming
        await collector.start(await env.svc.subscribe())

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(3)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(try await eventually { await stat(env.svc, child.id)?.mergeStalled == true })

        let msgs = try await env.svc.inboxPeek(parent.id).map(\.text)
        #expect(msgs.filter { $0.contains("reminder") }.count == 3)         // a hard stop, not a slow drip
        #expect(msgs.filter { $0.hasPrefix("merge-request:") }.count == 1)
        #expect(await stat(env.svc, child.id)?.nudges == 3)
        #expect(try await eventually { await env.svc.mergeRequestNudgeActive(child.id) == false })

        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        let warns = await collector.activities.filter {
            $0.kind == .warning && $0.text.contains("merge-request stalled")
        }
        #expect(warns.count == 1)                                            // fires once, on the flip
        // The blocked CHILD is told durably — it can borrow the parent and merge itself.
        #expect(try await env.svc.inboxPeek(child.id).contains { $0.text.contains("merge-request stalled") })

        // Terminal: stays stalled, stays silent.
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(await stat(env.svc, child.id)?.mergeStalled == true)
        #expect(try await env.svc.inboxPeek(parent.id).filter { $0.text.contains("reminder") }.count == 3)
    }

    /// The count is persisted, not held in the Task — `rebuildMergeRequestNudges()` re-arms every pending
    /// card at boot, so an in-memory counter would reset each restart and the cap would never fire. Also:
    /// a restart must not resurrect a loop we already gave up on.
    @Test("the backoff resumes across a restart, and a stalled card is never re-armed")
    func backoffSurvivesRestart() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parent, child) = try await pair((env.svc, env.base), repo, tip)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)                      // the daemon dies mid-budget
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 2 }   // 2 of 3 already sent

        let b = TestEnv.remake(base: env.base)                             // restart over the same store
        await b.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await b.svc.setMergeRequestNudgeCap(3)
        await b.svc.rebuildMergeRequestNudges()

        #expect(try await eventually { await stat(b.svc, child.id)?.mergeStalled == true })
        // Exactly ONE more reminder was owed — the restart did not hand it a fresh budget.
        #expect(try await b.svc.inboxPeek(parent.id).filter { $0.text.contains("reminder") }.count == 1)
        #expect(await stat(b.svc, child.id)?.nudges == 3)

        // Now stalled: a further restart must not re-arm it (that would resurrect the spam).
        let c = TestEnv.remake(base: env.base)
        await c.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await c.svc.rebuildMergeRequestNudges()
        #expect(await c.svc.mergeRequestNudgeActive(child.id) == false)
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        #expect(try await c.svc.inboxPeek(parent.id).filter { $0.text.contains("reminder") }.count == 1)
    }

    /// Re-send semantics, both directions. A re-send while ALREADY pending must not reset the budget (else
    /// any periodic re-sender re-arms it forever and the cap never fires — the case it exists for); a
    /// re-send on a STALLED child is the escape hatch and must reset it.
    @Test("a re-send preserves a running budget, but re-arms a stalled one")
    func reSendSemantics() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parent, child) = try await pair((env.svc, env.base), repo, tip)

        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)                    // freeze the loop; drive by hand
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 7 }

        _ = try await env.svc.mergeRequest(ref: child.ref())             // re-send while still pending
        await env.svc.stopMergeRequestNudge(child.id)
        #expect(await stat(env.svc, child.id)?.nudges == 7)              // budget preserved, not re-armed
        #expect(try await env.svc.inboxPeek(parent.id)
            .filter { $0.text.hasPrefix("merge-request:") }.count == 1)  // dedup held: no second request

        // Now stall it, and re-send: the escape hatch clears the flag, resets the budget, re-arms the loop,
        // and re-prods the parent at t=0.
        await env.svc.setMergeRequestNudgeInterval(.seconds(300))        // no tick can race the assertions
        _ = try await env.svc.store.update(child.id) {
            $0.treeStat?.mergeStalled = true; $0.treeStat?.state = .inSync
        }
        _ = try await env.svc.mergeRequest(ref: child.ref())

        let ts = await stat(env.svc, child.id)
        #expect(ts?.mergeStalled == false && ts?.state == .mergeRequested && ts?.nudges == 0)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)
        #expect(try await env.svc.inboxPeek(parent.id)
            .filter { $0.text.hasPrefix("merge-request:") }.count == 2)
    }

    /// The generation fence (mirrors `remoteWatchGen`). `cancel()` is cooperative and the tick has no
    /// cancellation checks, so a superseded loop runs its tick to completion: its cleanup must not evict the
    /// loop that replaced it, and its ghost tick must not nudge.
    @Test("a superseded loop can neither evict the live loop nor send a ghost reminder")
    func generationFence() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parent, child) = try await pair((env.svc, env.base), repo, tip)

        _ = try await env.svc.mergeRequest(ref: child.ref())
        let genA = await env.svc.mergeRequestNudgeGeneration(child.id)
        await env.svc.startMergeRequestNudge(childId: child.id)          // re-arm: A cancelled, B installed
        #expect(await env.svc.mergeRequestNudgeGeneration(child.id) != genA)

        // A's terminal cleanup lands late — it must no-op, not evict B (which would orphan a live,
        // uncancellable loop that `stop` can no longer reach).
        await env.svc.clearMergeRequestNudge(child.id, gen: genA)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)

        // And A's in-flight tick must send nothing.
        await env.svc.stopMergeRequestNudge(child.id)
        let before = try await env.svc.inboxPeek(parent.id).count
        #expect(await env.svc.reNudgeMergeRequest(child.id, gen: genA))   // stops
        #expect(try await env.svc.inboxPeek(parent.id).count == before)   // no ghost reminder
        #expect(await stat(env.svc, child.id)?.nudges == 0)               // no ghost count bump
    }

    /// The CAS behind the fence. A tick suspends across `inbox.enqueue` + `wake`; if the request is resolved
    /// and freshly re-armed in that window, the new request is ALSO `.mergeRequested` — so a state-only
    /// guard would accept the stale write and could flip a brand-new request straight to stalled.
    @Test("a write computed against a stale count is dropped; a matching one lands")
    func casRejectsStaleWrites() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await pair((env.svc, env.base), repo, tip)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 3 }

        #expect(await env.svc.casNudgeCount(child.id, prior: 7, sent: 8) == false)   // ghost: prior != 3
        #expect(await stat(env.svc, child.id)?.nudges == 3)
        #expect(await stat(env.svc, child.id)?.mergeStalled == false)

        #expect(await env.svc.casNudgeCount(child.id, prior: 3, sent: 4))            // legitimate: lands
        #expect(await stat(env.svc, child.id)?.nudges == 4)
    }

    /// The same hazard on the give-up write, which is also reachable from the already-exhausted path (a cap
    /// lowered under us, or cap <= 0) — that path skips the reminder and must not stamp a fresh request.
    @Test("a stale tick on an exhausted budget cannot stamp a freshly re-armed request")
    func exhaustedPathCannotStampAFreshRequest() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await pair((env.svc, env.base), repo, tip)

        await env.svc.setMergeRequestNudgeCap(2)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 5 }   // budget already blown
        let genOld = await env.svc.mergeRequestNudgeGeneration(child.id)

        _ = try await env.svc.synced(ref: child.ref())          // resolved...
        _ = try await env.svc.mergeRequest(ref: child.ref())    // ...then a NEW request (fresh budget)
        await env.svc.stopMergeRequestNudge(child.id)

        _ = await env.svc.reNudgeMergeRequest(child.id, gen: genOld)   // the exhausted tick lands late

        let ts = await stat(env.svc, child.id)
        #expect(ts?.mergeStalled == false)          // not dead on arrival
        #expect(ts?.state == .mergeRequested && ts?.nudges == 0)
    }
}

/// The flag is orthogonal to the state: a stalled card KEEPS TRACKING its parent. As an overloaded
/// `TreeState` it froze the recompute funnel, so a stalled child went blind — no ↓N, and no "parent moved
/// ahead, merge it down" nudge — and met the drift as conflicts at merge time.
@Suite("merge-request re-nudge — stalled, but still tracking")
struct MergeStalledTrackingTests {

    private func stat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func stalledChild(_ env: (svc: OrchestraService, base: String),
                              _ repo: String, _ tip: String) async throws -> Task {
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: tip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) {
            $0.treeStat = TreeStat(state: .inSync, nudges: 8, mergeStalled: true)
        }
        return child
    }

    /// The parent moving BEFORE the give-up is the LIKELY ordering over a 5h run — and the hard case: the
    /// funnel is frozen while the request is pending, and the give-up writes the true `.stale` state
    /// directly, crossing no inSync→stale edge, so nothing else would ever send the merge-down nudge.
    /// `giveUp` fires it. Then the funnel must keep tracking afterwards.
    @Test("a parent that moved before the give-up still gets a merge-down nudge, and tracking continues")
    func stalledCardTracksItsParent() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: RealProc()).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: tip))

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(1)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        try TreeStatTests.advanceParent(repo, 2)          // parent moves WHILE pending — funnel is frozen

        #expect(try await eventually { await stat(env.svc, child.id)?.mergeStalled == true })

        let ts = await stat(env.svc, child.id)
        #expect(ts?.state == .stale)                      // the TRUE state, written with the flag...
        #expect((ts?.behind ?? 0) >= 1)                   // ...not an .inSync placeholder
        let msgs = try await env.svc.inboxPeek(child.id).map(\.text)
        #expect(msgs.contains { $0.contains("merge-request stalled") })
        #expect(msgs.contains { $0.contains("moved ahead") })   // the nudge the frozen funnel couldn't send

        // And the funnel keeps tracking underneath the flag, rather than freezing on it.
        try TreeStatTests.advanceParent(repo, 1)
        await env.svc.recomputeTreeStat(child.id)
        let after = await stat(env.svc, child.id)
        #expect(after?.mergeStalled == true)              // flag survives the recompute...
        #expect(after?.nudges == 1)                       // ...as does the count
        #expect((after?.behind ?? 0) >= 2)                // ...and ↓N is live, not frozen
    }

    /// `synced` is the only clear path with a CONDITIONAL clear (shipped / set-parent nil `treeStat`
    /// outright), so it is the one that can regress back to testing `state` alone.
    @Test("synced clears the stalled flag — the merge finally happened")
    func syncedClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, tip) = try ShipChoreoTests.repoWithChild(env.base)
        let child = try await stalledChild((env.svc, env.base), repo, tip)

        _ = try await env.svc.synced(ref: child.ref())
        #expect(await stat(env.svc, child.id)?.mergeStalled != true)
    }
}
