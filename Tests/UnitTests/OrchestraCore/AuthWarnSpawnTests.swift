import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("authMode soft-warn on spawn — advisory only, never caps")
struct AuthWarnSpawnTests {

    static let apiKeyCaps = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        readOnlyEnforcement: .sandboxed, authMode: .apiKey,
        readinessConfirmation: .relaunchLiveness)   // setup spawns land immediately (not a readiness test)

    @Test("spawning past the default threshold emits a .warning activity; the spawn still succeeds (no cap)")
    func warnsPastThresholdAndStillSpawns() async throws {
        // Default StubAdapter caps = .claudeCode → subscription; default threshold = 3, so the 4th warns.
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        var tasks: [Task] = []
        for i in 0..<4 { tasks.append(try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p\(i)", repo: repo, branch: "b\(i)"))) }

        // No cap: all four cards were created and launched.
        #expect(tasks.count == 4)
        #expect(env.sessions.ensureArgv.count == 4)

        // Poll for the (async) warning fan-out, then settle and assert exactly one fired (only the 4th spawn).
        try await pollUntil("subscription warning delivered") {
            await collector.activities.contains { $0.kind == .warning }
        }
        await yieldBriefly()
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.count == 1)
        #expect(warnings.first?.text.contains("subscription") == true)
    }

    @Test("no warning at or below the threshold")
    func silentUnderThreshold() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        for i in 0..<3 { _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p\(i)", repo: repo, branch: "b\(i)")) }

        await yieldBriefly()   // negative: let a wrongful warning's fan-out land before asserting none did
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.isEmpty)
    }

    @Test("apiKey adapter never warns, even for a big fan-out")
    func apiKeyNeverWarns() async throws {
        let env = TestEnv.make(capabilities: Self.apiKeyCaps)   // single adapter, apiKey
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        for i in 0..<6 { _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p\(i)", repo: repo, branch: "b\(i)")) }

        await yieldBriefly()   // negative: let a wrongful warning's fan-out land before asserting none did
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.isEmpty)
    }
}
