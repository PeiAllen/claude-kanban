import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Task 2.5 — spawn/reopen walk the phase funnel synchronously; liveness respects being-born phases;
/// markDead concludes; the `relaunchClaimed` atomic claim replaces the deleted `recovering` set.
@Suite("OrchestraService — spawn/reopen phase funnel (2.5)")
struct SpawnPhaseTests {

    /// Phases emitted for `id`, in order, off a subscription started before the action.
    private func phases(_ collector: EventCollector, _ id: UUID) async -> [Phase] {
        await collector.upserts.filter { $0.id == id }.map { $0.phase }
    }
    private func isLive(_ p: Phase) -> Bool { if case .live = p { return true } else { return false } }

    @Test("spawn drives .creatingWorktree → .launching → .live, epoch pinned at 1")
    func test_spawnDrivesPhases() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "go", repo: repo, branch: "b"))
        try await pollUntil("the .live upsert is delivered") {
            await phases(collector, t.id).contains(where: isLive)
        }

        let ps = await phases(collector, t.id)
        let cw = ps.firstIndex(of: .creatingWorktree)
        let la = ps.firstIndex(of: .launching)
        let li = ps.firstIndex(where: isLive)
        #expect(cw != nil && la != nil && li != nil)
        if let cw, let la, let li { #expect(cw < la && la < li) }
        // sessionEpoch is set at creation and NEVER bumped again on the spawn walk.
        #expect(await collector.upserts.filter { $0.id == t.id }.allSatisfy { $0.sessionEpoch == 1 })
        #expect(t.sessionEpoch == 1)
    }

    @Test("spawn's initial persisted record is .creatingWorktree at epoch 1 (before any transition)")
    func test_spawnInitialRecordIsCreatingWorktree() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "go", repo: repo, branch: "b"))
        try await pollUntil("the spawn upserts are delivered") {
            await collector.upserts.contains { $0.id == t.id }
        }

        let first = await collector.upserts.first { $0.id == t.id }
        #expect(first?.phase == .creatingWorktree)
        #expect(first?.sessionEpoch == 1)
    }

    @Test("liveness skips being-born phases: sessionless .relaunching/.creatingWorktree/.launching cards are NOT killed")
    func test_livenessSkipsBeingBornPhases() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)

        // .relaunching + no session → NOT killed.
        let r = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "r"))
        _ = await env.svc.transition(r.id, to: .relaunching)
        env.sessions.setAlive(r.id, false)
        await env.svc.reconcileLiveness()
        #expect(await env.svc.list(includeArchived: true).first { $0.id == r.id }?.phase.kind == .relaunching)

        // .creatingWorktree + no session → NOT killed (reach it via the reopen normalize path).
        let c = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "c"))
        try await env.svc.archive(c.id)
        _ = await env.svc.transition(c.id, to: .archived(teardownComplete: true))
        _ = await env.svc.transition(c.id, to: .creatingWorktree)
        env.sessions.setAlive(c.id, false)
        await env.svc.reconcileLiveness()
        #expect(await env.svc.list(includeArchived: true).first { $0.id == c.id }?.phase.kind == .creatingWorktree)

        // .launching + vanished session → NOT killed (mirrors .creatingWorktree/.relaunching). The SYNCHRONOUS
        // launchAndConfirm owns readiness + the spawnFailed timeout, so liveness must never markDead a .launching
        // card — doing so races the launch's own transition(.launching)→ensure window and false-kills a live spawn.
        let l = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "l"))
        try await env.svc.archive(l.id)
        _ = await env.svc.transition(l.id, to: .archived(teardownComplete: true))
        _ = await env.svc.transition(l.id, to: .creatingWorktree)
        _ = await env.svc.transition(l.id, to: .launching)
        env.sessions.setAlive(l.id, false)
        await env.svc.reconcileLiveness()
        #expect(await env.svc.list(includeArchived: true).first { $0.id == l.id }?.phase.kind == .launching)
    }

    @Test("a prompted spawn lands .live(.running)")
    func test_promptedSpawnLandsRunning() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "do the thing", repo: repo, branch: "b"))
        #expect(t.phase == .live(.running))
    }

    @Test("a promptless (provisional) spawn lands .live(.waiting(.humanTurn))")
    func test_provisionalSpawnLandsWaiting() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "b"))
        #expect(t.phase == .live(.waiting(.humanTurn)))
    }

    @Test("relaunch supersede: a second relaunching self-edge bumps the epoch; the first attempt's completion is dropped")
    func test_relaunchSupersede() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))

        _ = await env.svc.transition(t.id, to: .relaunching)
        let e1 = try #require(await env.svc.store.get(t.id)).sessionEpoch
        _ = await env.svc.transition(t.id, to: .relaunching)   // supersede self-edge
        let e2 = try #require(await env.svc.store.get(t.id)).sessionEpoch
        #expect(e2 == e1 + 1)

        // The first attempt's completion (old epoch) is fenced out.
        let stale = await env.svc.transition(t.id, to: .live(.waiting(.humanTurn)), observedEpoch: e1)
        #expect(stale == .noop)
        #expect(try #require(await env.svc.store.get(t.id)).phase.kind == .relaunching)

        // The surviving attempt's completion (current epoch) applies.
        let fresh = await env.svc.transition(t.id, to: .live(.waiting(.humanTurn)), observedEpoch: e2)
        #expect(fresh == .applied)
    }

    @Test("a .dead(.completed) card revives to .live only on an epoch-current signal — never a verb")
    func test_deadCompletedRevivesOnSignal() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)

        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        _ = await env.svc.transition(t.id, to: .dead(.completed))
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        let revived = await env.svc.transition(t.id, to: .live(.running), observedEpoch: epoch)   // viaSignal
        #expect(revived == .applied)
        #expect(try #require(await env.svc.store.get(t.id)).phase == .live(.running))

        // A verb (no observedEpoch) may NOT drive dead → live.
        let t2 = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b2"))
        _ = await env.svc.transition(t2.id, to: .dead(.completed))
        let byVerb = await env.svc.transition(t2.id, to: .live(.running))
        #expect(byVerb == .rejected(from: .dead(.completed), to: .live(.running)))
    }

    @Test("two concurrent wakes on an idle card resume exactly once (relaunchClaimed defers the second)")
    func test_concurrentWakeDoesNotDoubleResume() async throws {
        // .claudeCode (sessionStartHook): the resume genuinely awaits its signal, so the in-flight window
        // the `relaunchClaimed` deferral depends on is observable (a `.relaunchLiveness` stub confirms too
        // fast to exercise it). spawnAwaited drives the setup spawn's launch-ready signal.
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)                       // resumable
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))   // idle
        let name = env.sessions.sessionName(t.id)
        let before = env.sessions.ensureCount

        async let w1: Void = env.svc.wake(t.id)
        async let w2: Void = env.svc.wake(t.id)
        _ = await (w1, w2)

        // `relaunchClaimed` lets ONE resume-seed proceed → ONE `.relaunching` transition; the reconciler
        // then drives that single relaunch (the other wake deferred at the claim).
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[name]?.contains("--resume") == true
        }
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))     // confirm the ONE resume
        await yieldBriefly()   // negative: a wrongful second resume-seed gets its chance to run
        #expect(env.sessions.ensureCount == before + 1)                           // one relaunch, not two
    }

    @Test("reopen drives .archived → .creatingWorktree → .launching → .live and re-materializes the cwd")
    func test_reopenDrivesCreatingWorktreePath() async throws {
        // .claudeCode: reopen's resume path awaits the delivered SessionStart(resume), so the
        // creatingWorktree→launching→live sequence lands deterministically (with time for the collector to
        // drain) instead of racing a too-fast `.relaunchLiveness` confirm.
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        let sid = try #require(t.agentSessionId)
        env.adapter.writeTranscript(for: sid)                                     // resumable
        try await TestEnv.archiveAndTeardown(env.svc, t.id)

        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        // Intent-only reopen enqueues `.creatingWorktree`; the reconciler walks it → launching → live.
        _ = try await env.svc.reopen(t.id, source: .app)
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id, inject: true)

        #expect(updated.archived == false)
        #expect(updated.agentSessionId == sid)                                    // resumed, id kept
        let ps = await phases(collector, t.id)
        let cw = ps.firstIndex(of: .creatingWorktree)
        let la = ps.firstIndex(of: .launching)
        let li = ps.firstIndex(where: isLive)
        #expect(cw != nil && la != nil && li != nil)
        #expect(cw! < la! && la! < li!)
        #expect(env.worktrees.ensured.contains("\(t.repo)#\(t.branch)"))          // cwd re-materialized
    }

    @Test("reopen of an archived card whose transcript is gone lands live via a blank launch")
    func test_reopenBlankWhenTranscriptGone() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        let oldId = try #require(t.agentSessionId)
        try await TestEnv.archiveAndTeardown(env.svc, t.id)                        // no transcript → not resumable

        let intent = try await env.svc.reopen(t.id, source: .app)
        #expect(intent.agentSessionId != oldId)                                    // fresh id (blank restart)
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)             // reconciler blank-launches

        #expect(updated.archived == false)
        #expect(updated.phase == .live(.waiting(.humanTurn)))
        #expect(updated.agentSessionId != oldId)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(!argv.contains("--resume"))
    }

    @Test("a suspended wait resolves when the awaited child dies via liveness (markDead concludes)")
    func test_waitResolvesOnCrashDeath() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "parent", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "child", repo: repo, branch: "c"))

        async let concl = env.svc.wait(watcher: parent.id, refs: [child.id])
        try await pollUntil("the wait subscription is registered") {
            await env.svc.activeWaitSubscriptionCount() == 1
        }
        env.sessions.setAlive(child.id, false)          // crash: session vanished, no SessionEnd
        await env.svc.reconcileLiveness()

        let c = await concl
        #expect(c?.kind == .exited)
        #expect(c?.deadReason == .sessionVanished)
    }
}
