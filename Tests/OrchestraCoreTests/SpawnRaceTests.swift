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
            // Start the spawn, then drive the liveness reconcile a few times while it is parked at
            // `await resolveTrust` — the window between `store.create` and `sessions.ensure` the guard
            // must cover. Bounded pokes (not a free-running spin loop) so sibling suites running in
            // parallel aren't starved of the shared cooperative thread pool.
            async let spawned = env.svc.spawn(SpawnInput(prompt: "c\(i)", repo: repo, branch: "b\(i)"))
            for _ in 0..<4 { await env.svc.reconcileLiveness() }
            let t = try await spawned
            ids.append(t.id)
        }

        let all = await env.svc.list(includeArchived: true)
        let dead = ids.filter { id in all.first { $0.id == id }?.status == .dead }
        #expect(dead.isEmpty, "\(dead.count)/\(ids.count) freshly-spawned cards were falsely marked dead")
    }

    @Test("restart: a stale SessionEnd from the killed old process does not re-kill the fresh session")
    func restartIgnoresStaleSessionEnd() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))

        // User clicks "start fresh": the old (still-running) process is killed and a new session ensured.
        let restarted = try await env.svc.restart(t.id, source: .app)
        #expect(restarted.status == .waiting)

        // The killed old process's SessionEnd hook arrives out-of-band right after restart returns.
        try await env.svc.report(t.id, StatusReport(endReason: "exit"))

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status != .dead, "stale SessionEnd re-killed the restarted card")
        #expect(after.deadReason == nil)
    }
}
