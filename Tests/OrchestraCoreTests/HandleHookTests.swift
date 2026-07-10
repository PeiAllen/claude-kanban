import Testing
import Foundation
@testable import OrchestraCore

@Suite struct HandleHookTests {
    @Test("sessionStart returns the live orientation; compact skips it")
    func sessionStart() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
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
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        try await svc.send(card.id, "queued message")

        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil)
        #expect(r?.continuation?.contains("queued message") == true)
        #expect(r?.additionalContext == nil)
    }

    @Test("stop with an empty inbox yields no continuation")
    func stopEmpty() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil)
        #expect(r == nil)
    }

    @Test("a telemetry event applies its report to the store and returns no response")
    func telemetry() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "Task", repo: TestEnv.repo(base), branch: "b"))

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
