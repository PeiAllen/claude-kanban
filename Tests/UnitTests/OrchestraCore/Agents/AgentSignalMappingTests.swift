import Testing
@testable import OrchestraCore

@Suite("Adapter agent-signal mapping")
struct AgentSignalMappingTests {
    private let epoch = 17

    @Test("hook observation payloads retain signal fields without forwarding large tool bodies")
    func hookObservationPayloads() {
        let claude = ClaudeCodeAdapter()
        let tool: JSONValue = .object([
            "session_id": .string("claude-session"),
            "tool_name": .string("Write"),
            "tool_input": .object(["content": .string(String(repeating: "x", count: 1_000))]),
        ])
        #expect(claude.hookObservationPayload(event: .preToolUse, payload: tool)
            == .object(["session_id": .string("claude-session")]))

        let permission: JSONValue = .object([
            "session_id": .string("claude-session"),
            "notification_type": .string("permission_prompt"),
            "tool_use_id": .string("tool-1"),
            "message": .string("Allow Write?"),
            "irrelevant": .string(String(repeating: "y", count: 1_000)),
        ])
        #expect(claude.hookObservationPayload(event: .notification, payload: permission)
            == .object([
                "session_id": .string("claude-session"),
                "notification_type": .string("permission_prompt"),
                "tool_use_id": .string("tool-1"),
                "message": .string("Allow Write?"),
            ]))
        #expect(claude.hookObservationPayload(event: .statusLine, payload: permission) == nil)

        let codex = CodexAdapter()
        #expect(codex.hookObservationPayload(event: .permission, payload: permission)
            == .object([
                "session_id": .string("claude-session"),
                "tool_use_id": .string("tool-1"),
                "message": .string("Allow Write?"),
            ]))
        #expect(codex.hookObservationPayload(event: .stop, payload: permission) == nil)
    }

    @Test("Claude prompt and Stop hooks map only top-level turn edges")
    func claudeHookTurnEdges() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        let prompt: JSONValue = .object([
            "session_id": .string("claude-session"),
            "prompt": .string("continue"),
        ])
        #expect(adapter.agentSignals(from: .hooksPush(kind: "prompt", payload: prompt), context: context)
            == [.init(sessionEpoch: epoch, kind: .turnStarted)])

        let stop: JSONValue = .object([
            "session_id": .string("claude-session"),
            "background_tasks": .array([]),
            "session_crons": .array([]),
        ])
        #expect(adapter.agentSignals(from: .hooksPush(kind: "stop", payload: stop), context: context)
            == [.init(sessionEpoch: epoch, kind: .turnCompleted())])

        // A tool edge can clear a resolved request, but never changes the top-level turn.
        for kind in ["pretool", "posttool"] {
            #expect(adapter.agentSignals(from: .hooksPush(kind: kind, payload: stop), context: context)
                == [.init(sessionEpoch: epoch, kind: .requests([]))])
        }
        for kind in ["notification", "taskcompleted", "permission"] {
            #expect(adapter.agentSignals(from: .hooksPush(kind: kind, payload: stop), context: context).isEmpty)
        }

        let permission: JSONValue = .object([
            "session_id": .string("claude-session"),
            "notification_type": .string("permission_prompt"),
            "message": .string("Allow Bash?"),
        ])
        #expect(adapter.agentSignals(
            from: .hooksPush(kind: "notification", payload: permission), context: context
        ) == [.init(sessionEpoch: epoch, kind: .requests([
            .init(id: "permission", kind: .permission, prompt: "Allow Bash?")
        ]))])
    }

    @Test("Claude Stop aggregates every currently-known automatic-resume source")
    func claudeAutomaticResume() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        for resumeField in ["background_tasks", "session_crons"] {
            let stop: JSONValue = .object([
                "session_id": .string("claude-session"),
                resumeField: .array([.object(["id": .string("resume-1")])]),
            ])
            #expect(adapter.agentSignals(from: .hooksPush(kind: "stop", payload: stop), context: context)
                == [.init(sessionEpoch: epoch, kind: .turnCompleted(resume: .init()))])
        }
    }

    @Test("Claude interaction-span completion closes an interrupted turn")
    func claudeInteractionSpanCompletion() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        #expect(adapter.agentSignals(
            from: .traceSpanEnded(name: "claude_code.interaction", attributes: .object([:])),
            context: context
        ) == [.init(sessionEpoch: epoch, kind: .turnCompleted())])
        #expect(adapter.agentSignals(
            from: .traceSpanEnded(name: "claude_code.tool", attributes: .object([:])),
            context: context
        ).isEmpty)
    }

    @Test("Claude drops hook observations from another harness session")
    func claudeSessionIdentityFence() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "current")
        let stale: JSONValue = .object(["session_id": .string("superseded")])

        #expect(adapter.agentSignals(from: .hooksPush(kind: "prompt", payload: stale), context: context).isEmpty)
        #expect(adapter.agentSignals(from: .hooksPush(kind: "stop", payload: stale), context: context).isEmpty)
    }

    @Test("Codex turn notifications map to the shared turn edges")
    func codexTurnNotifications() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")
        let params: JSONValue = .object([
            "threadId": .string("thread-1"),
            "turn": .object(["id": .string("turn-1")]),
        ])

        #expect(adapter.agentSignals(
            from: .rpcNotification(method: "turn/started", params: params), context: context
        ) == [.init(sessionEpoch: epoch, kind: .turnStarted)])
        #expect(adapter.agentSignals(
            from: .rpcNotification(method: "turn/completed", params: params), context: context
        ) == [.init(sessionEpoch: epoch, kind: .turnCompleted())])
    }

    @Test("Codex status notifications reconcile turn and request dimensions independently")
    func codexStatusNotifications() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")

        func signals(_ status: JSONValue) -> [AgentSignal] {
            adapter.agentSignals(
                from: .rpcNotification(
                    method: "thread/status/changed",
                    params: .object(["threadId": .string("thread-1"), "status": status])
                ),
                context: context
            )
        }

        #expect(signals(.object([
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval"), .string("waitingOnUserInput")]),
        ])) == [
            .init(sessionEpoch: epoch, kind: .turnReconciled(.running)),
            .init(sessionEpoch: epoch, kind: .requests([
                .init(id: "permission", kind: .permission),
                .init(id: "input", kind: .input),
            ])),
        ])
        #expect(signals(.object(["type": .string("idle")]))
            == [
                .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting())),
                .init(sessionEpoch: epoch, kind: .requests([])),
            ])
        #expect(signals(.object(["type": .string("notLoaded")]))
            == [.init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable))])
        #expect(signals(.object(["type": .string("systemError")]))
            == [.init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable))])
    }

    @Test("Codex subscribe/read responses supply one-time attach reconciliation")
    func codexThreadReadReconciliation() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")
        let result: JSONValue = .object([
            "thread": .object([
                "id": .string("thread-1"),
                "status": .object(["type": .string("idle")]),
            ]),
        ])

        for method in ["thread/resume", "thread/read"] {
            #expect(adapter.agentSignals(
                from: .rpcResponse(method: method, result: result), context: context
            ) == [
                .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting())),
                .init(sessionEpoch: epoch, kind: .requests([])),
            ])
        }
    }

    @Test("Codex requires the observer's exact thread identity")
    func codexThreadIdentityFence() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")
        let other: JSONValue = .object([
            "threadId": .string("thread-2"),
            "status": .object(["type": .string("idle")]),
        ])

        #expect(adapter.agentSignals(
            from: .rpcNotification(method: "thread/status/changed", params: other), context: context
        ).isEmpty)
        #expect(adapter.agentSignals(
            from: .rpcNotification(method: "turn/started", params: other), context: context
        ).isEmpty)
    }
}
