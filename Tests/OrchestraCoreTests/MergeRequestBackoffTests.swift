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
