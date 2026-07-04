import Foundation
import Testing
@testable import OrchestraCore

/// F2 · Codex wakes by **resume-seed** (`wakeTransport == .relaunch`), NOT a TUI keystroke. An idle Codex
/// card `send`-ed a message relaunches via `resumeInCard` with the inbox folded into the opening turn — the
/// same primitive Claude's no-wait wake uses (see `SendWakeTests` for the shared behaviour). The ONE
/// divergence from Claude (`nativeReinvoke`): a Codex card has no harness re-invoke, so `resumeSeedWake`
/// passes `watcherWillReinvoke: false` and it resumes **even when watching children**.
@Suite("F2 · Codex resume-seed wake (.relaunch)")
struct CodexWakeTests {

    /// Codex-shaped wake+drain (resume-seed + Stop hook), run over the StubAdapter's resume machinery so the
    /// transcript/resume-callback plumbing matches `SendWakeTests`.
    static let relaunchCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription)

    @Test("send resume-seeds an idle Codex card so the queued message lands now")
    func sendResumeSeedsIdleCodex() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)                                  // resumable
        try await env.svc.report(card.id, StatusReport(status: .waiting))                       // idle
        let name = env.sessions.sessionName(card.id)

        try await env.svc.send(card.id, "PING-CODEX")
        // The wake resume-seeds on a detached task; wait for the relaunch, then feed the resume callback.
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))

        let argv = try #require(env.sessions.ensureArgv[name])
        #expect(argv.contains("--resume"))                    // a resume relaunch, never a fresh start
        #expect(try #require(argv.last).contains("PING-CODEX"))   // the message rides the opening turn
        #expect(await env.svc.drainForStop(card.id) == nil)   // drained into the seed — no double-delivery
    }

    // The divergence from Claude: a WATCHING Codex card still resumes — there is no `orchestra wait`
    // re-invoke to defer to, so `watcherWillReinvoke: false`. (Compare `SendWakeTests.sendDefersPendingWatcher`.)
    @Test("send resume-seeds a WATCHING Codex card (Claude would defer)")
    func codexResumesEvenWhenWatching() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: parent.agentSessionId!)
        await env.svc.registerWatch(parent.id, [child.id])                    // parent has a live `orchestra wait`
        try await env.svc.report(parent.id, StatusReport(status: .waiting))   // idle, but watching
        let name = env.sessions.sessionName(parent.id)

        try await env.svc.send(parent.id, "POKE-CODEX")
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await env.svc.report(parent.id, StatusReport(sessionSource: "resume"))

        #expect(try #require(env.sessions.ensureArgv[name]).last?.contains("POKE-CODEX") == true)
    }

    @Test("send does NOT resume-seed a RUNNING Codex card (its Stop hook drains it at turn-end)")
    func codexDefersRunning() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        let ensureBefore = env.sessions.ensureCount

        try await env.svc.send(card.id, "later")
        try await _Concurrency.Task.sleep(for: .milliseconds(120))

        #expect(env.sessions.ensureCount == ensureBefore)                         // no relaunch
        #expect(env.sessions.killed.isEmpty)                                      // live turn untouched
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])    // durable → its Stop drains it
    }
}
