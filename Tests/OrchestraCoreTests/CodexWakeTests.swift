import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// F2 · Codex wakes by **resume-seed** (`wakeTransport == .relaunch`), NOT a TUI keystroke. An idle Codex
/// card `send`-ed a message relaunches via `resumeInCard` with the inbox folded into the opening turn — the
/// same primitive Claude's no-wait wake uses (see `SendWakeTests` for the shared behaviour). The ONE
/// divergence from Claude (`nativeReinvoke`): a Codex card has no harness re-invoke, so `resumeSeedWake`
/// passes `watcherWillReinvoke: false` and it resumes **even when watching children**.
@Suite("F2 · Codex resume-seed wake (.relaunch)")
struct CodexWakeTests {

    /// Codex-shaped wake+drain (resume-seed + Stop hook), run over the StubAdapter's resume machinery so the
    /// transcript/resume-callback plumbing matches `SendWakeTests`.
    /// Codex-shaped wake+drain over the StubAdapter's SEEDED resume machinery (so the transcript/resume-
    /// callback plumbing matches `SendWakeTests`). `.relaunchLiveness` readiness so the setup spawn + the
    /// wake's resume both land immediately (this suite drives wake/seed delivery, not the awaited signal).
    static let relaunchCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .relaunchLiveness)

    /// The `.relaunchLiveness` confirmation shape with `fileTail` telemetry — the agent emits NO marker on a
    /// relaunch, so the live relaunch itself must confirm the wake (else every idle wake times out and kills
    /// the card). `.relaunchLiveness` remains a valid capability value in 2.6 (Codex's own relaunch now
    /// rides `.rolloutMeta` + the N=3 fallback — see `ReadinessSignalTests.test_relaunchingToLive_fallback`).
    static let realCodexCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .relaunchLiveness)

    @Test("send resume-seeds an idle Codex card so the queued message lands now")
    func sendResumeSeedsIdleCodex() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)                                  // resumable
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))                       // idle
        let name = env.sessions.sessionName(card.id)

        try await env.svc.send(card.id, "PING-CODEX")
        // The wake resume-seeds `.relaunching`; the reconciler's RelaunchStepper brings up the resume session.
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[name]?.contains("--resume") == true
        }
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
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: parent.agentSessionId!)
        await env.svc.registerWatch(parent.id, [child.id])                    // parent has a durable watch
        try await env.svc.report(parent.id, StatusReport(run: .waiting(.humanTurn)))   // idle, but watching
        let name = env.sessions.sessionName(parent.id)

        try await env.svc.send(parent.id, "POKE-CODEX")
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[name]?.contains("--resume") == true
        }
        try await env.svc.report(parent.id, StatusReport(sessionSource: "resume"))

        #expect(try #require(env.sessions.ensureArgv[name]).last?.contains("POKE-CODEX") == true)
    }

    @Test("MCP wait also returns immediately for a Codex watcher")
    func mcpWaitRegistersAndReturnsImmediatelyForCodex() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let cmd = try #require(CommandRegistry().command("wait"))

        let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await cmd.run(env.svc, .object([
                    "refs": .array([.string(child.id.uuidString)]),
                    "watcher": .string(parent.id.uuidString),
                ]), .mcp)
            }
            group.addTask {
                // yield-based failure backstop: fires only if `wait` wrongly PARKS on the child's
                // conclusion instead of registering-and-returning (the child never concludes here)
                try await pollUntil("MCP wait returns without parking", timeout: .seconds(60)) { false }
                throw OrchestraError.invalidParams("MCP wait did not return immediately")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        #expect(result["watching"]?.boolValue == true)
        #expect(await env.svc.activeWaitSubscriptionCount() == 0)
    }

    @Test("send does NOT resume-seed a RUNNING Codex card (its Stop hook drains it at turn-end)")
    func codexDefersRunning() async throws {
        let env = TestEnv.make(grace: 2, capabilities: Self.relaunchCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        let ensureBefore = env.sessions.ensureCount

        try await env.svc.send(card.id, "later")
        await yieldBriefly()   // negative: a wrongful wake's detached resume-seed gets its chance to run

        #expect(env.sessions.ensureCount == ensureBefore)                         // no relaunch
        #expect(env.sessions.killed.isEmpty)                                      // live turn untouched
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])    // durable → its Stop drains it
    }

    /// Regression (the fatal Codex symptom): a `send` to an idle Codex card KILLED it — `resume()` waited
    /// `revivalGraceSeconds` for a `sessionSource=="resume"` hook that `codex resume` never emits, then
    /// `failResume` → `.dead(resumeFailed)`. With `.relaunchLiveness` the live relaunch confirms, so the card
    /// stays alive. This drives the REAL confirmation path — NO hand-injected `sessionSource:"resume"`.
    @Test("send wakes an idle Codex card with NO resume hook — the live relaunch confirms; card stays alive")
    func codexWakeConfirmsOnRelaunchLiveness() async throws {
        // The service clock is a TestClock: the revival-grace watchdog parks on it, so "waiting past
        // the grace" is a deterministic `advance`, not a 1.3s wall sleep.
        let clock = TestClock()
        let env = TestEnv.make(grace: 1, capabilities: Self.realCodexCaps, clock: clock)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)                                  // resumable
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))                       // idle
        let name = env.sessions.sessionName(card.id)

        try await env.svc.send(card.id, "PING-CODEX")
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[name]?.contains("--resume") == true
        }     // relaunched
        // First let the live relaunch CONFIRM readiness (before the fix, this confirmation never came
        // and the grace watchdog would kill the card — that regression shows up here as a PollTimeout).
        try await pollUntil("the live relaunch confirms and the card leaves .relaunching") {
            await env.svc.reconcile()
            let t = await env.svc.list().first { $0.id == card.id }
            return t?.phase.kind == .live
        }
        // Then jump PAST the grace: the parked watchdog fires and must be a stale no-op — before the
        // fix it fired `markDead(resumeFailed)` here.
        await clock.parked(1, deadlineAtLeast: .milliseconds(500))
        clock.advance(by: .seconds(2))
        await env.svc.reconcile()

        let after = try #require(await env.svc.list().first { $0.id == card.id })
        #expect(after.waitReason != nil)                     // alive — NOT .dead(resumeFailed)
        #expect(after.phaseDisplay != .dead)
        #expect(after.deadReason == nil)
        #expect(try #require(env.sessions.ensureArgv[name]).last?.contains("PING-CODEX") == true)  // seed rode in
    }
}
