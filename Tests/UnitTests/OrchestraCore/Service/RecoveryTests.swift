import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("OrchestraService — recovery: reconcilePhasesAtBoot / resume / restart / reconcile")
struct RecoveryTests {

    /// Drive `reconcile()` ticks (like `reconcileUntilLive`) until `cond` holds — the steppers run
    /// off-actor, so a single tick only DISPATCHES a step; polling lets it complete.
    static func reconcileUntil(_ svc: OrchestraService, _ cond: @escaping @Sendable () async -> Bool) async throws {
        try await pollUntil { await svc.reconcile(); return await cond() }
    }

    @Test("reconcilePhasesAtBoot: alive+epoch adopted; gone+transcript → relaunch/resume; gone+no transcript → dead; archived skipped")
    func recoverDecisions() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // Bring all four LIVE first (non-blocking spawn + reconciler), THEN apply the session-liveness
        // manipulations. Doing the setAlive(false) BEFORE a later spawnAndAwaitLive would let that spawn's
        // reconcile tick markDead the session-gone card early (as `.sessionVanished`) — corrupting the setup
        // this boot pass is meant to classify.
        let a = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "alive", repo: repo, branch: "a"))
        let b = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "resumable", repo: repo, branch: "b"))
        let c = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "unrevivable", repo: repo, branch: "c"))
        let d = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "archived", repo: repo, branch: "d"))

        // A: alive at the matching epoch → adopted (stays live, not relaunched).
        env.sessions.setAlive(a.id, true)
        // B: gone + transcript exists → resumable (relaunch → resume).
        env.adapter.writeTranscript(for: b.agentSessionId!)
        env.sessions.setAlive(b.id, false)
        // C: gone + no transcript, prompted → dead (rebootUnrevived).
        env.sessions.setAlive(c.id, false)
        // D: archived → skipped.
        try await env.svc.archive(d.id)

        let aEnsureBefore = env.sessions.ensureCount

        await env.svc.reconcilePhasesAtBoot()
        // B was routed to `.relaunching`; drive ticks so the RelaunchStepper resumes it to `.live`.
        try await Self.reconcileUntil(env.svc) {
            await env.svc.list(includeArchived: true).first { $0.id == b.id }?.phase.kind == .live
        }

        let all = await env.svc.list(includeArchived: true)
        let cAfter = all.first { $0.id == c.id }
        #expect(cAfter?.phaseDisplay == .dead)
        #expect(cAfter?.deadReason == .rebootUnrevived)
        // A (alive, epoch-matched) was adopted — still live.
        #expect(all.first { $0.id == a.id }?.phase.kind == .live)
        // Only B relaunched (A adopted, C dead, D archived) → exactly one recovery ensure.
        #expect(env.sessions.ensureCount == aEnsureBefore + 1)
        // B was relaunched with a --resume argv.
        let bArgv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(b.id)])
        #expect(bArgv.contains("--resume"))
    }

    @Test("resume success: confirmed within grace → .waiting, deadReason cleared, same id kept")
    func resumeSuccess() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        // Intent-only: resume records `.relaunching` + returns; the RelaunchStepper (reconciler) resumes it.
        let intent = try await env.svc.resume(t.id)
        #expect(intent.phase.kind == .relaunching)
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(updated.waitReason != nil)
        #expect(updated.deadReason == nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id (no new mint)
    }

    @Test("resume success: SessionStart callback delivered BEFORE awaitResume registers still confirms (no lost wakeup)")
    func resumeConfirmBeforeWaiterRegistered() async throws {
        // .claudeCode: the resume genuinely awaits SessionStart(resume), so the pending-before-registered
        // ordering is exercisable (a `.relaunchLiveness` stub never registers a waiter).
        let env = TestEnv.make(grace: 2, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        // Force the exact ordering behind the parallel-load flake: PARK the off-actor relaunch (now inside the
        // RelaunchStepper's `finishLaunch`) so the SessionStart(resume) `report()` lands WHILE the step is
        // still inside `offActor` — i.e. before `awaitReadiness` registers its continuation. It must not drop.
        // Drive the RelaunchStepper DIRECTLY (not the full reconcile loop) so the ordering is deterministic.
        let gate = SyncGate()
        env.sessions.ensureGate = gate

        let intent = try await env.svc.resume(t.id)            // intent → `.relaunching`
        #expect(intent.phase.kind == .relaunching)
        let ctx = await env.svc.convergeContext()
        async let stepping: Void = RelaunchStepper().step(intent, ctx)
        await gate.reached()                                   // provably parked inside the off-actor ensure
        env.sessions.ensureGate = nil                          // only the scheduled call parks
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))   // lands before the waiter registers
        gate.release()
        try await stepping

        let updated = try #require(await env.svc.store.get(t.id))
        #expect(updated.phase.kind == .live)
        #expect(updated.waitReason != nil)
        #expect(updated.deadReason == nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id
    }

    @Test("resume failure: no transcript (non-provisional) → RelaunchStepper marks .dead resumeFailed")
    func resumeFailNoTranscript() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        // Intent-only: resume no longer throws — it records `.relaunching`; the RelaunchStepper fails safe
        // (non-provisional card, no transcript on disk → `.dead(.resumeFailed)` "transcript gone").
        _ = try await env.svc.resume(t.id)
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == t.id }?.phase.kind == .dead
        }
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .resumeFailed)
        #expect(after.deadDetail?.contains("transcript") == true)
    }

    @Test("resume failure: transcript present but no ready signal → reconciler launch-timeout marks .dead resumeFailed")
    func resumeFailTimeout() async throws {
        // .claudeCode so the relaunch awaits its SessionStart(resume) hook; with NO signal delivered the
        // RelaunchStepper leaves the card `.relaunching`, and the reconciler's `phaseChangedAt` launch-timeout
        // (carry #2) marks it dead. Back-date the anchor so the bound trips deterministically.
        let env = TestEnv.make(grace: 2, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)

        _ = try await env.svc.resume(t.id)                     // intent → `.relaunching`
        env.sessions.setAlive(t.id, false)                     // no stale session to adopt / N=3-tick to live
        // Back-date the phase anchor past the launch timeout so the reconciler's timeout arm fires.
        let timeout = await env.svc.config.sessionLaunchTimeout
        await env.svc.seedPhase(t.id, .relaunching, phaseChangedAt: Date().addingTimeInterval(-Double(timeout) - 5))
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == t.id }?.phase.kind == .dead
        }
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .resumeFailed)
        #expect(after.deadDetail?.contains("timed out") == true)
    }

    @Test("restart: fresh id (old→prior), blank (no prompt), status waiting, provisional, deadReason cleared, initialPrompt intact")
    func restart() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "Original ask", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: "x", source: .daemon)
        let oldId = try #require(t.agentSessionId)

        // Intent-only: restart records `.relaunching` with the persist block; the RelaunchStepper blank-launches.
        let intent = try await env.svc.restart(t.id, source: .app)
        #expect(intent.phase.kind == .relaunching)
        #expect(intent.titleProvisional == true)
        #expect(intent.deadReason == nil)
        #expect(intent.deadDetail == nil)
        let newId = try #require(intent.agentSessionId)
        #expect(newId != oldId)
        #expect(intent.priorSessionIds.contains(oldId))
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(updated.waitReason != nil)
        #expect(updated.initialPrompt == "Original ask")    // intact, not re-sent
        // launch argv carries --name <title> as its last pair; NO positional prompt follows it
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(argv[nameIdx + 1] == updated.title)
        // Only the model flag trails the name — no positional → the prompt is NOT re-handed.
        #expect(Array(argv[(nameIdx + 2)...]) == ["--model", "m1"])
    }

    @Test("test_restartSingleWinner")
    func test_restartSingleWinner() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))

        // Two restarts in quick succession: the second's `.relaunching` supersede self-edge bumps the epoch.
        let r1 = try await env.svc.restart(t.id)
        let e1 = r1.sessionEpoch
        let r2 = try await env.svc.restart(t.id)
        let e2 = r2.sessionEpoch
        #expect(e2 == e1 + 1)   // supersede bump — the single-winner mechanism (NOT competing steppers)

        // The earlier attempt's finalize (old epoch) is epoch-fenced to a no-op.
        let stale = await env.svc.transition(t.id, to: .live(.waiting(.humanTurn)), observedEpoch: e1)
        #expect(stale == .noop)
        #expect(try #require(await env.svc.store.get(t.id)).phase.kind == .relaunching)

        // The reconciler admits ONE step (`inFlightSteps`) and converges a single live session.
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(live.phase.kind == .live)
        let names = try env.sessions.list().map(\.name)
        #expect(names.filter { $0 == env.sessions.sessionName(t.id) }.count == 1)   // exactly one session
    }

    @Test("reconcilePhasesAtBoot: never-prompted (provisional, no transcript) card blank-restarts, not dead")
    func recoverRestartsNeverPrompted() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        // No initial prompt → titleProvisional, and no transcript ever written.
        let p = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "fresh"))
        #expect(p.titleProvisional == true)
        env.sessions.setAlive(p.id, false)   // session gone (reboot), no transcript on disk

        await env.svc.reconcilePhasesAtBoot()   // provisional → `.relaunching` (blank-restart intent)
        try await Self.reconcileUntil(env.svc) {
            await env.svc.list(includeArchived: true).first { $0.id == p.id }?.phase.kind == .live
        }

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == p.id })
        #expect(after.waitReason != nil)        // blank-restarted (idle waiting), NOT marked dead
        #expect(after.deadReason == nil)
        // Relaunched via a fresh `start` (no --resume) — the RelaunchStepper's provisional blank path.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(p.id)])
        #expect(!argv.contains("--resume"))
    }

    @Test("reconcileLiveness: vanished session → .dead sessionVanished; recovering card not falsely killed")
    func reconcile() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.sessions.setAlive(t.id, false)   // vanished (crash / tmux kill, no SessionEnd)
        await env.svc.reconcileLiveness()
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .sessionVanished)
    }

    // (The old windowed-revival `throttle` test is retired: the reconciler paces recovery per-card via
    // `inFlightSteps` + capped backoff — one step in flight per card — rather than a global revival window,
    // so `maxConcurrentRevivals` no longer governs boot recovery. Backoff is covered by `stepFailureBacksOff`.)

    /// The ONE place a `send` to an idle card is otherwise silently dropped: it lands WHILE a prior
    /// wake-driven resume is in flight (`relaunchClaimed` set / the card mid-`.relaunching`), so `wake`
    /// defers — and unlike every other gate, nothing else retries it (no running turn to Stop-drain, no
    /// reinvoke). The fix re-drives `wake` the instant that relaunch settles (`clearRelaunchClaimed` →
    /// `wakeIfPending`), event-driven, no poll.
    @Test("a send that lands mid-relaunch is delivered when the relaunch settles")
    func sendDuringRelaunchDeliveredOnRelease() async throws {
        // .claudeCode: the wake-driven resume stays IN FLIGHT until its SessionStart(resume) hook lands, so
        // a second send genuinely arrives mid-relaunch (a `.relaunchLiveness` stub confirms too fast to race).
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))             // idle
        let name = env.sessions.sessionName(card.id)

        // send A wakes → resume-seed transitions `.relaunching` (A drained + folded into pendingSeed). Drive
        // the RelaunchStepper DIRECTLY (deterministic — no N=3 fallback racing the mid-relaunch window): it
        // ensures the `--resume` session then AWAITS the SessionStart(resume) hook.
        let ctx = await env.svc.convergeContext()
        try await env.svc.send(card.id, "A")
        try await pollUntil { await env.svc.store.get(card.id)?.phase.kind == .relaunching }
        let relaunchingA = try #require(await env.svc.store.get(card.id))
        async let steppingA: Void = RelaunchStepper().step(relaunchingA, ctx)
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        let ensureAfterA = env.sessions.ensureCount

        // send B lands mid-relaunch (card `.relaunching`, readiness pending) → wake defers, B stranded.
        try await env.svc.send(card.id, "B")
        await yieldBriefly()   // negative: a wrongful second resume's detached task gets its chance to run
        #expect(env.sessions.ensureCount == ensureAfterA)                          // deferred: not resumed yet
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["B"])         // stranded (A rode the seed)

        // Confirm resume #1 → `.live` → the funnel's wake-on-live re-drives wake → resume #2 (B folded).
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))
        try await steppingA
        try await pollUntil { await env.svc.store.get(card.id)?.phase.kind == .relaunching }   // B's resume-seed
        let relaunchingB = try #require(await env.svc.store.get(card.id))
        async let steppingB: Void = RelaunchStepper().step(relaunchingB, ctx)
        try await pollUntil { env.sessions.ensureCount > ensureAfterA }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))   // confirm resume #2
        try await steppingB
        #expect(try #require(env.sessions.ensureArgv[name]).last?.contains("B") == true)   // B rode the seed
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)                      // drained
    }

    @Test("wakeIfPending leaves a RUNNING card alone (its Stop-drain owns delivery)")
    func wakeIfPendingSkipsRunningCard() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.send(card.id, "later")                         // queues (gate B), not delivered now
        let ensureBefore = env.sessions.ensureCount

        await env.svc.wakeIfPending(card.id)
        await yieldBriefly()   // negative: a wrongful wake's detached resume gets its chance to run
        #expect(env.sessions.ensureCount == ensureBefore)                // no relaunch — running turn untouched
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])   // stays for its Stop-drain
    }

    /// Regression: two overlapping `resume(id)` for the SAME card must never leak a continuation and must
    /// converge to a single live session (single-winner). Intent-only (PR4b Task 4): each `resume` is now a
    /// non-blocking `transition(→ .relaunching)` (the supersede self-edge bumps the epoch), so neither call
    /// holds a continuation to leak; the reconciler admits ONE step (`inFlightSteps`) and any earlier
    /// bring-up's `.live` finalize is epoch-fenced. The card stays wakeable afterward.
    @Test("overlapping resume(id): both return immediately; the reconciler converges one live session; card stays wakeable")
    func concurrentResumeNeverLeaks() async throws {
        // .claudeCode: the relaunch genuinely awaits its SessionStart(resume) hook (a `.relaunchLiveness` stub
        // would confirm too fast to exercise the overlap).
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: t.agentSessionId!)                                 // resumable
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))                      // idle

        // Two overlapping resumes — both are intent-only and MUST return (never hang on a leaked continuation).
        async let r1: Task = env.svc.resume(t.id)
        async let r2: Task = env.svc.resume(t.id)
        _ = try await r1
        _ = try await r2
        // The reconciler drives the surviving relaunch to a single live session.
        let live = try await TestEnv.reconcileToLive(env.svc, t.id, inject: true)
        #expect(live.phaseDisplay != .dead)

        // And the card must remain wakeable: idle+resumable, no stuck claim, so a fresh send resume-seeds it.
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))
        let ensureBefore = env.sessions.ensureCount
        try await env.svc.send(t.id, "PING-AFTER-LEAK")
        try await pollUntil { await env.svc.reconcile(); return env.sessions.ensureCount > ensureBefore }
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))   // confirm the post-wake relaunch
    }
}
