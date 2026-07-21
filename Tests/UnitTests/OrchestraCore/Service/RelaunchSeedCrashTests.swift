import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// B3 — the crash / provenance spine. Leases + watermarks are PERSISTED, so every crash test is a
/// `TestEnv.remake(base:)` reload asserting the reconciler converges from disk, and the provenance fence
/// is asserted to survive a daemon restart (a replayed pre-watermark line never confirms). Loss-shaped
/// assertions: a message is gone ONLY through a proven confirm; every crash ends in re-delivery/retention.
@Suite("B3 · relaunchSeed crash / provenance spine")
struct RelaunchSeedCrashTests {

    private static func makeDeadResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        _ branch: String = "b") async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("test_seedSurvivesCrashBeforeLaunch: a crash between the resume intent and launch loses nothing")
    func test_seedSurvivesCrashBeforeLaunch() async throws {
        let env = TestEnv.make(grace: 30)
        let t = try await Self.makeDeadResumable(env)
        try await env.svc.send(t.id, "durable-1")
        try await env.svc.send(t.id, "durable-2")

        // Resume intent recorded (.relaunching) — but CRASH before the stepper runs (no reconcile here).
        let intent = try await env.svc.resume(t.id)
        #expect(intent.phase.kind == .relaunching)
        #expect(try await env.svc.inboxPeek(t.id).count == 2)   // nothing drained by the intent

        // Fresh daemon: re-derive from disk. The RelaunchStepper claims the still-durable inbox + delivers it.
        let env2 = TestEnv.remake(base: env.base)
        _ = try await TestEnv.reconcileToLive(env2.svc, t.id)
        let argv = try #require(env2.sessions.ensureArgv[env2.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("durable-1") == true)
        #expect(argv.last?.contains("durable-2") == true)
    }

    @Test("test_daemonRestartReplayNeverConfirms: a persisted watermark survives remake; a pre-watermark replay never confirms")
    func test_daemonRestartReplayNeverConfirms() async throws {
        let env = TestEnv.make(grace: 5, capabilities: RelaunchSeedTests.codexStub)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "M")
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        _ = try #require(await env.svc.claimSeed(t.id, epoch: epoch))
        try await env.svc.inbox.setTailWatermark(cardId: t.id, epoch: epoch, watermark: 100, path: "/roll.jsonl")

        // Daemon restart: lease + watermark are on disk; the tailer re-reads the rollout from offset 0.
        let env2 = TestEnv.remake(base: env.base)
        #expect(try await env2.svc.inboxPeek(t.id).count == 1)   // the held lease reloaded
        // A replayed PRE-watermark line (below the persisted mark) must NEVER confirm.
        try await env2.svc.report(t.id, StatusReport(run: .running), tail: ("/roll.jsonl", 50))
        #expect(try await env2.svc.inboxPeek(t.id).count == 1)   // replay → retained, not falsely confirmed
        // A genuine post-watermark line confirms.
        try await env2.svc.report(t.id, StatusReport(run: .running), tail: ("/roll.jsonl", 150))
        #expect(try await env2.svc.inboxPeek(t.id).isEmpty)
    }

    @Test("test_restartBlankPreservesInbox: restart clears pendingSeed but the inbox survives and delivers")
    func test_restartBlankPreservesInbox() async throws {
        let env = TestEnv.make(grace: 5)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "survive-restart")

        let intent = try await env.svc.restart(t.id)   // pendingSeed = nil, but the inbox is UNTOUCHED
        #expect(intent.pendingSeed == nil)
        #expect(try await env.svc.inboxPeek(t.id).count == 1)   // messages NOT stranded by a blank restart

        _ = try await TestEnv.reconcileToLive(env.svc, t.id)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains { $0.contains("survive-restart") })   // delivered after the blank lands
    }

    @Test("test_unstampedTailNeverLandsRelaunchingLive (D7): an unstamped snapshot can't land a relaunching card live")
    func test_unstampedTailNeverLandsRelaunchingLive() async throws {
        let env = TestEnv.make(grace: 30, capabilities: RelaunchSeedTests.codexStub)
        let t = try await Self.makeDeadResumable(env)
        _ = try await env.svc.restart(t.id)   // .relaunching, provisional, pendingSeed/pendingModel nil (owesLaunch was false)
        #expect(await env.svc.store.get(t.id)?.phase.kind == .relaunching)

        // An UNSTAMPED (Codex file-tail) .running snapshot from the dying predecessor must NOT land it live.
        try await env.svc.report(t.id, StatusReport(run: .running))
        #expect(await env.svc.store.get(t.id)?.phase.kind == .relaunching)   // fence holds — still being born

        // A CURRENT-generation stamped report DOES land it (the legal .relaunching→.live edge).
        let e = try #require(await env.svc.store.get(t.id)).sessionEpoch
        try await env.svc.report(t.id, StatusReport(run: .running), observedEpoch: e)
        #expect(await env.svc.store.get(t.id)?.phase.kind == .live)
    }

    @Test("test_staleEpochSignalDoesNotResolveReadiness (D6): a stale-epoch resume hook can't confirm the new relaunch")
    func test_staleEpochSignalDoesNotResolveReadiness() async throws {
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)
        let t = try await Self.makeDeadResumable(env)
        _ = try await env.svc.resume(t.id)
        let ctx = await env.svc.convergeContext()
        let relaunching = try #require(await env.svc.store.get(t.id))
        async let stepping: Void = RelaunchStepper().step(relaunching, ctx)
        try await pollUntil { await env.svc.hasReadinessWaiter(t.id) }
        let epoch = relaunching.sessionEpoch

        // A STALE-epoch resume signal (the dying predecessor's) must NOT resolve the new waiter.
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"), observedEpoch: epoch - 1)
        await yieldBriefly()
        #expect(await env.svc.hasReadinessWaiter(t.id))   // still pending — stale signal ignored

        // The CURRENT-generation signal resolves it → live.
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"), observedEpoch: epoch)
        try await stepping
        #expect(await env.svc.store.get(t.id)?.phase.kind == .live)
    }
}
