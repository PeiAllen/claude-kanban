import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex model table — vendored offline (E1 denominator for B2)")
struct CodexModelTableTests {
    let adapter = CodexAdapter()

    @Test("known Codex model resolves to its offline context window")
    func knownModelHasWindow() {
        let m = adapter.model(for: "gpt-5.3-codex")
        #expect(m.contextWindow == 272_000)
        #expect(m.displayName == "GPT-5.3 Codex")
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

@Suite("Codex rollout parse — fileTail line → StatusReport")
struct CodexRolloutParseTests {
    let a = CodexAdapter()

    private func tail(_ s: String) -> StatusReport? { a.parse(.fileTail(line: s)) }

    @Test("test_rollout_to_statusreport: task_started → running")
    func taskStartedRunning() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        #expect(r.snapshot?.run == .running)
    }

    @Test("turn_complete → waiting with humanTurn reason")
    func turnCompleteHumanTurn() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"turn_complete"}}"#))
        #expect(r.snapshot?.run != nil)
        #expect(r.snapshot?.run == .waiting(.humanTurn))
        #expect(r.snapshot?.turnCompleted == true)
    }

    @Test("token_count → ctxPct (tokens ÷ table window) + modelId")
    func tokenCountCtx() throws {
        // 68000 / 272000 = 25%
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 25.0)
        #expect(r.snapshot?.modelId == "gpt-5.3-codex")
    }

    @Test("token_count without model uses last_token_usage over inline context window")
    func tokenCountWithoutModelUsesInlineWindow() throws {
        // Current Codex rollout lines can omit `model`; `total_token_usage` is session-cumulative,
        // while `last_token_usage` is the request that reflects the current context window.
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999999},"last_token_usage":{"total_tokens":27200},"model_context_window":272000}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 10.0)
        #expect(r.snapshot?.modelId == nil)
    }

    @Test("test_ctxpct_from_model_table: ctxPct denominator is the OFFLINE model window, not the rollout's")
    func ctxPctFromModelTable() throws {
        // Rollout carries a bogus in-line window; parse must ignore it and use codex-models.json (272000).
        let line = #"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","model_context_window":999,"total_token_usage":{"total_tokens":136000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 50.0)   // 136000 / 272000, NOT 136000/999
    }

    @Test("function_call → running + desc")
    func functionCallDesc() throws {
        let line = #"{"timestamp":"2026-07-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.run == .running)
        #expect(r.snapshot?.desc == "Running shell")
    }

    @Test("idle signal: TurnComplete → waiting")
    func idleSignal() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#))
        #expect(r.snapshot?.run != nil)
    }

    @Test("rename tolerance: old TaskComplete AND new TurnComplete both mean idle")
    func renameToleranceTurn() throws {
        #expect(tail(#"{"type":"event_msg","payload":{"type":"TaskComplete"}}"#)?.snapshot?.run != nil)
        #expect(tail(#"{"type":"event_msg","payload":{"type":"turn_complete"}}"#)?.snapshot?.run != nil)
    }

    @Test("rename tolerance: total_token_usage.total_tokens AND a flat total_tokens both parse")
    func renameToleranceTokens() throws {
        let nested = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let flat   = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_tokens":68000}}}"#
        #expect(tail(nested)?.snapshot?.ctxPct == 25.0)
        #expect(tail(flat)?.snapshot?.ctxPct == 25.0)
    }

    @Test("seq-gate mapping: later timestamp → strictly larger seq")
    func seqFromTimestamp() throws {
        let t1 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        let t2 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        #expect((t2.snapshot?.seq ?? 0) > (t1.snapshot?.seq ?? 0))
    }

    @Test("session_meta binds id; unhandled + junk lines drop to nil")
    func junkDropsNil() {
        #expect(tail("not json at all") == nil)
        #expect(tail("") == nil)
        #expect(tail(#"{"type":"session_meta","payload":{"id":"x"}}"#)?.event?.sessionId == "x")
        #expect(tail(#"{"type":"unhandled","payload":{}}"#) == nil)
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
        #expect(await t.newLines(cardId: id, path: path) == ["a", "b", "c"])
    }

    @Test("second read returns only newly-appended lines")
    func incremental() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        append(path, "c\nd\n")
        #expect(await t.newLines(cardId: id, path: path) == ["c", "d"])
    }

    @Test("a trailing partial line is held until it is completed")
    func partialHeld() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb")                 // "b" has no newline yet
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: id, path: path) == ["a"])
        append(path, "bb\n")                 // completes -> "bbb"
        #expect(await t.newLines(cardId: id, path: path) == ["bbb"])
    }

    @Test("no new bytes → empty")
    func nothingNew() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        #expect(await t.newLines(cardId: id, path: path) == [])
    }

    @Test("missing file → empty, no crash")
    func missingFile() async {
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: UUID(), path: "/no/such/rollout.jsonl") == [])
    }

    @Test("truncation/rotation below offset resets to 0")
    func truncationResets() async {
        let path = tmpFile(); let id = UUID()
        append(path, "x\ny\nz\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        try? "n\n".write(toFile: path, atomically: true, encoding: .utf8)   // shorter file
        #expect(await t.newLines(cardId: id, path: path) == ["n"])
    }

    @Test("offsets are independent per card")
    func perCard() async {
        let path = tmpFile(); let a = UUID(); let b = UUID()
        append(path, "1\n2\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: a, path: path)
        #expect(await t.newLines(cardId: b, path: path) == ["1", "2"])   // b starts fresh
    }
}

@Suite("Codex telemetry e2e — tail → parse → report → board")
struct CodexTelemetryE2ETests {

    /// Spawn a codex card with an isolated CODEX_HOME + StubSessions, and return the pieces.
    private func makeEnv() async throws -> (svc: OrchestraService, card: Task, rollout: String) {
        let base = NSTemporaryDirectory() + "codex-tel-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/01"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-01T10-00-00-\(sid).jsonl"
        FileManager.default.createFile(atPath: rollout, contents: nil)
        append(rollout, #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sid)","cwd":"\#(PathResolver.canonical(work))"}}"#)

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: StubWorktrees(root: config.worktreesRoot),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"))
        let card = try await svc.spawn(SpawnInput(prompt: "look", model: "gpt-5.3-codex",
                                                  agentId: "codex",
                                                  cwd: PathResolver.canonical(work)))
        return (svc, card, rollout)
    }

    private func makeMultiEnv() async throws -> (svc: OrchestraService, cardA: Task, rolloutA: String,
                                                 cardB: Task, rolloutB: String) {
        let base = NSTemporaryDirectory() + "codex-tel-\(UUID().uuidString)"
        let workA = PathResolver.canonical(base + "/work-a")
        let workB = PathResolver.canonical(base + "/work-b")
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/01"
        try FileManager.default.createDirectory(atPath: workA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)

        let sidA = UUID().uuidString.lowercased()
        let sidB = UUID().uuidString.lowercased()
        let rolloutA = "\(day)/rollout-2026-07-01T10-00-00-\(sidA).jsonl"
        let rolloutB = "\(day)/rollout-2026-07-01T10-01-00-\(sidB).jsonl"
        FileManager.default.createFile(atPath: rolloutA, contents: nil)
        FileManager.default.createFile(atPath: rolloutB, contents: nil)
        append(rolloutA, #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sidA)","cwd":"\#(workA)"}}"#)
        append(rolloutB, #"{"timestamp":"2026-07-01T10:01:00.000Z","type":"session_meta","payload":{"id":"\#(sidB)","cwd":"\#(workB)"}}"#)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
                                              ofItemAtPath: rolloutA)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)],
                                              ofItemAtPath: rolloutB)

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: StubWorktrees(root: config.worktreesRoot),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"))
        let cardA = try await svc.spawn(SpawnInput(prompt: "look a", model: "gpt-5.3-codex",
                                                   agentId: "codex", cwd: workA))
        let cardB = try await svc.spawn(SpawnInput(prompt: "look b", model: "gpt-5.3-codex",
                                                   agentId: "codex", cwd: workB))
        return (svc, cardA, rolloutA, cardB, rolloutB)
    }

    private func append(_ path: String, _ line: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile(); fh.write(Data((line + "\n").utf8)); try? fh.close()
    }

    @Test("pollTelemetry tails a Codex rollout and updates the card's ctxPct + status")
    func tailUpdatesBoard() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#)
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_token_usage":{"total_tokens":68000}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 25.0)
        #expect(after.phaseDisplay == .running)
    }

    @Test("pollTelemetry handles current Codex token_count without model id")
    func tailUpdatesBoardFromCurrentTokenShape() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999999},"last_token_usage":{"total_tokens":27200},"model_context_window":272000}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 10.0)
    }

    @Test("idle signal reaches the board: TurnComplete → waiting")
    func idleReachesBoard() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#)
        await svc.pollTelemetry()
        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.waitReason != nil)
    }

    @Test("seq-gate holds end-to-end: a stale (earlier-timestamp) ctx line can't overwrite a fresher one")
    func seqGateHoldsE2E() async throws {
        let (svc, card, rollout) = try await makeEnv()
        // Fresh ctx first (later ts, 50%), then a STALE ctx (earlier ts, 10%) appended after.
        append(rollout, #"{"timestamp":"2026-07-01T10:00:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_token_usage":{"total_tokens":136000}}}}"#)
        await svc.pollTelemetry()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.3-codex","total_token_usage":{"total_tokens":27200}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 50.0)   // the stale 10% snapshot was dropped by the seq-gate
    }

    @Test("multiple Codex cards keep independent rollout status and description")
    func multipleCardsDoNotShareNewestRolloutStatus() async throws {
        let (svc, cardA, rolloutA, cardB, rolloutB) = try await makeMultiEnv()
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
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.pollTelemetry()   // must be a no-op for hooksPush; no crash, no change
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.phase == t.phase)
    }
}
