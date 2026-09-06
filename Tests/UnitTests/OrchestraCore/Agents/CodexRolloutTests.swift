import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Codex model table — vendored offline (E1 denominator for B2)")
struct CodexModelTableTests {
    let adapter = CodexAdapter()

    @Test("retired GPT-5.5 resolves without a catalog context window")
    func retiredModelHasNoCatalogWindow() {
        let m = adapter.model(for: "gpt-5.5")
        #expect(m.id == "gpt-5.5")
        #expect(m.contextWindow == nil)
    }

    @Test("GPT-6 Astra is selectable with its published context and capabilities")
    func astraHasPublishedMetadata() throws {
        let model = try #require(adapter.models().first { $0.id == "gpt-6-astra" })
        #expect(adapter.models().first?.id == "gpt-6-astra")
        #expect(model.displayName == "GPT-6 Astra")
        #expect(model.family == "gpt")
        #expect(model.contextWindow == 1_050_000)
        #expect(model.flags == ModelFlags(toolCall: true, reasoning: true, vision: true))
    }

    @Test("unknown Codex model id falls back (no fabricated window)")
    func unknownFallsBack() {
        let m = adapter.model(for: "totally-made-up")
        #expect(m.id == "totally-made-up")
        #expect(m.contextWindow == nil)
    }

    @Test("table is loaded OFFLINE from the bundled local file (no network)")
    func offlineLocalResource() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-models", withExtension: "json"))
        #expect(url.isFileURL)
        #expect(!ModelCatalog.load("codex-models").isEmpty)
    }

    @Test("every table entry carries a positive context window")
    func populated() {
        #expect(adapter.models().allSatisfy { ($0.contextWindow ?? 0) > 0 })
    }
}

@Suite("Codex rollout parse — metadata only")
struct CodexRolloutParseTests {
    let a = CodexAdapter()

    private func tail(_ s: String) -> StatusReport? { a.parse(.fileTail(line: s)) }

    @Test("task_started is ignored because app-server owns turn state")
    func taskStartedIgnored() {
        #expect(tail(#"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#) == nil)
    }

    @Test("turn_complete is ignored because app-server owns turn state")
    func turnCompleteIgnored() {
        #expect(tail(#"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"turn_complete"}}"#) == nil)
    }

    @Test("token_count → ctxPct (tokens ÷ table window) + modelId")
    func tokenCountCtx() throws {
        // 262500 / 1050000 = 25%
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_token_usage":{"total_tokens":262500}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 25.0)
        #expect(r.snapshot?.modelId == "gpt-6-astra")
    }

    @Test("token_count without model uses last_token_usage over inline context window")
    func tokenCountWithoutModelUsesInlineWindow() throws {
        // Current Codex rollout lines can omit `model`; `total_token_usage` is session-cumulative,
        // while `last_token_usage` is the request that reflects the current context window.
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999999},"last_token_usage":{"total_tokens":105000},"model_context_window":1050000}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 10.0)
        #expect(r.snapshot?.modelId == nil)
    }

    @Test("test_ctxpct_from_model_table: ctxPct denominator is the OFFLINE model window, not the rollout's")
    func ctxPctFromModelTable() throws {
        // Rollout carries a bogus in-line window; parse must ignore it and use codex-models.json (372000).
        let line = #"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.6-sol","model_context_window":999,"total_token_usage":{"total_tokens":186000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 50.0)   // 186000 / 372000, NOT 186000/999
    }

    @Test("GPT-6 Astra token usage uses its catalog context window")
    func astraTokenUsageUsesCatalogWindow() throws {
        let line = #"{"timestamp":"2026-09-05T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","model_context_window":999,"total_token_usage":{"total_tokens":525000}}}}"#
        let report = try #require(tail(line))
        #expect(report.snapshot?.ctxPct == 50.0) // 525000 / 1050000, not 525000 / 999
        #expect(report.snapshot?.modelId == "gpt-6-astra")
    }

    @Test("function_call contributes description without turn state")
    func functionCallDesc() throws {
        let line = #"{"timestamp":"2026-07-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.desc == "Running shell")
    }

    @Test("old and new completion spellings are both ignored by the metadata parser")
    func completionRenameTolerance() {
        #expect(tail(#"{"type":"event_msg","payload":{"type":"TaskComplete"}}"#) == nil)
        #expect(tail(#"{"type":"event_msg","payload":{"type":"turn_complete"}}"#) == nil)
    }

    @Test("rename tolerance: total_token_usage.total_tokens AND a flat total_tokens both parse")
    func renameToleranceTokens() throws {
        let nested = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_token_usage":{"total_tokens":262500}}}}"#
        let flat   = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_tokens":262500}}}"#
        #expect(tail(nested)?.snapshot?.ctxPct == 25.0)
        #expect(tail(flat)?.snapshot?.ctxPct == 25.0)
    }

    @Test("seq-gate mapping: later timestamp → strictly larger seq")
    func seqFromTimestamp() throws {
        let t1 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#))
        let t2 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:06.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#))
        #expect((t2.snapshot?.seq ?? 0) > (t1.snapshot?.seq ?? 0))
    }

    @Test("session_meta is identity-silent; unhandled + junk lines drop to nil")
    func junkDropsNil() {
        #expect(tail("not json at all") == nil)
        #expect(tail("") == nil)
        #expect(tail(#"{"type":"session_meta","payload":{"id":"x"}}"#) == nil)
        #expect(tail(#"{"type":"unhandled","payload":{}}"#) == nil)
    }

    @Test("a nested Codex session_meta never binds the card session")
    func subagentSessionMetaDropsNil() {
        let nested = #"{"type":"session_meta","payload":{"id":"child","thread_source":"subagent","parent_thread_id":"root"}}"#
        #expect(tail(nested) == nil)
    }
}

@Suite("RolloutTailer — per-card byte-offset transport")
struct RolloutTailerTests {
    private func tmpFile() -> String {
        NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl"
    }
    private func append(_ path: String, _ text: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(Data(text.utf8)); try? fh.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test("first read returns all complete lines")
    func firstRead() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb\nc\n")
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: id, path: path).map(\.line) == ["a", "b", "c"])
    }

    @Test("second read returns only newly-appended lines")
    func incremental() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        append(path, "c\nd\n")
        #expect(await t.newLines(cardId: id, path: path).map(\.line) == ["c", "d"])
    }

    @Test("a trailing partial line is held until it is completed")
    func partialHeld() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb")                 // "b" has no newline yet
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: id, path: path).map(\.line) == ["a"])
        append(path, "bb\n")                 // completes -> "bbb"
        #expect(await t.newLines(cardId: id, path: path).map(\.line) == ["bbb"])
    }

    @Test("no new bytes → empty")
    func nothingNew() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        #expect(await t.newLines(cardId: id, path: path).isEmpty)
    }

    @Test("missing file → empty, no crash")
    func missingFile() async {
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: UUID(), path: "/no/such/rollout.jsonl").isEmpty)
    }

    @Test("truncation/rotation below offset resets to 0")
    func truncationResets() async {
        let path = tmpFile(); let id = UUID()
        append(path, "x\ny\nz\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        try? "n\n".write(toFile: path, atomically: true, encoding: .utf8)   // shorter file
        #expect(await t.newLines(cardId: id, path: path).map(\.line) == ["n"])
    }

    @Test("offsets are independent per card")
    func perCard() async {
        let path = tmpFile(); let a = UUID(); let b = UUID()
        append(path, "1\n2\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: a, path: path)
        #expect(await t.newLines(cardId: b, path: path).map(\.line) == ["1", "2"])   // b starts fresh
    }
}

@Suite("Codex telemetry e2e — tail → parse → report → board")
struct CodexTelemetryE2ETests {

    /// Spawn a Codex card, bind the id as its app-server would, then expose its matching rollout metadata.
    private func makeEnv() async throws -> (svc: OrchestraService, card: Task, rollout: String) {
        let base = NSTemporaryDirectory() + "codex-tel-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/01"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-01T10-00-00-\(sid).jsonl"

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"),
                                   proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
        async let spawned = TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "look", model: "gpt-6-astra",
                                                 agentId: "codex",
                                                 cwd: PathResolver.canonical(work)))
        try await TestEnv.reconcileUntilLive(svc, count: 1)
        let card = try await spawned
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        FileManager.default.createFile(atPath: rollout, contents: nil)
        append(rollout, #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(PathResolver.canonical(work))","timestamp":"\#(timestamp)"}}"#)
        try await svc.report(card.id, StatusReport(sessionId: sid))
        return (svc, try #require(await svc.store.get(card.id)), rollout)
    }

    private func makeMultiEnv(sameCwd: Bool = false) async throws -> (svc: OrchestraService, cardA: Task, rolloutA: String,
                                                                       cardB: Task, rolloutB: String) {
        let base = NSTemporaryDirectory() + "codex-tel-\(UUID().uuidString)"
        let workA = PathResolver.canonical(base + "/work-a")
        let workB = sameCwd ? workA : PathResolver.canonical(base + "/work-b")
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/01"
        try FileManager.default.createDirectory(atPath: workA, withIntermediateDirectories: true)
        if !sameCwd { try FileManager.default.createDirectory(atPath: workB, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)

        let sidA = UUID().uuidString.lowercased()
        let sidB = UUID().uuidString.lowercased()
        let rolloutA = "\(day)/rollout-2026-07-01T10-00-00-\(sidA).jsonl"
        let rolloutB = "\(day)/rollout-2026-07-01T10-01-00-\(sidB).jsonl"

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"),
                                   proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
        async let sa = TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "look a", model: "gpt-6-astra",
                                            agentId: "codex", cwd: workA))
        async let sb = TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "look b", model: "gpt-6-astra",
                                            agentId: "codex", cwd: workB))
        try await TestEnv.reconcileUntilLive(svc, count: 2)   // N=3 fallback: no metadata yet
        let cardA = try await sa
        let cardB = try await sb
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampA = formatter.string(from: Date())
        let timestampB = formatter.string(from: Date().addingTimeInterval(0.001))
        FileManager.default.createFile(atPath: rolloutA, contents: nil)
        FileManager.default.createFile(atPath: rolloutB, contents: nil)
        append(rolloutA, #"{"timestamp":"\#(timestampA)","type":"session_meta","payload":{"id":"\#(sidA)","cwd":"\#(workA)","timestamp":"\#(timestampA)","thread_source":"user"}}"#)
        append(rolloutB, #"{"timestamp":"\#(timestampB)","type":"session_meta","payload":{"id":"\#(sidB)","cwd":"\#(workB)","timestamp":"\#(timestampB)","thread_source":"user"}}"#)
        try await svc.report(cardA.id, StatusReport(sessionId: sidA))
        try await svc.report(cardB.id, StatusReport(sessionId: sidB))
        return (
            svc,
            try #require(await svc.store.get(cardA.id)), rolloutA,
            try #require(await svc.store.get(cardB.id)), rolloutB
        )
    }

    private func append(_ path: String, _ line: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile(); fh.write(Data((line + "\n").utf8)); try? fh.close()
    }

    @Test("pollTelemetry updates ctxPct without changing app-server turn status")
    func tailUpdatesBoard() async throws {
        let (svc, card, rollout) = try await makeEnv()
        await svc.pollTelemetry()
        try await pollUntil("missing app-server to make turn observation unavailable") {
            await svc.store.get(card.id)?.turnStatus == .unavailable
        }
        let before = try #require(await svc.list().first { $0.id == card.id }).turnStatus
        append(rollout, #"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#)
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_token_usage":{"total_tokens":262500}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 25.0)
        #expect(after.turnStatus == before)
    }

    @Test("pollTelemetry handles current Codex token_count without model id")
    func tailUpdatesBoardFromCurrentTokenShape() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999999},"last_token_usage":{"total_tokens":105000},"model_context_window":1050000}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 10.0)
    }

    @Test("legacy rollout TurnComplete no longer changes authoritative turn status")
    func legacyIdleIsIgnored() async throws {
        let (svc, card, rollout) = try await makeEnv()
        await svc.pollTelemetry()
        try await pollUntil("missing app-server to make turn observation unavailable") {
            await svc.store.get(card.id)?.turnStatus == .unavailable
        }
        let before = try #require(await svc.list().first { $0.id == card.id }).turnStatus
        append(rollout, #"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#)
        await svc.pollTelemetry()
        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.turnStatus == before)
    }

    @Test("seq-gate holds end-to-end: a stale (earlier-timestamp) ctx line can't overwrite a fresher one")
    func seqGateHoldsE2E() async throws {
        let (svc, card, rollout) = try await makeEnv()
        // Fresh ctx first (later ts, 50%), then a STALE ctx (earlier ts, 10%) appended after.
        append(rollout, #"{"timestamp":"2026-07-01T10:00:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_token_usage":{"total_tokens":525000}}}}"#)
        await svc.pollTelemetry()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-6-astra","total_token_usage":{"total_tokens":105000}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 50.0)   // the stale 10% snapshot was dropped by the seq-gate
    }

    @Test("multiple Codex cards keep independent rollout status and description")
    func multipleCardsDoNotShareNewestRolloutStatus() async throws {
        let (svc, cardA, rolloutA, cardB, rolloutB) = try await makeMultiEnv(sameCwd: true)
        append(rolloutA, #"{"timestamp":"2026-07-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"older_tool"}}"#)
        append(rolloutB, #"{"timestamp":"2026-07-01T10:01:03.000Z","type":"response_item","payload":{"type":"function_call","name":"newer_tool"}}"#)

        await svc.pollTelemetry()

        let afterA = try #require(await svc.list().first { $0.id == cardA.id })
        let afterB = try #require(await svc.list().first { $0.id == cardB.id })
        #expect(afterA.agentSessionId != afterB.agentSessionId)
        #expect(afterA.desc == "Running older_tool")
        #expect(afterB.desc == "Running newer_tool")
    }

    @Test("a Claude (hooksPush) card is NOT tailed by pollTelemetry")
    func claudeNotTailed() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.pollTelemetry()   // must be a no-op for hooksPush; no crash, no change
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.phase == t.phase)
    }
}

/// B3 — the tail-watermark fence compares the rollout path captured in `finishLaunch` against the one
/// `pollTelemetry` later tails. Those are two INDEPENDENT `sessionInfo(...).transcriptPath` resolutions
/// built from differently-shaped `AdapterContext`s, so their agreement is load-bearing: if they ever
/// diverge for the same session, every held-relaunch confirm silently degrades to lease-expiry
/// re-delivery. The existing wrong-path test only proves the NEGATIVE; this pins the positive.
@Suite("B3 · rollout path fidelity — capture path == poll path")
struct RolloutPathFidelityTests {

    @Test("finishLaunch's resume context and pollTelemetry's context resolve the SAME rollout path")
    func captureAndPollResolveSamePath() throws {
        let base = NSTemporaryDirectory() + "pathfid-\(UUID().uuidString)"
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/19"
        let cwd = PathResolver.canonical(base + "/work")
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-19T10-00-00-\(sid).jsonl"
        FileManager.default.createFile(atPath: rollout, contents:
            Data((#"{"timestamp":"2026-07-19T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(cwd)","timestamp":"2026-07-19T10:00:00.000Z"}}"# + "\n").utf8))

        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)

        // The context finishLaunch builds for a `.resume` bring-up (seed + trust + launch flags).
        let captureCtx = AdapterContext(cwd: cwd, model: "gpt-6-astra", sessionId: sid, name: "Card",
                                        trustCwd: true, seed: "SEED")
        // The context pollTelemetry builds each tick (no seed/trust; may carry a discovery cutoff).
        let pollCtx = AdapterContext(cwd: cwd, model: "gpt-6-astra", sessionId: sid, name: "Card")

        let capturePath = codex.sessionInfo(captureCtx, current: sid, prior: [])?.transcriptPath
        let pollPath = codex.sessionInfo(pollCtx, current: sid, prior: [])?.transcriptPath
        #expect(capturePath != nil)
        #expect(capturePath == pollPath)      // the fence can only match if these agree
        #expect(capturePath == rollout)
    }
}
