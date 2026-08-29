import Foundation
import Testing
@testable import OrchestraCore

@Suite("Adapter telemetry parse — per-adapter ownership + Claude byte-identity + board round-trip")
struct ParseTests {

    // I12 — parse is the ADAPTER's, not a core function: the same raw goes to different adapters
    // and yields different results; a Claude adapter cannot produce a fileTail (Codex-shaped) report.
    @Test("adapter owns parse: same raw, different adapters → different reports")
    func test_adapter_owns_parse() throws {
        // Claude has no fileTail transport → nil for a tailed line.
        #expect(ClaudeCodeAdapter().parse(.fileTail(line: #"{"usage":123}"#)) == nil)

        // A tail-shaped stub parses the SAME raw into a report the Claude adapter can't produce.
        let tailCaps = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .relaunch, inboxDrain: .stopHook,
            readOnlyEnforcement: .sandboxed, authMode: .subscription)
        let stub = StubAdapter(transcriptDir: NSTemporaryDirectory(), capabilities: tailCaps)
        #expect(stub.parse(.fileTail(line: "hello")) == StatusReport(desc: "tail:hello"))
    }

    @Test("Claude hook parsing extracts metadata without duplicating agent state")
    func test_claude_metadata_parse() throws {
        let a = ClaudeCodeAdapter()

        let tool = try JSONValue.parse(Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/Foo.swift"}}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "pretool", payload: tool))
                == StatusReport(desc: "Editing Foo.swift"))

        let bash = try JSONValue.parse(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls -la"}}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "posttool", payload: bash))
                == StatusReport(desc: "Running: ls -la"))

        let notify = try JSONValue.parse(Data(#"{"message":"done"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "notification", payload: notify))
                == StatusReport(desc: "done"))
        #expect(a.parse(.hooksPush(kind: "stop", payload: notify)) == nil)
        #expect(a.parse(.hooksPush(kind: "taskcompleted", payload: notify)) == nil)

        let prompt = try JSONValue.parse(Data(#"{"prompt":"hi there"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "prompt", payload: prompt))
                == StatusReport(promptText: "hi there"))

        let session = try JSONValue.parse(Data(#"{"session_id":"sid","source":"resume"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "session", payload: session))
                == StatusReport(sessionId: "sid", sessionSource: "resume"))

        // sessionend: transition reasons (clear/resume/compact) drop to nil; genuine exit carries.
        let clear = try JSONValue.parse(Data(#"{"reason":"clear"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "sessionend", payload: clear)) == nil)
        let exit = try JSONValue.parse(Data(#"{"reason":"exit","session_id":"sid"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "sessionend", payload: exit))
                == StatusReport(sessionId: "sid", endReason: "exit"))

        // statusline: seq is a live timestamp → assert the parsed fields, not the whole struct.
        let sl = try JSONValue.parse(Data(#"""
        {"session_id":"sid","context_window":{"used_percentage":42.0},
         "model":{"id":"m","display_name":"M"},"session_name":"Card"}
        """#.utf8))
        let r = try #require(a.parse(.hooksPush(kind: "statusline", payload: sl)))
        #expect(r.snapshot?.ctxPct == 42)
        #expect(r.snapshot?.modelId == "m")
        #expect(r.snapshot?.modelDisplay == "M")
        #expect(r.snapshot?.sessionName == "Card")
        #expect((r.snapshot?.seq ?? 0) > 0)
        #expect(r.event?.sessionId == "sid")

        // Unknown kind → nil (unchanged default branch).
        #expect(a.parse(.hooksPush(kind: "bogus", payload: .object([:]))) == nil)
    }

    // I14 / spawn→telemetry→board — a parse-produced StatusReport reaches service.report and updates
    // the board (proves the transport→parse→merge path end to end, using the real Claude parse).
    @Test("spawn → ClaudeCodeAdapter.parse(raw) → service.report → board card updates")
    func test_parse_report_reaches_board() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "Task", repo: repo, branch: "b"))

        let raw = RawTelemetry.hooksPush(
            kind: "posttool",
            payload: try JSONValue.parse(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
        let report = try #require(ClaudeCodeAdapter().parse(raw))
        try await env.svc.report(t.id, report)

        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.desc == "Running: ls")
        #expect(after.phaseDisplay == .running)
    }

    @Test("Claude PermissionRequest maps to an independent permission request")
    func test_claude_permission_path() throws {
        let payload = try JSONValue.parse(Data(#"{"prompt_id":"p1","tool_name":"Bash"}"#.utf8))
        let signals = ClaudeCodeAdapter().agentSignals(
            from: .hooksPush(kind: "permission", payload: payload),
            context: .init(sessionEpoch: 1, harnessSessionId: nil)
        )
        #expect(signals == [.init(
            sessionEpoch: 1,
            turnID: "p1",
            kind: .requests([.init(id: "permission:p1", kind: .permission)])
        )])
    }
}
