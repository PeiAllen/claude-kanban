import Foundation
import Testing
@testable import OrchestraCore

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
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .rolloutMeta)

    // MARK: - Claude (.sessionStartHook)

    @Test("test_launchingToLive_onReady[claude]: SessionStart(startup) drives the blank spawn to live")
    func test_launchingToLive_onReady_claude() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)   // sessionStartHook → blank spawn awaits
        let repo = TestEnv.repo(env.base)

        async let spawned = env.svc.spawn(SpawnInput(prompt: "do it", repo: repo, branch: "b"))
        // The card is walked to `.launching`, where its inline readiness waiter blocks (no signal yet).
        try await pollUntil {
            await env.svc.list().contains { $0.branch == "b" && $0.phase.kind == .launching }
        }
        let cardId = try #require(await env.svc.list().first { $0.branch == "b" }?.id)
        // The launch's ready signal: SessionStart(startup). It resolves the waiter → the verb lands `.live`.
        try await env.svc.report(cardId, StatusReport(sessionSource: "startup"))
        let live = try await spawned
        #expect(live.phase == .live(.running))   // a prompt was in flight → running (per the landing rule)
    }

    @Test("test_relaunchingToLive_onReady[claude]: SessionStart(resume) drives the resume to live")
    func test_relaunchingToLive_onReady_claude() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)

        async let resumed = env.svc.resume(t.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))   // the relaunch's ready signal
        let live = try await resumed
        #expect(live.phase == .live(.waiting(.humanTurn)))
        #expect(live.deadReason == nil)
    }

    // MARK: - Codex (.rolloutMeta)

    @Test("test_launchingToLive_onReady[codex]: rollout session_meta (mtime > phaseChangedAt) drives launch to live")
    func test_launchingToLive_onReady_codex() async throws {
        let base = NSTemporaryDirectory() + "rdy-codex-\(UUID().uuidString)"
        let work = PathResolver.canonical(base + "/work")
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/09"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], revivalGraceSeconds: 30)
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"))

        async let spawned = svc.spawn(SpawnInput(prompt: "look", model: "gpt-5.3-codex",
                                                 agentId: "codex", cwd: work))
        // Wait until the card is `.launching` (its readiness waiter is registered), THEN write the fresh
        // rollout — its session_meta has mtime "now" > the card's `phaseChangedAt`, so the launch bind adopts
        // exactly this rollout (never a stale/foreign one).
        try await pollUntil { await svc.list().contains { $0.phase.kind == .launching } }
        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-09T10-00-00-\(sid).jsonl"
        FileManager.default.createFile(atPath: rollout, contents:
            Data((#"{"timestamp":"2026-07-09T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(work)"}}"# + "\n").utf8))

        await svc.pollTelemetry()   // tails session_meta → report(sessionId) → launching → resolveReadiness → live
        let live = try await spawned
        #expect(live.phase.kind == .live)
        #expect(live.agentSessionId == sid)   // bound from the rollout the launch just wrote
    }

    @Test("test_relaunchingToLive_fallback[codex]: resume writes no rollout → N=3 liveness fallback drives it live")
    func test_relaunchingToLive_fallback_codex() async throws {
        let env = TestEnv.make(grace: 30, capabilities: Self.codexStubCaps)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)                  // resumable
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)

        // `.rolloutMeta` relaunch inline-awaits — but a `codex resume` emits NO rollout, so NO signal is
        // hand-delivered here. The N=3 liveness-tick fallback (session live + pending waiter) must resolve
        // it within the grace, so the card reaches live rather than timing out and being killed.
        async let resumed = env.svc.resume(t.id)
        try await pollUntil {
            await env.svc.reconcileLiveness()
            return (await env.svc.list().first { $0.id == t.id })?.phase.kind == .live
        }
        let live = try await resumed
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

        async let spawned = env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await TestEnv.reconcileUntilLive(env.svc, count: 1)   // reconcile ticks → N=3 → resolveReadiness → live
        let live = try await spawned
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

        func writeRollout(_ sid: String, ts: String, mtime: Date) {
            let path = "\(day)/rollout-\(ts)-\(sid).jsonl"
            FileManager.default.createFile(atPath: path, contents:
                Data((#"{"timestamp":"2026-07-09T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(cwd)"}}"# + "\n").utf8))
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }

        let launchAt = Date(timeIntervalSince1970: 10_000)

        // Stale pre-reboot rollout only (mtime < launch): a relaunching card must NOT adopt its own stale
        // rollout — the time-scoped bind refuses it (fallback carries readiness).
        let staleSid = UUID().uuidString.lowercased()
        writeRollout(staleSid, ts: "2026-07-09T09-00-00", mtime: launchAt.addingTimeInterval(-3600))
        #expect(codex.discover(cwd: cwd, newerThan: launchAt) == nil)
        #expect(codex.discover(cwd: cwd, newerThan: nil) == staleSid)   // unscoped legacy path still finds it

        // Add a LIVE SIBLING's actively-written rollout in the SAME cwd (co-located cards). Now TWO rollouts
        // are newer than launch → ambiguous → bind nothing: the launching card must not adopt the sibling's.
        let ownSid = UUID().uuidString.lowercased()
        let sibSid = UUID().uuidString.lowercased()
        writeRollout(ownSid, ts: "2026-07-09T10-00-00", mtime: launchAt.addingTimeInterval(30))
        writeRollout(sibSid, ts: "2026-07-09T10-05-00", mtime: launchAt.addingTimeInterval(60))
        #expect(codex.discover(cwd: cwd, newerThan: launchAt) == nil)   // ambiguous → nothing (never the sibling)
    }
}
