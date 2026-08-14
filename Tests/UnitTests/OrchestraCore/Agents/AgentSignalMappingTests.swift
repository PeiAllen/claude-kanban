import Testing
@testable import OrchestraCore

@Suite("Adapter agent-signal mapping")
struct AgentSignalMappingTests {
    private let epoch = 17

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

        // Tool, permission, and child-task events are deliberately not top-level turn edges.
        for kind in ["pretool", "posttool", "notification", "taskcompleted", "permission"] {
            #expect(adapter.agentSignals(from: .hooksPush(kind: kind, payload: stop), context: context).isEmpty)
        }
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

    @Test("Codex status notifications reconcile only the turn dimension")
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
        ])) == [.init(sessionEpoch: epoch, kind: .turnReconciled(.running))])
        #expect(signals(.object(["type": .string("idle")]))
            == [.init(sessionEpoch: epoch, kind: .turnReconciled(.waiting()))])
        #expect(signals(.object(["type": .string("notLoaded")]))
            == [.init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable))])
        #expect(signals(.object(["type": .string("systemError")]))
            == [.init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable))])
    }

    @Test("Codex thread/read response supplies the one-time attach reconciliation")
    func codexThreadReadReconciliation() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")
        let result: JSONValue = .object([
            "thread": .object([
                "id": .string("thread-1"),
                "status": .object(["type": .string("idle")]),
            ]),
        ])

        #expect(adapter.agentSignals(
            from: .rpcResponse(method: "thread/read", result: result), context: context
        ) == [.init(sessionEpoch: epoch, kind: .turnReconciled(.waiting()))])
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
