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
