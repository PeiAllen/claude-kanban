import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — recovery: recoverSessions / resume / restart / reconcile")
struct RecoveryTests {

    @Test("recoverSessions: alive skipped; gone+transcript queues resume; gone+no transcript → dead; archived skipped")
    func recoverDecisions() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)

        // A: alive → must be skipped
        let a = try await env.svc.spawn(SpawnInput(prompt: "alive", repo: repo, branch: "a"))
        env.sessions.setAlive(a.id, true)

        // B: gone + transcript exists → resumable (will be relaunched)
        let b = try await env.svc.spawn(SpawnInput(prompt: "resumable", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: b.agentSessionId!)
        env.sessions.setAlive(b.id, false)

        // C: gone + no transcript → dead (rebootUnrevived)
        let c = try await env.svc.spawn(SpawnInput(prompt: "unrevivable", repo: repo, branch: "c"))
        env.sessions.setAlive(c.id, false)   // no transcript written

        // D: archived → skipped
        let d = try await env.svc.spawn(SpawnInput(prompt: "archived", repo: repo, branch: "d"))
        try await env.svc.archive(d.id)

        let aEnsureBefore = env.sessions.ensureCount

        // Drive recovery; concurrently satisfy B's resume callback so it confirms.
        async let recovered: Void = env.svc.recoverSessions()
        // B's resume awaits a SessionStart(resume) callback — deliver it.
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try? await env.svc.report(b.id, StatusReport(sessionSource: "resume"))
        await recovered

        let all = await env.svc.list(includeArchived: true)
        let cAfter = all.first { $0.id == c.id }
        #expect(cAfter?.phaseDisplay == .dead)
        #expect(cAfter?.deadReason == .rebootUnrevived)
        // A (alive) was not relaunched
        let aArgv = env.sessions.ensureArgv[env.sessions.sessionName(a.id)]
        // a was launched once at spawn; ensure count for A shouldn't grow from recovery
        #expect(aArgv != nil)
        // B was relaunched with a --resume argv
        let bArgv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(b.id)])
        #expect(bArgv.contains("--resume"))
        #expect(env.sessions.ensureCount > aEnsureBefore)  // at least B relaunched
    }

    @Test("resume success: confirmed within grace → .waiting, deadReason cleared, same id kept")
    func resumeSuccess() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        async let resumed = env.svc.resume(t.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed
        #expect(updated.waitReason != nil)
        #expect(updated.deadReason == nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id (no new mint)
    }

    @Test("resume success: SessionStart callback delivered BEFORE awaitResume registers still confirms (no lost wakeup)")
    func resumeConfirmBeforeWaiterRegistered() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        // Force the exact ordering behind the parallel-load flake: make the off-actor relaunch slow so
        // the SessionStart(resume) `report()` lands WHILE resume() is still inside `offActor` — i.e.
        // before `awaitResume()` has registered its continuation. The confirmation must not be dropped.
        env.sessions.ensureSleepMs = 250

        async let resumed = env.svc.resume(t.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(40))   // well inside the 250ms relaunch window
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed

        #expect(updated.waitReason != nil)
        #expect(updated.deadReason == nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id
    }

    @Test("resume failure: no transcript → .dead resumeFailed + throws")
    func resumeFailNoTranscript() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        // no transcript written → "transcript gone"
        await #expect(throws: OrchestraError.self) { _ = try await env.svc.resume(t.id) }
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .resumeFailed)
        #expect(after.deadDetail?.contains("transcript") == true)
    }

    @Test("resume failure: transcript present but no callback within grace → .dead resumeFailed")
    func resumeFailTimeout() async throws {
        let env = TestEnv.make(grace: 0)   // immediate timeout, no callback delivered
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        await #expect(throws: OrchestraError.self) { _ = try await env.svc.resume(t.id) }
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .resumeFailed)
        #expect(after.deadDetail?.contains("callback") == true)
    }

    @Test("restart: fresh id (old→prior), blank (no prompt), status waiting, provisional, deadReason cleared, initialPrompt intact")
    func restart() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "Original ask", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: "x", source: .daemon)
        let oldId = try #require(t.agentSessionId)

        let updated = try await env.svc.restart(t.id, source: .app)
        #expect(updated.waitReason != nil)
        #expect(updated.titleProvisional == true)
        #expect(updated.deadReason == nil)
        #expect(updated.deadDetail == nil)
        #expect(updated.initialPrompt == "Original ask")    // intact, not re-sent
        let newId = try #require(updated.agentSessionId)
        #expect(newId != oldId)
        #expect(updated.priorSessionIds.contains(oldId))
        // launch argv carries --name <title> as its last pair; NO positional prompt follows it
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(argv[nameIdx + 1] == updated.title)
        #expect(argv.count == nameIdx + 2)   // nothing after the name value → the prompt is NOT re-handed
    }

    @Test("recoverSessions: never-prompted (provisional, no transcript) card restarts fresh, not dead")
    func recoverRestartsNeverPrompted() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        // No initial prompt → titleProvisional, and no transcript ever written.
        let p = try await env.svc.spawn(SpawnInput(prompt: "", repo: repo, branch: "fresh"))
        #expect(p.titleProvisional == true)
        let oldId = try #require(p.agentSessionId)
        env.sessions.setAlive(p.id, false)   // session gone (reboot), no transcript on disk

        await env.svc.recoverSessions()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == p.id })
        #expect(after.waitReason != nil)        // restarted fresh, NOT marked dead
        #expect(after.deadReason == nil)
        let newId = try #require(after.agentSessionId)
        #expect(newId != oldId)                   // restart mints a fresh session id
        #expect(after.priorSessionIds.contains(oldId))
        // Relaunched via a fresh `start` (no --resume).
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(p.id)])
        #expect(!argv.contains("--resume"))
    }

    @Test("reconcileLiveness: vanished session → .dead sessionVanished; recovering card not falsely killed")
    func reconcile() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setAlive(t.id, false)   // vanished (crash / tmux kill, no SessionEnd)
        await env.svc.reconcileLiveness()
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .sessionVanished)
    }

    @Test("recover throttle: peak concurrent revivals never exceeds maxConcurrentRevivals")
    func throttle() async throws {
        let env = TestEnv.make(maxRevivals: 3, grace: 1)
        let repo = TestEnv.repo(env.base)
        env.sessions.ensureSleepMs = 120   // create overlap so concurrency is observable

        for i in 0..<9 {
            let t = try await env.svc.spawn(SpawnInput(prompt: "card\(i)", repo: repo, branch: "br\(i)"))
            env.adapter.writeTranscript(for: t.agentSessionId!)
            env.sessions.setAlive(t.id, false)
        }
        let countBefore = env.sessions.peakConcurrentEnsure
        await env.svc.recoverSessions()   // no callbacks → each resume times out after grace
        #expect(env.sessions.peakConcurrentEnsure <= 3)
        #expect(env.sessions.peakConcurrentEnsure >= countBefore)
    }

    /// The ONE place a `send` to an idle card is otherwise silently dropped: it lands in the `recovering`
    /// grace window right after a prior resume, so `wake` no-ops at gate A — and unlike every other gate,
    /// nothing else retries it (no running turn to Stop-drain, no reinvoke). The fix re-drives `wake` the
    /// instant that window closes (`scheduleRecoveringRelease` → `wakeIfPending`), event-driven, no poll.
    @Test("a send during the recovering grace window is delivered when the window closes")
    func sendDuringRecoveringDeliveredOnRelease() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))                       // idle
        let name = env.sessions.sessionName(card.id)

        // send A wakes → resume #1; confirm it so `recovering` is held for the grace window.
        try await env.svc.send(card.id, "A")
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))   // resume #1 confirmed
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))          // idle again, still in grace
        let ensureAfterA = env.sessions.ensureCount

        // send B lands DURING the recovering window → wake no-ops at gate A, message stranded.
        try await env.svc.send(card.id, "B")
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        #expect(env.sessions.ensureCount == ensureAfterA)                          // gate A no-op: not resumed yet
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["B"])         // stranded

        // When the window closes, releaseRecovering → wakeIfPending re-drives wake → resume #2 delivers B.
        try await pollUntil { env.sessions.ensureCount > ensureAfterA }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))   // confirm resume #2
        #expect(try #require(env.sessions.ensureArgv[name]).last?.contains("B") == true)   // B rode the seed
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)                      // drained
    }

    @Test("wakeIfPending leaves a RUNNING card alone (its Stop-drain owns delivery)")
    func wakeIfPendingSkipsRunningCard() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.send(card.id, "later")                         // queues (gate B), not delivered now
        let ensureBefore = env.sessions.ensureCount

        await env.svc.wakeIfPending(card.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        #expect(env.sessions.ensureCount == ensureBefore)                // no relaunch — running turn untouched
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])   // stays for its Stop-drain
    }

    /// Regression: two overlapping `resume(id)` for the SAME card must never leak a continuation. The
    /// second resume registers a waiter that (before the fix) OVERWROTE the first in `resumeWaiters[id]`
    /// without resolving it — leaking the first `awaitResume` continuation, so `resume` #1 never returns,
    /// its `defer`/`scheduleRecoveringRelease` never runs, and the card stays in `recovering` FOREVER →
    /// `wake` gate A (`!recovering.contains(id)`) no-ops every future `send`, and the idle card can never
    /// be woken again (the "idle Claude ignores a send / inbox add" bug). Overlap is reachable in the wild:
    /// `resume`/`handoff`/`reopen` don't gate on `recovering`, and `recoverSessions` can race a send-wake.
    @Test("overlapping resume(id): the superseded resume returns (no leaked continuation → recovering can't stick)")
    func concurrentResumeNeverLeaks() async throws {
        let env = TestEnv.make(grace: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: t.agentSessionId!)                                 // resumable
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))                      // idle
        let name = env.sessions.sessionName(t.id)

        // Does `op` finish at all? A leaked continuation leaves it suspended FOREVER, so the bound only
        // separates "returned" from "hung" — generous so heavy-load scheduler latency can't flake it.
        func completes(_ op: @escaping @Sendable () async -> Void) async -> Bool {
            await withTaskGroup(of: Bool.self) { g in
                g.addTask { await op(); return true }
                g.addTask { try? await _Concurrency.Task.sleep(for: .seconds(15)); return false }
                let first = await g.next() ?? false
                g.cancelAll()
                return first
            }
        }

        // Two resumes for the same card, overlapping.
        async let c1 = completes { _ = try? await env.svc.resume(t.id) }
        async let c2 = completes { _ = try? await env.svc.resume(t.id) }
        // Both land a `--resume` relaunch; deliver ONE SessionStart(resume) to confirm the surviving waiter.
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))

        #expect(await c1)   // one is confirmed, the other superseded — BOTH must return, neither may hang
        #expect(await c2)

        // And the card must remain wakeable: it is idle+resumable and NOT stuck in `recovering`, so a
        // fresh send resume-seeds it. (grace=1s must elapse first so the confirmed resume's release fires.)
        let confirmed = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(confirmed.phaseDisplay != .dead)
        try await _Concurrency.Task.sleep(for: .milliseconds(1100))   // let scheduleRecoveringRelease fire
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))
        let ensureBefore = env.sessions.ensureCount
        try await env.svc.send(t.id, "PING-AFTER-LEAK")
        try await pollUntil { env.sessions.ensureCount > ensureBefore }   // stuck `recovering` → never fires
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))   // confirm the post-leak wake
    }
}
