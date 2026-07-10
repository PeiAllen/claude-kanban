import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

/// A stepper whose `step` ALWAYS throws — drives the backoff test. Counts its invocations thread-safely
/// (the reconciler dispatches it off-actor).
final class CountingThrowStepper: PhaseStepper, @unchecked Sendable {
    static var drives: Phase.Kind { .creatingWorktree }
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        lock.withLock { _count += 1 }
        throw OrchestraError.io("boom")
    }
    func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool { false }
}

@Suite("OrchestraService — Stage-4 reconciler driving discipline")
struct ReconcilerTests {

    /// Drive `reconcile()` ticks until `cond` holds (steps run off-actor; a tick only DISPATCHES a step).
    static func reconcileUntil(_ svc: OrchestraService, _ cond: @escaping @Sendable () async -> Bool) async throws {
        try await pollUntil { await svc.reconcile(); return await cond() }
    }

    // MARK: - stepping + backoff

    @Test("a stranded transitional card is redriven to .live on the next tick")
    func strandedTransitionalCardRedriven() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .live
        await env.svc.seedPhase(t.id, .creatingWorktree)                                     // strand it
        #expect(await env.svc.list().first { $0.id == t.id }?.phase.kind == .creatingWorktree)

        try await Self.reconcileUntil(env.svc) {
            await env.svc.list().first { $0.id == t.id }?.phase.kind == .live
        }
        #expect(await env.svc.list().first { $0.id == t.id }?.phase.kind == .live)
    }

    @Test("a failing step emits an activity and backs off (no hot loop within the backoff window)")
    func stepFailureBacksOff() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let stepper = CountingThrowStepper()
        await env.svc.setStepper(stepper, for: .creatingWorktree)
        await env.svc.seedPhase(t.id, .creatingWorktree)

        await env.svc.reconcile()                                    // dispatch the throwing step
        try await pollUntil { stepper.count >= 1 }
        let afterFirst = stepper.count

        // Immediate re-ticks land inside the (≥2s) backoff window → the step must NOT re-run (no hot loop).
        for _ in 0..<6 { await env.svc.reconcile() }
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(stepper.count == afterFirst)

        // The failure surfaced an activity.
        try await pollUntil {
            await collector.activities.contains { $0.kind == .warning && $0.text.contains("step") }
        }
    }

    // MARK: - launch timeout (carry #2)

    @Test("a .launching card older than sessionLaunchTimeout is classified dead(.spawnFailed) from its persisted timestamp")
    func launchTimeoutSurvivesCrash() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Back-date `phaseChangedAt` well past the timeout and persist at `.launching`.
        await env.svc.seedPhase(t.id, .launching, phaseChangedAt: Date().addingTimeInterval(-120))

        // Fresh process (persisted timestamp survives; its tmux session is gone → no adoption).
        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.reconcile()

        let after = try #require(await env2.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .spawnFailed)
        #expect(after.deadDetail?.contains("timed out") == true)
    }

    @Test("a .launching card whose readiness signal was lost still reaches .live via the N=3 liveness fallback")
    func launchingMissedHookConvergesViaLiveness() async throws {
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)   // long grace so the N=3 tick fires first
        let repo = TestEnv.repo(env.base)

        // The inequality the fallback depends on: threshold × pollInterval < sessionLaunchTimeout.
        let thr = await env.svc.launchReadyTickThreshold
        let interval = await env.svc.reconcilePollInterval
        let timeout = await env.svc.config.sessionLaunchTimeout
        #expect(Double(thr) * interval < Double(timeout))

        // Non-blocking spawn persists `.creatingWorktree`; the reconciler drives it to `.launching`, where it
        // awaits its SessionStart hook. We DON'T deliver the hook — the reconcile tick's N=3 launch-readiness
        // fallback is the only resolver that carries it the rest of the way to `.live`.
        _ = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await Self.reconcileUntil(env.svc) {
            await env.svc.list().first { $0.branch == "b" }?.phase.kind == .live
        }
    }

    // MARK: - orphan-session sweep + fresh probe + epoch-identity adoption

    @Test("orphan session (archived / nonexistent card) is swept; a dead(.completed) card's session is kept")
    func orphanSessionSwept() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // X: an archived card with a lingering alive session → swept.
        let x = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "x"))
        await env.svc.seedPhase(x.id, .archived(teardownComplete: true))
        env.sessions.setAlive(x.id, true)

        // Y: a dead(.completed) card (NOT archived) with an alive session → kept (revival possible).
        let y = try await env.svc.spawn(SpawnInput(prompt: "y", repo: repo, branch: "y"))
        await env.svc.markDead(y.id, reason: .completed, detail: nil, source: .daemon)
        env.sessions.setAlive(y.id, true)

        // Z: a live session with NO card at all → swept.
        let zid = UUID()
        env.sessions.setAlive(zid, true)

        await env.svc.reconcile()

        #expect(env.sessions.killed.contains(env.sessions.sessionName(x.id)))    // archived → swept
        #expect(!env.sessions.killed.contains(env.sessions.sessionName(y.id)))   // dead(.completed) → kept
        #expect(env.sessions.killed.contains(env.sessions.sessionName(zid)))     // orphan (no card) → swept
    }

    @Test("the pre-kill decision consults a FRESH epoch-stamped probe, not the batched snapshot")
    func preKillProbeIsFresh() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let x = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "x"))
        await env.svc.seedPhase(x.id, .archived(teardownComplete: true))
        env.sessions.setAlive(x.id, true)
        let name = env.sessions.sessionName(x.id)

        await env.svc.reconcile()

        #expect(env.sessions.isAliveQueries.contains(name))   // a fresh probe was consulted before the kill
        #expect(env.sessions.killed.contains(name))
    }

    @Test("the pre-kill probe runs OFF the service actor (a concurrent fast RPC returns while it runs)")
    func preKillProbeOffActor() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let x = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "x"))
        await env.svc.seedPhase(x.id, .archived(teardownComplete: true))
        env.sessions.setAlive(x.id, true)
        env.sessions.isAliveSleepMs = 500   // slow probe

        async let sweep: Void = env.svc.reconcile()
        try await _Concurrency.Task.sleep(for: .milliseconds(80))   // let reconcile reach the probe
        let t0 = Date()
        _ = await env.svc.list()                                    // must not block behind the 500ms probe
        let elapsed = Date().timeIntervalSince(t0)
        await sweep

        #expect(elapsed < 0.3)
    }

    @Test("adoption checks epoch identity: matching-epoch session adopted; older-epoch session relaunched, never adopted")
    func adoptionChecksEpochIdentity() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // M: seeded `.launching` with a live session at the MATCHING epoch → adopt to `.live` (no relaunch).
        let m = try await env.svc.spawn(SpawnInput(prompt: "m", repo: repo, branch: "m"))
        await env.svc.seedPhase(m.id, .launching, sessionEpoch: 1)
        env.sessions.setStampedEpoch(m.id, 1)

        // O: seeded `.relaunching` (provisional) whose surviving session is at an OLDER epoch → relaunch.
        let o = try await env.svc.spawn(SpawnInput(prompt: "", repo: repo, branch: "o"))
        await env.svc.seedPhase(o.id, .relaunching, sessionEpoch: 5)
        env.sessions.setStampedEpoch(o.id, 3)   // old-epoch session

        try await Self.reconcileUntil(env.svc) {
            let mp = await env.svc.list().first { $0.id == m.id }?.phase.kind
            let op = await env.svc.list().first { $0.id == o.id }?.phase.kind
            return mp == .live && op == .live
        }

        // M was adopted — its session identity is unchanged (still epoch 1).
        #expect((try env.sessions.stampedEpoch(name: env.sessions.sessionName(m.id))) == 1)
        // O completed the relaunch — its new session carries the CURRENT epoch (5), never the old 3.
        #expect((try env.sessions.stampedEpoch(name: env.sessions.sessionName(o.id))) == 5)
        #expect(env.sessions.killed.contains(env.sessions.sessionName(o.id)))   // old session was killed
    }

    // MARK: - startup phase reconciliation

    @Test("startup reconciles a persisted in-flight phase (no stuck-Creating): re-driven to .live")
    func startupReconcilesInFlightPhases() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)     // resumable
        await env.svc.seedPhase(t.id, .creatingWorktree)        // stranded mid-spawn, persisted

        // Fresh process.
        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.reconcilePhasesAtBoot()
        try await Self.reconcileUntil(env2.svc) {
            await env2.svc.list().first { $0.id == t.id }?.phase.kind == .live
        }
        #expect(await env2.svc.list().first { $0.id == t.id }?.phase.kind == .live)
    }

    // MARK: - durable watch registry (carry #4)

    @Test("an MCP wait watcher survives a daemon restart; a child terminal-at-reload delivers immediately")
    func mcpWatchSurvivesRestart() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        // Both must be genuinely `.live` (a boot pass only adopts/revives `.live`-persisted cards).
        let watcher = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "w", repo: repo, branch: "w"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "c", repo: repo, branch: "c"))
        _ = await env.svc.watch(watcher: watcher.id, refs: [child.id])   // durable MCP watch (no CLI process)
        env.sessions.setAlive(child.id, false)                           // child dies while daemon is down

        // Restart: watcher's session survived (daemon-only crash) → adopt; child's is gone → rebootUnrevived.
        let env2 = TestEnv.remake(base: env.base)
        env2.sessions.setStampedEpoch(watcher.id, 1)
        await env2.svc.reconcilePhasesAtBoot()   // child → dead(.rebootUnrevived) [terminal]
        await env2.svc.reloadWatchRegistry()     // reload persisted registry + deliver terminal-at-reload

        #expect(await env2.svc.list().first { $0.id == watcher.id }?.phase.kind == .live)   // adopted
        let inbox = try await env2.svc.inboxPeek(watcher.id)
        #expect(inbox.contains { $0.text.contains("concluded") })
    }

    // MARK: - corrupt-store recovery + conservative mode (carry #3)

    @Test("a corrupt tasks.json is timestamped-backed-up, boots empty, and enters conservative mode")
    func corruptTasksJsonRecovers() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try "{ this is not valid json".write(toFile: env.base + "/tasks.json", atomically: true, encoding: .utf8)

        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.reconcilePhasesAtBoot()

        #expect(await env2.svc.list(includeArchived: true).isEmpty)                 // booted empty
        #expect(await env2.svc.worktreeConservativeMode())                          // conservative ON
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: env.base))?
            .filter { $0.hasPrefix("tasks.json.corrupt-") } ?? []
        #expect(backups.count == 1)                                                 // timestamped backup
    }

    @Test("conservative mode persists for the daemon's lifetime; cleared only by a later clean restart")
    func conservativeModePersistsForDaemonLifetime() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try "{ corrupt".write(toFile: env.base + "/tasks.json", atomically: true, encoding: .utf8)

        // Corrupt boot → conservative ON.
        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.reconcilePhasesAtBoot()
        #expect(await env2.svc.worktreeConservativeMode())

        // A fresh spawn + archive in the SAME daemon removes NOTHING (conservative not cleared by writes).
        let s = try await env2.svc.spawn(SpawnInput(prompt: "new", repo: repo, branch: "new"))
        let removedBefore = env2.worktrees.removed.count
        try await env2.svc.archive(s.id)
        #expect(env2.worktrees.removed.count == removedBefore)          // reclaim suppressed
        #expect(await env2.svc.worktreeConservativeMode())              // still ON

        // A subsequent CLEAN restart (healthy tasks.json) boots with conservative mode OFF.
        let env3 = TestEnv.remake(base: env.base)
        await env3.svc.reconcilePhasesAtBoot()
        #expect(!(await env3.svc.worktreeConservativeMode()))
    }
}
