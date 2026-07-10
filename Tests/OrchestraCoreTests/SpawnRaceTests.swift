import Foundation
import Testing
@testable import OrchestraCore

/// Regression tests for the "freshly spawned/restarted agent reads as dead" flake. Two distinct
/// actor-reentrancy races, both rooted in the `recovering` guard not covering the full launch window:
///  1. `spawn` creates the card, then suspends at `await resolveTrust` BEFORE `sessions.ensure` — the
///     background liveness poll can interleave there and mark the session-less card `.dead`.
///  2. `restart` drops `recovering` the instant it returns, so a stale `SessionEnd` from the just-killed
///     old process lands unguarded and re-kills the fresh session as `.agentExited`.
@Suite("OrchestraService — spawn/restart liveness races")
struct SpawnRaceTests {

    @Test("spawn: a concurrent liveness poll never falsely kills an in-flight spawn")
    func spawnNotKilledByConcurrentPoll() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)

        var ids: [UUID] = []
        for i in 0..<40 {
            // Non-blocking spawn persists a `.creatingWorktree` card, then the STEPPING reconciler drives it
            // through the funnel. Interleave `reconcile()` ticks while each card is being born — the
            // being-born phases (creatingWorktree/launching) must never be false-killed by a concurrent tick.
            let t = try await env.svc.spawn(SpawnInput(prompt: "c\(i)", repo: repo, branch: "b\(i)"))
            for _ in 0..<4 { await env.svc.reconcile() }
            ids.append(t.id)
        }
        // Drive all the way to live; still nothing may have been marked dead in the process.
        let expected = ids.count
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().filter { $0.phase.kind == .live }.count == expected
        }

        let all = await env.svc.list(includeArchived: true)
        let dead = ids.filter { id in all.first { $0.id == id }?.phaseDisplay == .dead }
        #expect(dead.isEmpty, "\(dead.count)/\(ids.count) freshly-spawned cards were falsely marked dead")
    }

    // S2-6: co-located siblings on one branch are still permitted (the cwd-keyed archive refcount depends
    // on it), but spawning a second one WARNS on the multiplicity, and every derived parent-card lookup
    // is DETERMINISTIC (the oldest card wins) rather than an arbitrary sibling.
    @Test("S2-6: a co-located sibling spawn warns; derived parent lookup picks the oldest deterministically")
    func spawnWarnsOnMultiplicityDeterministicLookup() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let first = try await env.svc.spawn(SpawnInput(prompt: "a", repo: repo, branch: "parent"))
        let second = try await env.svc.spawn(SpawnInput(prompt: "b", repo: repo, branch: "parent"))  // co-located: allowed
        _ = second
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(await collector.activities.contains { $0.kind == .warning && $0.text.contains("second live card") })

        // A child on `parent`: shipping it (root ship) / notify must resolve to the OLDEST parent card.
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        _ = child
        let active = await env.svc.list()
        #expect(await env.svc.derivedCard(repo: repo, branch: "parent", among: active)?.id == first.id)
    }

    @Test("restart: a stale SessionEnd from the killed old process does not re-kill the fresh session")
    func restartIgnoresStaleSessionEnd() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))

        // User clicks "start fresh": the old (still-running) process is killed and a new session ensured.
        let restarted = try await env.svc.restart(t.id, source: .app)
        #expect(restarted.waitReason != nil)

        // The killed old process's SessionEnd hook arrives out-of-band right after restart returns.
        try await env.svc.report(t.id, StatusReport(endReason: "exit"))

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay != .dead, "stale SessionEnd re-killed the restarted card")
        #expect(after.deadReason == nil)
    }
}
