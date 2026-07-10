import Foundation
import Testing
@testable import OrchestraCore

/// F2 · `send` must wake an idle native-reinvoke (Claude) card. A message queued onto a card that has
/// already ended its turn (`.waiting`) has no in-flight turn to Stop-drain it and no background
/// `orchestra wait` whose exit would re-invoke the harness — so before this fix it sat durable until
/// some unrelated future turn. The wake reuses the proven resume-seed primitive (`resumeInCard`): the
/// inbox folds into the resumed session's opening turn.
@Suite("F2 · send wakes an idle native-reinvoke (Claude) card")
struct SendWakeTests {

    /// Drive a resumable card to the idle `.waiting` state (turn ended), the exact state the bug hides in.
    private func idleResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: branch))   // .running
        env.adapter.writeTranscript(for: t.agentSessionId!)                                     // resumable
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))                          // idle/Waiting
        return t
    }

    @Test("send resume-seeds an idle Claude card so the queued message lands now")
    func sendResumeSeedsIdleClaude() async throws {
        let env = TestEnv.make(grace: 2)                     // default caps = .claudeCode (nativeReinvoke)
        let card = try await idleResumable(env, branch: "b")
        let name = env.sessions.sessionName(card.id)

        try await env.svc.send(card.id, "PING-IDLE")
        // The wake resume-seeds on a detached task; wait for the relaunch, then feed the resume callback.
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))

        let argv = try #require(env.sessions.ensureArgv[name])
        #expect(argv.contains("--resume"))                   // a resume relaunch, never a fresh start
        let seed = try #require(argv.last)
        #expect(seed.contains("PING-IDLE"))                  // the message rides the opening turn
        // Drained into the seed → nothing left to double-deliver on the resumed session's Stop.
        #expect(await env.svc.drainForStop(card.id) == nil)
    }

    @Test("send does NOT resume-seed a RUNNING card (its natural Stop-drain delivers it)")
    func sendDefersRunningClaude() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        let ensureBefore = env.sessions.ensureCount

        try await env.svc.send(card.id, "later")
        try await _Concurrency.Task.sleep(for: .milliseconds(120))

        #expect(env.sessions.ensureCount == ensureBefore)                     // no relaunch
        #expect(env.sessions.killed.isEmpty)                                  // the live turn is untouched
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])    // message stays durable
    }

    @Test("send does NOT resume-seed a card with a live native wait subscription")
    func sendDefersLiveNativeWaitSubscription() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: parent.agentSessionId!)
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 } // parent has a live `orchestra wait`
        try await env.svc.report(parent.id, StatusReport(run: .waiting(.humanTurn)))   // idle, but waiting on the child
        let ensureBefore = env.sessions.ensureCount

        try await env.svc.send(parent.id, "poke")
        try await _Concurrency.Task.sleep(for: .milliseconds(120))

        #expect(env.sessions.ensureCount == ensureBefore)                     // NOT relaunched — fan-out preserved
        #expect(try await env.svc.inboxPeek(parent.id).contains { $0.text == "poke" })
        waiting.cancel(); _ = await waiting.value
    }

    @Test("send does NOT resume-seed a never-prompted card with no transcript (nothing to resume)")
    func sendDefersUnresumable() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        // Provisional spawn (no prompt) → .waiting, but no transcript on disk yet → not resumable.
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "", repo: repo, branch: "b"))
        let ensureBefore = env.sessions.ensureCount

        try await env.svc.send(card.id, "hello")
        try await _Concurrency.Task.sleep(for: .milliseconds(120))

        #expect(env.sessions.ensureCount == ensureBefore)                     // no relaunch
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["hello"])    // durable until the first real turn
    }
}
