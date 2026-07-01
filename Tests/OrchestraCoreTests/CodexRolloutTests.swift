import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex model table — vendored offline (E1 denominator for B2)")
struct CodexModelTableTests {
    let adapter = CodexAdapter()

    @Test("known Codex model resolves to its offline context window")
    func knownModelHasWindow() {
        let m = adapter.model(for: "gpt-5-codex")
        #expect(m.contextWindow == 272_000)
        #expect(m.displayName == "GPT-5 Codex")
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
        #expect(r.snapshot?.status == .running)
    }

    @Test("token_count → ctxPct (tokens ÷ table window) + modelId")
    func tokenCountCtx() throws {
        // 68000 / 272000 = 25%
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 25.0)
        #expect(r.snapshot?.modelId == "gpt-5-codex")
    }

    @Test("test_ctxpct_from_model_table: ctxPct denominator is the OFFLINE model window, not the rollout's")
    func ctxPctFromModelTable() throws {
        // Rollout carries a bogus in-line window; parse must ignore it and use codex-models.json (272000).
        let line = #"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","model_context_window":999,"total_token_usage":{"total_tokens":136000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 50.0)   // 136000 / 272000, NOT 136000/999
    }

    @Test("function_call → running + desc")
    func functionCallDesc() throws {
        let line = #"{"timestamp":"2026-07-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.status == .running)
        #expect(r.snapshot?.desc == "Running shell")
    }

    @Test("idle signal: TurnComplete → waiting")
    func idleSignal() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#))
        #expect(r.snapshot?.status == .waiting)
    }

    @Test("rename tolerance: old TaskComplete AND new TurnComplete both mean idle")
    func renameToleranceTurn() throws {
        #expect(tail(#"{"type":"event_msg","payload":{"type":"TaskComplete"}}"#)?.snapshot?.status == .waiting)
        #expect(tail(#"{"type":"event_msg","payload":{"type":"turn_complete"}}"#)?.snapshot?.status == .waiting)
    }

    @Test("rename tolerance: total_token_usage.total_tokens AND a flat total_tokens both parse")
    func renameToleranceTokens() throws {
        let nested = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let flat   = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_tokens":68000}}}"#
        #expect(tail(nested)?.snapshot?.ctxPct == 25.0)
        #expect(tail(flat)?.snapshot?.ctxPct == 25.0)
    }

    @Test("seq-gate mapping: later timestamp → strictly larger seq")
    func seqFromTimestamp() throws {
        let t1 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        let t2 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        #expect((t2.snapshot?.seq ?? 0) > (t1.snapshot?.seq ?? 0))
    }

    @Test("unhandled + junk lines drop to nil")
    func junkDropsNil() {
        #expect(tail("not json at all") == nil)
        #expect(tail("") == nil)
        #expect(tail(#"{"type":"session_meta","payload":{"id":"x"}}"#) == nil)
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
