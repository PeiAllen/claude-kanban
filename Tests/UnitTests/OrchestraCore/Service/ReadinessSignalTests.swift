import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// 2.6 — the capability-gated READINESS signal that drives `launching → live` AND `relaunching → live`
/// for BOTH agents. A being-born card's inline `awaitReadiness` waiter is resolved by the agent's own
/// ready signal (Claude SessionStart(startup/resume); Codex rollout `session_meta`) or, when no signal
/// comes (Codex `codex resume` writes no rollout; a missed hook), by the universal N=3 liveness-tick
/// fallback within the grace window. Strictly capability-gated — no `if agentId ==`.
@Suite("2.6 · capability-gated readiness → live (claude + codex)")
struct ReadinessSignalTests {

    /// A Codex-shaped `.rolloutMeta` stub (seeded so the StubAdapter's transcript resume works; `hooksPush`
    /// so `pollTelemetry` leaves it alone). Exercises the rolloutMeta RELAUNCH fallback generically.
    static let codexStubCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .tokens,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .rolloutMeta)

    // MARK: - Claude (.sessionStartHook)

    @Test("test_launchingToLive_onReady[claude]: SessionStart(startup) drives the blank spawn to live")
    func test_launchingToLive_onReady_claude() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)   // sessionStartHook → blank spawn awaits
        let repo = TestEnv.repo(env.base)

        // Non-blocking spawn: the reconciler drives the card to `.launching`, where its readiness waiter
        // blocks; spawnAwaited hand-delivers SessionStart(startup), which resolves it → the card lands `.live`.
        let live = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "do it", repo: repo, branch: "b"))
        #expect(live.phase == .live(.init(turnStatus: .unavailable)))   // readiness proves liveness, not provider turn state
    }

    @Test("test_relaunchingToLive_onReady[claude]: SessionStart(resume) drives the resume to live")
    func test_relaunchingToLive_onReady_claude() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)

        // Intent-only: resume records `.relaunching`; the RelaunchStepper brings the session up and its
        // readiness waiter is resolved by the delivered SessionStart(resume) (inject) → `.live`.
        _ = try await env.svc.resume(t.id)
        let live = try await TestEnv.reconcileToLive(env.svc, t.id, inject: true)
        #expect(live.phase == .live(.init(turnStatus: .unavailable)))
        #expect(live.deadReason == nil)
    }

    // MARK: - Codex (.rolloutMeta)

    @Test("test_launchingToLive_onReady[codex]: rollout metadata newer than phaseChangedAt drives launch to live")
    func test_launchingToLive_onReady_codex() async throws {
        let base = NSTemporaryDirectory() + "rdy-codex-\(UUID().uuidString)"
        let work = PathResolver.canonical(base + "/work")
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/09"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], revivalGraceSeconds: 30, sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"),
                                   proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })

        let created = try await svc.spawn(SpawnInput(id: UUID(), prompt: "look", model: "gpt-5.5",
                                                     agentId: "codex", cwd: work))
        // Non-blocking spawn: drive the reconciler ONLY until the card is `.launching` (its readiness waiter
        // registers), then STOP reconciling so the N=3 fallback can't fire — the rollout's session_meta is the
        // resolver we want to exercise. Its immutable metadata birth time is after `phaseChangedAt`, so the
        // launch bind adopts exactly this rollout (never a stale/foreign one).
        try await pollUntil {
            await svc.reconcile()
            return await svc.list().first { $0.id == created.id }?.phase.kind == .launching
        }
        // The MaterializeStepper can publish `.launching` just before its own in-flight claim is released,
        // so keep reconciling until the subsequent LaunchStepper has registered its waiter. Stop immediately
        // once it does; this still leaves the metadata signal, rather than N=3, as the resolver under test.
        try await pollUntil("readiness waiter registered") {
            await svc.reconcile()
            return await svc.hasReadinessWaiter(created.id)
        }
        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-09T10-00-00-\(sid).jsonl"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(1))
        FileManager.default.createFile(atPath: rollout, contents:
            Data((#"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(work)","timestamp":"\#(timestamp)"}}"# + "\n").utf8))

        await svc.pollTelemetry()   // tails session_meta → report(sessionId) → launching → resolveReadiness → live
        try await pollUntil { await svc.list().first { $0.id == created.id }?.phase.kind == .live }   // no reconcile → no N=3
        let live = try #require(await svc.list().first { $0.id == created.id })
        #expect(live.phase.kind == .live)
        #expect(live.agentSessionId == sid)   // bound from the rollout the launch just wrote
    }

    @Test("test_codexFallbackKeepsLaunchCutoff: delayed fresh rollout binds without adopting stale history")
    func test_codexFallbackKeepsLaunchCutoff() async throws {
        let base = NSTemporaryDirectory() + "rdy-codex-delayed-\(UUID().uuidString)"
        let work = PathResolver.canonical(base + "/work")
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/09"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], revivalGraceSeconds: 30, sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"),
                                   proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func writeRollout(_ sid: String, timestamp: Date) {
            let startedAt = formatter.string(from: timestamp)
            let path = "\(day)/rollout-\(startedAt)-\(sid).jsonl"
            FileManager.default.createFile(atPath: path, contents:
                Data((#"{"timestamp":"\#(startedAt)","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(work)","timestamp":"\#(startedAt)"}}"# + "\n").utf8))
        }

        // This old rollout can still be written after the launch starts, so its metadata birth time, not
        // its file mtime, must keep it out of the new card's discovery set.
        writeRollout(UUID().uuidString.lowercased(), timestamp: Date(timeIntervalSince1970: 1))
        let created = try await svc.spawn(SpawnInput(id: UUID(), prompt: "look", model: "gpt-5.5",
                                                     agentId: "codex", cwd: work))
        try await TestEnv.reconcileUntilLive(svc, count: 1)   // N=3 fallback: no fresh metadata yet
        let afterFallback = try #require(await svc.list().first { $0.id == created.id })
        #expect(afterFallback.agentSessionId == nil)
        let cutoff = try #require(afterFallback.sessionDiscoverySince)
        let restored = try #require(await TaskStore(path: base + "/tasks.json").load().first { $0.id == created.id })
        let persistedCutoff = try #require(restored.sessionDiscoverySince)
        #expect(abs(persistedCutoff.timeIntervalSince(cutoff)) < 0.000_001)   // durable across a daemon restart

        let fresh = UUID().uuidString.lowercased()
        writeRollout(fresh, timestamp: cutoff.addingTimeInterval(60))
        await svc.pollTelemetry()

        let bound = try #require(await svc.list().first { $0.id == created.id })
        #expect(bound.agentSessionId == fresh)
        #expect(bound.sessionDiscoverySince == nil)
    }

    @Test("test_relaunchingToLive_fallback[codex]: resume writes no rollout → N=3 liveness fallback drives it live")
    func test_relaunchingToLive_fallback_codex() async throws {
        let env = TestEnv.make(grace: 30, capabilities: Self.codexStubCaps)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)                  // resumable
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)

        // `.rolloutMeta` relaunch inline-awaits — but a `codex resume` emits NO rollout, so NO signal is
        // hand-delivered here. The N=3 liveness-tick fallback (session live + pending waiter) must resolve
        // it within the grace, so the card reaches live rather than timing out and being killed.
        // Intent-only: resume records `.relaunching`; the RelaunchStepper brings the session up and — since a
        // `codex resume` emits NO rollout — the reconciler's N=3 liveness fallback (NO signal injected) must
        // resolve the waiter within the grace so the card reaches live rather than timing out.
        _ = try await env.svc.resume(t.id)
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(live.phase.kind == .live)
        #expect(live.deadReason == nil)
    }

    // MARK: - Universal N=3 fallback (any capability)

    @Test("test_launchingToLive_fallback: no signal → N=3 liveness ticks drive launch to live (N×tick < timeout)")
    func test_launchingToLive_fallback() async throws {
        let env = TestEnv.make(grace: 30, capabilities: .claudeCode)   // awaits; no startup hook delivered
        let repo = TestEnv.repo(env.base)
        let n = await env.svc.launchReadyTickThreshold
        #expect(n * 2 < 30)   // N × tickInterval(2s poll) < sessionLaunchTimeout(grace) — fallback beats the timeout

        _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await TestEnv.reconcileUntilLive(env.svc, count: 1)   // reconcile ticks → N=3 → resolveReadiness → live
        let live = try #require(await env.svc.list().first { $0.branch == "b" })
        #expect(live.phase.kind == .live)
        #expect(live.deadReason == nil)
    }

    // MARK: - Time-scoped rollout binding

    @Test("test_codexRolloutBindingIsTimeScoped: no live-sibling adopt, no stale pre-reboot adopt")
    func test_codexRolloutBindingIsTimeScoped() throws {
        let base = NSTemporaryDirectory() + "rdy-bind-\(UUID().uuidString)"
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/09"
        let cwd = PathResolver.canonical(base + "/work")
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)

        func writeRollout(_ sid: String, ts: String, startedAt: String) {
            let path = "\(day)/rollout-\(ts)-\(sid).jsonl"
            FileManager.default.createFile(atPath: path, contents:
                Data((#"{"timestamp":"\#(startedAt)","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(cwd)","timestamp":"\#(startedAt)"}}"# + "\n").utf8))
        }

        let launchAt = Date(timeIntervalSince1970: 10_000)

        // Stale pre-reboot rollout only (metadata birth before launch): a relaunching card must NOT adopt
        // its own stale rollout — the time-scoped bind refuses it (fallback carries readiness).
        let staleSid = UUID().uuidString.lowercased()
        writeRollout(staleSid, ts: "2026-07-09T09-00-00", startedAt: "1970-01-01T01:46:40Z")
        #expect(codex.discover(cwd: cwd, newerThan: launchAt) == nil)
        #expect(codex.discover(cwd: cwd, newerThan: nil) == staleSid)   // unscoped legacy path still finds it

        // Add a LIVE SIBLING's actively-written rollout in the SAME cwd (co-located cards). Now TWO rollouts
        // are newer than launch → ambiguous → bind nothing: the launching card must not adopt the sibling's.
        let ownSid = UUID().uuidString.lowercased()
        let sibSid = UUID().uuidString.lowercased()
        writeRollout(ownSid, ts: "2026-07-09T10-00-00", startedAt: "1970-01-01T02:47:10Z")
        writeRollout(sibSid, ts: "2026-07-09T10-05-00", startedAt: "1970-01-01T02:47:40Z")
        #expect(codex.discover(cwd: cwd, newerThan: launchAt) == nil)   // ambiguous → nothing (never the sibling)
    }
}
