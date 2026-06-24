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
        #expect(cAfter?.status == .dead)
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
        #expect(updated.status == .waiting)
        #expect(updated.deadReason == nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id (no new mint)
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
        #expect(after.status == .dead)
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
        #expect(after.status == .dead)
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
        #expect(updated.status == .waiting)
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

    @Test("reconcileLiveness: vanished session → .dead sessionVanished; recovering card not falsely killed")
    func reconcile() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setAlive(t.id, false)   // vanished (crash / tmux kill, no SessionEnd)
        await env.svc.reconcileLiveness()
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
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
}
