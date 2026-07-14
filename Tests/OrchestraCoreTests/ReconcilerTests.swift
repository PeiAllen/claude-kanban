import Foundation
import Testing
import OrchestraKit
import TestSupport
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
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .live
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

        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        let stepper = CountingThrowStepper()
        await env.svc.setStepper(stepper, for: .creatingWorktree)
        // Pin a large backoff so the "re-ticks stay inside the window" assertion is load-proof: the real
        // first delay is 2s, which a heavily-parallel suite run can outlast between the reconcile() calls.
        await env.svc.setStepBackoff(3600)
        await env.svc.seedPhase(t.id, .creatingWorktree)

        await env.svc.reconcile()                                    // dispatch the throwing step
        try await pollUntil { stepper.count >= 1 }
        let afterFirst = stepper.count

        // Immediate re-ticks land inside the (pinned 3600s) backoff window → the step must NOT re-run (no hot loop).
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
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        // Back-date `phaseChangedAt` well past the timeout and persist at `.launching`. Derived FROM the
        // config, not a hardcoded -120s: the test env deliberately runs a launch timeout it cannot outlive
        // (see `TestEnv.make`), so a fixed back-date would silently stop clearing the deadline and this test
        // would assert a timeout that never armed.
        let timeout = await env.svc.config.sessionLaunchTimeout
        await env.svc.seedPhase(t.id, .launching, phaseChangedAt: Date().addingTimeInterval(-Double(timeout) - 60))

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
        let interval = env.svc.reconcilePollInterval
        let timeout = await env.svc.config.sessionLaunchTimeout
        #expect(Double(thr) * interval < Double(timeout))

        // Non-blocking spawn persists `.creatingWorktree`; the reconciler drives it to `.launching`, where it
        // awaits its SessionStart hook. We DON'T deliver the hook — the reconcile tick's N=3 launch-readiness
        // fallback is the only resolver that carries it the rest of the way to `.live`.
        _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
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
        let x = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "x"))
        await env.svc.seedPhase(x.id, .archived(teardownComplete: true))
        env.sessions.setAlive(x.id, true)

        // Y: a dead(.completed) card (NOT archived) with an alive session → kept (revival possible).
        let y = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "y", repo: repo, branch: "y"))
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
        let x = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "x"))
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
        let x = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "x"))
        await env.svc.seedPhase(x.id, .archived(teardownComplete: true))
        env.sessions.setAlive(x.id, true)
        let gate = SyncGate()
        env.sessions.isAliveGate = gate   // park the probe

        async let sweep: Void = env.svc.reconcile()
        await gate.reached()                                        // the probe is genuinely parked, off-actor
        env.sessions.isAliveGate = nil                              // only the scheduled probe parks
        let t0 = Date()
        _ = await env.svc.list()                                    // must not block behind the parked probe
        let elapsed = Date().timeIntervalSince(t0)
        gate.release()
        await sweep

        #expect(elapsed < 0.3)
    }

    @Test("adoption checks epoch identity: matching-epoch session adopted; older-epoch session relaunched, never adopted")
    func adoptionChecksEpochIdentity() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // M: seeded `.launching` with a live session at the MATCHING epoch → adopt to `.live` (no relaunch).
        let m = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "m", repo: repo, branch: "m"))
        await env.svc.seedPhase(m.id, .launching, sessionEpoch: 1)
        env.sessions.setStampedEpoch(m.id, 1)

        // O: seeded `.relaunching` (provisional) whose surviving session is at an OLDER epoch → relaunch.
        let o = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "o"))
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

    @Test("adopt clears pendingSeed (mirrors the stepper's companion cleanup) so it can't be replayed")
    func adoptClearsPendingSeed() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // Seed a `.launching` card at the MATCHING epoch (→ adopt), carrying a leftover `pendingSeed` the
        // stepper would normally clear on its own `→ live` transition — but a crash BEFORE the stepper ran
        // (session consumed the seed + came up, then daemon died) leaves it set. Adopt must clear it too.
        let c = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        await env.svc.seedPhase(c.id, .launching, sessionEpoch: 1)
        env.sessions.setStampedEpoch(c.id, 1)
        _ = try await env.svc.store.update(c.id) { $0.pendingSeed = "replay-me" }

        try await Self.reconcileUntil(env.svc) {
            (await env.svc.list().first { $0.id == c.id }?.phase.kind) == .live
        }

        // Adopted to `.live` AND the stale seed is gone — a later `resume(seed: nil)` can't replay it.
        let now = try #require(await env.svc.store.get(c.id))
        #expect(now.phase.kind == .live)
        #expect(now.pendingSeed == nil)
    }

    /// BLOCKER regression: the adoption shortcut probes the session epoch OFF-actor (suspending the
    /// service), then adopts to `.live`. If a concurrent restart/resume bumps the card to a NEWER
    /// `.relaunching` epoch during that suspension, the STALE adoption must NOT force-live the card on the
    /// old generation — the newer relaunch wins (single-winner fence). The fix passes the probed epoch as
    /// `observedEpoch`, so the funnel re-reads the current card and no-ops on a bumped generation.
    @Test("adoption is epoch-fenced: a restart bumping the epoch during the off-actor probe wins over stale adoption")
    func adoptionEpochFencedAgainstConcurrentRestart() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // Seed a `.relaunching` card at epoch 1 with a live session stamped at the SAME epoch → the
        // adoption condition (`probed == snapshot.sessionEpoch`) holds at snapshot time.
        let c = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        await env.svc.seedPhase(c.id, .relaunching, sessionEpoch: 1)
        env.sessions.setStampedEpoch(c.id, 1)

        // A handshake: the probe (off-actor) signals it has entered, then blocks; while blocked, the actor
        // is free, so the test drives a concurrent restart that bumps the card to epoch 2; then the probe is
        // released and returns the still-stale-matching epoch 1.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        env.sessions.onStampedEpochProbe = { _ in entered.signal(); release.wait() }

        // Run ONE reconcile tick concurrently — it will suspend inside the off-actor epoch probe.
        let tick = _Concurrency.Task { await env.svc.reconcile() }

        // Wait until the probe is in its actor-released window, then simulate a concurrent restart: bump the
        // persisted generation to a NEWER `.relaunching` epoch (what `restart`/`resume` would do).
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { entered.wait(); cont.resume() }
        }
        await env.svc.seedPhase(c.id, .relaunching, sessionEpoch: 2)
        release.signal()
        await tick.value

        // The stale adoption must have NO-OPed: the card stays on the newer generation (`.relaunching`,
        // epoch 2), NOT force-lived on the old epoch-1 generation.
        let after = try #require(await env.svc.list().first { $0.id == c.id })
        #expect(after.phase.kind == .relaunching)
        #expect(after.sessionEpoch == 2)
        #expect(after.phase.kind != .live)
    }

    // MARK: - startup phase reconciliation

    @Test("startup reconciles a persisted in-flight phase (no stuck-Creating): re-driven to .live")
    func startupReconcilesInFlightPhases() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
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
        let watcher = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "w", repo: repo, branch: "w"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
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

    /// MAJOR regression: `server.start()` accepts RPCs BEFORE boot's `reloadWatchRegistry` runs (after the
    /// slow phase reconciliation). A `wait`/`watch` RPC in that window used to mutate the STILL-EMPTY
    /// in-memory registry and `save`, CLOBBERING the persisted `watch-registry.json` (losing every prior
    /// watch). The lazy-load fix loads-then-unions on first access, so the boot-window write MERGES.
    @Test("a boot-window registerWatch does NOT clobber the persisted registry (lazy-load unions)")
    func bootWindowRegisterWatchDoesNotClobber() async throws {
        let env = TestEnv.make(grace: 1)
        let storePath = env.base + "/watch-registry.json"
        let priorWatcher = UUID(), priorChild = UUID()
        await env.svc.registerWatch(priorWatcher, [priorChild])   // persisted before the "restart"
        #expect(WatchRegistryStore(path: storePath).load().map[priorWatcher]?.contains(priorChild) == true)

        // Fresh service over the SAME registry file — a boot-window register BEFORE `reloadWatchRegistry`.
        let env2 = TestEnv.remake(base: env.base)
        let newWatcher = UUID(), newChild = UUID()
        await env2.svc.registerWatch(newWatcher, [newChild])   // the boot-window RPC (pre-reload)

        // The prior watch survives on disk (unioned), and the new one is added — no clobber.
        let onDisk = WatchRegistryStore(path: storePath).load().map
        #expect(onDisk[priorWatcher]?.contains(priorChild) == true)
        #expect(onDisk[newWatcher]?.contains(newChild) == true)

        // The later reload still sees the prior watch — nothing lost.
        await env2.svc.reloadWatchRegistry()
        #expect(WatchRegistryStore(path: storePath).load().map[priorWatcher]?.contains(priorChild) == true)
    }

    /// Fail-safe posture (mirrors `borrowsLoadFailed`): a present-but-TORN `watch-registry.json` must never
    /// be overwritten by a boot-window mutation — a partial in-memory map replacing an ambiguous-but-maybe-
    /// recoverable file would be data loss. On `loadFailed` the mutation skips the `watchStore.save`.
    @Test("a torn watch-registry.json is never overwritten by a boot-window mutation (loadFailed posture)")
    func tornWatchRegistryNotOverwritten() async throws {
        let env = TestEnv.make(grace: 1)
        let storePath = env.base + "/watch-registry.json"
        let torn = "{ not valid json"
        try torn.write(toFile: storePath, atomically: true, encoding: .utf8)

        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.registerWatch(UUID(), [UUID()])   // must REFUSE to persist over the torn file

        let raw = try String(contentsOfFile: storePath, encoding: .utf8)
        #expect(raw == torn)                                             // torn bytes intact
        #expect(WatchRegistryStore(path: storePath).load().loadFailed)   // still ambiguous, not clobbered
    }

    // MARK: - corrupt-store recovery + conservative mode (carry #3)

    @Test("a corrupt tasks.json is timestamped-backed-up, boots empty, and enters conservative mode")
    func corruptTasksJsonRecovers() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
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
        _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try "{ corrupt".write(toFile: env.base + "/tasks.json", atomically: true, encoding: .utf8)

        // Corrupt boot → conservative ON.
        let env2 = TestEnv.remake(base: env.base)
        await env2.svc.reconcilePhasesAtBoot()
        #expect(await env2.svc.worktreeConservativeMode())

        // A fresh spawn + archive in the SAME daemon removes NOTHING (conservative not cleared by writes).
        let s = try await env2.svc.spawn(SpawnInput(id: UUID(), prompt: "new", repo: repo, branch: "new"))
        let removedBefore = env2.worktrees.removed.count
        try await env2.svc.archive(s.id)
        #expect(env2.worktrees.removed.count == removedBefore)          // reclaim suppressed
        #expect(await env2.svc.worktreeConservativeMode())              // still ON

        // A subsequent CLEAN restart (healthy tasks.json) boots with conservative mode OFF.
        let env3 = TestEnv.remake(base: env.base)
        await env3.svc.reconcilePhasesAtBoot()
        #expect(!(await env3.svc.worktreeConservativeMode()))
    }

    /// BUG (mirror of bug #2): a STALE LIVENESS SNAPSHOT must never kill a FRESHLY-LIVE session.
    ///
    /// `reconcile()` sampled the live-session set (`sessions.list()`, off-actor) BEFORE it read the card
    /// phases (`store.all()`), with two actor suspensions in between. A card that was `.relaunching` (session
    /// not yet created) when the session snapshot was taken, but whose bring-up step completed during those
    /// suspensions, is then read as `.live` and judged against a session set that PREDATES its session. The
    /// `.live` case sees `!alive` and concludes `.sessionVanished` — killing a healthy agent that had just
    /// come up. Bug #2 was "a stale bring-up resurrects a live session"; this is the same stale-snapshot
    /// hazard pointing the other way.
    ///
    /// In production this is the 2s reconcile loop: restart or resume a card, the agent launches fine, and
    /// the card immediately flips to `dead(sessionVanished)`. The window is the whole `agentPaneDeadSessions`
    /// tmux subprocess, so a loaded machine widens it — which is why it surfaced as a "flaky test" under
    /// `--parallel` rather than as the product bug it is.
    ///
    /// The orphan sweep already learned this lesson ("never off a stale snapshot; bug #7") and re-probes
    /// before killing. The `.live` kill path never did.
    @Test("a card that lands .live during the tick's own probes is NOT killed by that tick's stale session snapshot")
    func freshlyLiveCardNotKilledByStaleSnapshot() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        _ = try await env.svc.restart(t.id, source: .app)     // `.relaunching`, no session yet

        let svc = env.svc, sessions = env.sessions, id = t.id
        // Land the card `.live` WITH its session inside the tick's second off-actor probe — i.e. AFTER the
        // session snapshot was taken and BEFORE the phases are read. This is exactly where a real
        // RelaunchStepper lands; the actor is released across that hop, so the step legitimately runs there.
        sessions.onAgentPaneDeadProbe = { @Sendable in
            let sem = DispatchSemaphore(value: 0)
            _Concurrency.Task {
                sessions.setAlive(id, true)                   // the relaunch's `ensure` brought the session up…
                await svc.seedPhase(id, .live(.running))      // …and the step landed the card `.live`
                sem.signal()
            }
            sem.wait()
        }

        await svc.reconcile()

        let after = try #require(await svc.list(includeArchived: true).first { $0.id == id })
        #expect(after.deadReason != .sessionVanished)   // its session EXISTS — the snapshot was just older than it
        #expect(after.phase.kind == .live)              // a healthy, freshly-launched card stays up
    }
}
