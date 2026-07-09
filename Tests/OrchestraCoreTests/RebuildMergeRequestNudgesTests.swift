import Foundation
import Testing
@testable import OrchestraCore

/// O2 restart durability: `merge-request` arms an in-memory re-nudge timer that dies on a daemon
/// restart while its durable state (child `mergeRequested` + the parent's inbox request) survives.
/// `rebuildMergeRequestNudges()` re-arms those timers at startup — mirroring `rebuildRemoteWatches`.
@Suite("merge-request re-nudge — startup rebuild")
struct RebuildMergeRequestNudgesTests {

    private func treeState(_ svc: OrchestraService, _ id: UUID) async -> TreeState? {
        await svc.list().first { $0.id == id }?.treeStat?.state
    }

    @Test("restart durability: a rebuilt timer re-prods the parent after the daemon restarts")
    func rebuildReProdsAfterRestart() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == .mergeRequested)
        await env.svc.stopMergeRequestNudge(child.id)   // the daemon dies — the in-memory timer goes with it

        // Restart: a fresh service over the SAME on-disk stores, with a short injected nudge interval.
        let svcB = TestEnv.remake(base: env.base)
        await svcB.svc.setMergeRequestNudgeInterval(.milliseconds(30))
        let before = try await svcB.svc.inboxPeek(parentCard.id).count
        await svcB.svc.rebuildMergeRequestNudges()

        var reProdded = false
        for _ in 0..<100 {
            if try await svcB.svc.inboxPeek(parentCard.id).contains(where: { $0.text.contains("reminder") }) {
                reProdded = true; break
            }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        #expect(reProdded)                                                    // the timer re-armed and ticked
        #expect(try await svcB.svc.inboxPeek(parentCard.id).count > before)   // a new message arrived
    }

    @Test("rebuild skips archived cards and non-mergeRequested states, arms only the live pending one")
    func rebuildSkipsIneligible() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))

        // (a) live, pending — the positive control that MUST be re-armed.
        let live = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: live.ref())
        await env.svc.stopMergeRequestNudge(live.id)   // restart sim: clear the in-memory timer

        // (b) archived but still mergeRequested in the store — must be skipped.
        let archived = try await env.svc.spawn(SpawnInput(prompt: "a", repo: repo, branch: "child-arch"))
        _ = try await env.svc.store.update(archived.id) {
            $0.treeStat = TreeStat(state: .mergeRequested); $0.archived = true
        }
        // (c) live worktree card, but not mergeRequested — must be skipped.
        let plain = try await env.svc.spawn(SpawnInput(prompt: "b", repo: repo, branch: "child-plain"))

        await env.svc.rebuildMergeRequestNudges()

        // Checked immediately, before any tick: the interval keeps the default 300s, so the armed `live`
        // timer is parked in its first sleep — `active` reflects the rebuild filter, not tick side effects.
        #expect(await env.svc.mergeRequestNudgeActive(live.id) == true)
        #expect(await env.svc.mergeRequestNudgeActive(archived.id) == false)
        #expect(await env.svc.mergeRequestNudgeActive(plain.id) == false)
    }

    @Test("a rebuilt timer still stops on shipped (the clear path works post-rebuild)")
    func rebuiltTimerStopsOnShipped() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)   // restart sim

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(30))
        await env.svc.rebuildMergeRequestNudges()
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)

        try TreeStatTests.advanceParent(repo, 1)   // simulate the merge (S2-2 gate)
        try await env.svc.shipped(ref: child.ref())
        #expect(await treeState(env.svc, child.id) == nil)   // cleared

        // The next tick sees the child no longer pending, breaks the loop, and clears the slot.
        var stopped = false
        for _ in 0..<100 {
            if await env.svc.mergeRequestNudgeActive(child.id) == false { stopped = true; break }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        #expect(stopped)
    }
}
