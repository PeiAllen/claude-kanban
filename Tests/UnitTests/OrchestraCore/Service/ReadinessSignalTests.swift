import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Capability-gated readiness drives both being-born phases. SessionStart confirms launch/resume for
/// adapters that expose it; the universal N=3 liveness fallback covers a missed provider signal.
@Suite("2.6 · capability-gated readiness → live")
struct ReadinessSignalTests {
    /// Stub-friendly Codex shape: seeded identity keeps transcript fixtures simple while SessionStart
    /// exercises the same readiness contract as the production adapter.
    static let codexStubCaps = AgentCapabilities(
        sessionId: .seeded,
        telemetry: .hooksPush,
        contextUsage: .tokens,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription,
        readinessConfirmation: .sessionStartHook
    )

    @Test("SessionStart(startup) drives a blank launch to live")
    func launchingToLiveOnReady() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)

        let live = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "do it", repo: repo, branch: "b")
        )

        #expect(live.phase == .live(.init(turnStatus: .unavailable)))
    }

    @Test("SessionStart(resume) drives a relaunch to live")
    func relaunchingToLiveOnReady() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b")
        )
        env.adapter.writeTranscript(for: card.agentSessionId!)
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)

        _ = try await env.svc.resume(card.id)
        let live = try await TestEnv.reconcileToLive(env.svc, card.id, inject: true)

        #expect(live.phase == .live(.init(turnStatus: .unavailable)))
        #expect(live.deadReason == nil)
    }

    @Test("missing readiness signal falls back after bounded live-session ticks")
    func launchingToLiveFallback() async throws {
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let threshold = await env.svc.launchReadyTickThreshold
        #expect(threshold * 2 < 30)

        _ = try await env.svc.spawn(
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b")
        )
        try await TestEnv.reconcileUntilLive(env.svc, count: 1)
        let live = try #require(await env.svc.list().first { $0.branch == "b" })

        #expect(live.phase.kind == .live)
        #expect(live.deadReason == nil)
    }
}
