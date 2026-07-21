import Testing
import Foundation
@testable import OrchestraCore

@Suite struct HandleHookTests {
    @Test("sessionStart returns the live orientation; compact skips it")
    func sessionStart() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let ref = card.id.uuidString

        let r = await svc.handleHook(ref, event: .sessionStart, report: nil, source: .startup)
        #expect(r?.additionalContext?.contains(card.shortId) == true)
        #expect(r?.continuation == nil)

        let compact = await svc.handleHook(ref, event: .sessionStart, report: nil, source: .compact)
        #expect(compact == nil)   // don't re-orient mid-turn
    }

    @Test("stop drains the inbox into the continuation")
    func stop() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let epoch = try #require(await svc.store.get(card.id)).sessionEpoch   // the fence reads sessionEpoch
        try await svc.send(card.id, "queued message")

        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil, observedEpoch: epoch)
        #expect(r?.continuation?.contains("queued message") == true)
        #expect(r?.additionalContext == nil)
    }

    /// MAJOR (final-review): a REAL Claude Stop carries a `waiting(.humanTurn)` report, and `handleHook`
    /// must claim the stopDrain BEFORE applying that report — else the report's `.live(.waiting)` landing
    /// fires wake-on-live, which cold-relaunches a `nativeReinvoke` card with no active wait (bumping the
    /// epoch), so `payloadForStop`'s fence then fails and a HEALTHY session is needlessly restarted on
    /// every send. This asserts the busy card DRAINS via stopDrain with no epoch bump / no relaunch. The
    /// old `stop` test passed `report: nil`, so it never exercised this.
    @Test("a Stop carrying a real waiting report drains via stopDrain — no cold relaunch")
    func stopWithWaitingReportDrainsNotRelaunch() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)   // resumable — the state a cold relaunch needs
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        try await env.svc.send(card.id, "DRAIN-ME")              // queued; a running card doesn't wake, so it waits for the Stop
        let ensureBefore = env.sessions.ensureCount

        // The ACTUAL Claude Stop: the stop event PLUS a report that lands waiting(.humanTurn).
        let r = await env.svc.handleHook(card.id.uuidString, event: .stop,
                                         report: StatusReport(run: .waiting(.humanTurn)),
                                         source: nil, observedEpoch: epoch, stopHookActive: false)

        #expect(r?.continuation?.contains("DRAIN-ME") == true)                       // drained via stopDrain
        #expect(try #require(await env.svc.store.get(card.id)).sessionEpoch == epoch) // NO epoch bump
        #expect(env.sessions.ensureCount == ensureBefore)                            // session NOT restarted
        #expect(env.sessions.ensureArgv[env.sessions.sessionName(card.id)]?.contains("--resume") != true)
    }

    @Test("stop with an empty inbox yields no continuation")
    func stopEmpty() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let epoch = try #require(await svc.store.get(card.id)).sessionEpoch
        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil, observedEpoch: epoch)
        #expect(r == nil)   // nil from an empty inbox (matching epoch), not from the fence
    }

    @Test("a telemetry event applies its report to the store and returns no response")
    func telemetry() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))

        let r = await svc.handleHook(card.id.uuidString, event: .postToolUse,
                                     report: StatusReport(desc: "Running: ls", run: .waiting(.humanTurn)), source: nil)
        #expect(r == nil)
        let after = try await svc.resolveRef(card.id.uuidString)
        #expect(after.waitReason != nil)   // the report landed
    }

    @Test("unknown ref returns nil, never throws")
    func unknownRef() async {
        let (svc, _, _, _, _, _) = TestEnv.make()
        let r = await svc.handleHook("no-such-card", event: .stop, report: nil, source: nil)
        #expect(r == nil)
    }
}
