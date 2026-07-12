import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

/// O2 backoff + give-up cap. The re-nudge loop used to re-prod the parent every 300s FOREVER; it now
/// backs off geometrically and gives up after `mergeRequestNudgeCap` unanswered reminders, flipping the
/// child to the terminal `mergeStalled` badge so a human can see the stuck merge-request.
/// Design: `notes/designs/2026-07-11-merge-request-nudge-backoff.md`.
@Suite("merge-request re-nudge — model")
struct MergeRequestBackoffModelTests {

    @Test("a TreeStat persisted before this change decodes with nudges == 0")
    func legacyTreeStatDecodesWithZeroNudges() throws {
        let legacy = #"{"state":"mergeRequested","behind":0,"parentIsRemote":false}"#
        let ts = try JSONDecoder().decode(TreeStat.self, from: Data(legacy.utf8))
        #expect(ts.state == .mergeRequested)
        #expect(ts.nudges == 0)
    }

    @Test("nudges round-trips through Codable")
    func nudgesRoundTrips() throws {
        let ts = TreeStat(state: .mergeStalled, nudges: 8)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.nudges == 8)
    }

    @Test("isMergePending covers both waiting and stalled, and nothing else")
    func isMergePendingCoversBoth() {
        #expect(TreeState.mergeRequested.isMergePending)
        #expect(TreeState.mergeStalled.isMergePending)
        #expect(!TreeState.inSync.isMergePending)
        #expect(!TreeState.stale.isMergePending)
        #expect(!TreeState.restackNeeded.isMergePending)
    }
}

@Suite("merge-request re-nudge — backoff schedule")
struct NudgeDelayTests {
    private let base = Duration.seconds(300)

    @Test("the delay doubles from the base until it hits the 12x ceiling")
    func doublesThenCeilings() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 0) == .seconds(300))   // 1x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 1) == .seconds(600))   // 2x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 2) == .seconds(1200))  // 4x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 3) == .seconds(2400))  // 8x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 4) == .seconds(3600))  // 12x ceiling
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 5) == .seconds(3600))  // held
    }

    @Test("the ceiling is relative to the base, so an injected fast base stays fast")
    func ceilingIsBaseRelative() {
        let fast = Duration.milliseconds(20)
        #expect(OrchestraService.nudgeDelay(base: fast, attempt: 9) == .milliseconds(240))  // 12 x 20ms
    }

    @Test("a corrupt or absurd persisted count neither traps nor sleeps forever")
    func absurdAttemptIsClamped() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: Int.max) == .seconds(3600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: -5) == .seconds(300))
    }
}

/// The loop itself: it backs off, it counts, and it GIVES UP — instead of re-prodding the parent every
/// 300s until the heat death of the universe. A parent that ignored 8 reminders will not act on the 9th.
@Suite("merge-request re-nudge — give-up cap")
struct MergeRequestCapTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    /// Poll until `check` holds — the loop ticks on its own schedule, so there is nothing to await on.
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("after the cap the loop gives up: the child goes mergeStalled, the timer stops, a warning fires")
    func capFiresAndStalls() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        // Subscribe BEFORE arming: activity items are ephemeral events, not stored state, so a collector
        // started after the flip would miss the warning entirely.
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(3)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(try await eventually { await treeStat(env.svc, child.id)?.state == .mergeStalled })

        // Exactly 1 original request + exactly 3 reminders. The cap is a hard stop, not a slower drip.
        let msgs = try await env.svc.inboxPeek(parentCard.id).map(\.text)
        #expect(msgs.filter { $0.contains("reminder") }.count == 3)
        #expect(msgs.filter { $0.hasPrefix("merge-request:") }.count == 1)
        #expect(await treeStat(env.svc, child.id)?.nudges == 3)

        #expect(try await eventually { await env.svc.mergeRequestNudgeActive(child.id) == false })
        try await _Concurrency.Task.sleep(for: .milliseconds(60))   // let the ephemeral event land
        let warns = await collector.activities.filter {
            $0.kind == .warning && $0.text.contains("merge-request stalled")
        }
        #expect(warns.count == 1)   // fires ONCE, on the flip

        // Terminal: it stays stalled, and stays silent.
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(await treeStat(env.svc, child.id)?.state == .mergeStalled)
        let after = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }.count
        #expect(after == 3)
    }

    @Test("the backoff resumes across a daemon restart — the count comes from the store, not the Task")
    func backoffResumesAcrossRestart() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)          // the daemon dies mid-budget

        // 2 of the 3 reminders were already sent before the crash — persisted on the card.
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 2 }

        let svcB = TestEnv.remake(base: env.base)              // restart over the SAME on-disk store
        await svcB.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await svcB.svc.setMergeRequestNudgeCap(3)
        await svcB.svc.rebuildMergeRequestNudges()

        #expect(try await eventually { await treeStat(svcB.svc, child.id)?.state == .mergeStalled })
        // The restart did NOT reset the budget: exactly ONE more reminder was owed, not three.
        let reminders = try await svcB.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }
        #expect(reminders.count == 1)
        #expect(await treeStat(svcB.svc, child.id)?.nudges == 3)
    }

    @Test("a fresh merge-request on a stalled child resets the budget and re-arms the loop")
    func reSendResetsTheBudget() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(2)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(try await eventually { await treeStat(env.svc, child.id)?.state == .mergeStalled })

        // The human re-sends. A stalled child is NOT deduped (`alreadyPending` tests `.mergeRequested`), so
        // the request is re-enqueued, the parent re-woken, and the whole budget re-armed from zero.
        await env.svc.setMergeRequestNudgeCap(99)   // keep it pending so the reset is observable
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(await treeStat(env.svc, child.id)?.state == .mergeRequested)
        #expect(await treeStat(env.svc, child.id)?.nudges == 0)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)
        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.hasPrefix("merge-request:") }
        #expect(requests.count == 2)   // the original + the re-send
    }
}

/// The give-up badge is only useful if it STAYS. The tree-stat funnel recomputes `treeStat` on every
/// parent movement, so `mergeStalled` must be sticky against it exactly as `mergeRequested` is — and must
/// be cleared by the same verbs, or the card would wear a red badge forever after the merge finally lands.
@Suite("merge-request re-nudge — mergeStalled is sticky and clearable")
struct MergeStalledStickinessTests {

    private func treeState(_ svc: OrchestraService, _ id: UUID) async -> TreeState? {
        await svc.list().first { $0.id == id }?.treeStat?.state
    }

    /// A child whose merge-request was given up on. Forced straight to the terminal state — the loop's own
    /// path there is Task 3's business (it needs the parent branch's rewrite); this suite is about what the
    /// REST of the system does to the badge once it exists.
    private func stalledChild(_ svc: OrchestraService, _ repo: String, _ parentTip: String) async throws -> Task {
        let child = try await TestEnv.spawnAndAwaitLive(
            svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await svc.mergeRequest(ref: child.ref())
        await svc.stopMergeRequestNudge(child.id)
        _ = try await svc.store.update(child.id) {
            $0.treeStat = TreeStat(state: .mergeStalled, nudges: 8)
        }
        return child
    }

    @Test("a tree-stat recompute does not clobber the stalled badge")
    func recomputeKeepsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        await env.svc.recomputeTreeStat(child.id)
        #expect(await treeState(env.svc, child.id) == .mergeStalled)
    }

    @Test("synced clears the stalled badge (the merge finally happened)")
    func syncedClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        _ = try await env.svc.synced(ref: child.ref())
        #expect(await treeState(env.svc, child.id) != .mergeStalled)
    }
}
