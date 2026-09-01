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
            "prompt_id": .string("prompt-1"),
            "tool_name": .string("Write"),
            "tool_input": .object(["content": .string(String(repeating: "x", count: 1_000))]),
        ])
        #expect(claude.hookObservationPayload(event: .preToolUse, payload: tool)
            == .object([
                "session_id": .string("claude-session"),
                "prompt_id": .string("prompt-1"),
                "tool_name": .string("Write"),
            ]))

        let permission: JSONValue = .object([
            "session_id": .string("claude-session"),
            "prompt_id": .string("prompt-1"),
            "tool_name": .string("Bash"),
            "notification_type": .string("permission_prompt"),
            "tool_use_id": .string("tool-1"),
            "message": .string("Allow Write?"),
            "irrelevant": .string(String(repeating: "y", count: 1_000)),
        ])
        #expect(claude.hookObservationPayload(event: .permission, payload: permission)
            == .object([
                "session_id": .string("claude-session"),
                "prompt_id": .string("prompt-1"),
                "tool_name": .string("Bash"),
            ]))
        #expect(claude.hookObservationPayload(event: .notification, payload: permission) == nil)
        #expect(claude.hookObservationPayload(event: .statusLine, payload: permission) == nil)

        let codex = CodexAdapter()
        #expect(codex.hookObservationPayload(event: .permission, payload: permission) == nil)
        #expect(codex.hookObservationPayload(event: .stop, payload: permission) == nil)
    }

    @Test("Claude prompt and Stop hooks map correlated turn edges and clear human need")
    func claudeHookTurnEdges() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        let prompt: JSONValue = .object([
            "session_id": .string("claude-session"),
            "prompt_id": .string("prompt-1"),
            "prompt": .string("continue"),
        ])
        #expect(adapter.agentSignals(from: .hooksPush(kind: "prompt", payload: prompt), context: context)
            == [.init(sessionEpoch: epoch, turnID: "prompt-1", kind: .turnStarted)])

        let stop: JSONValue = .object([
            "session_id": .string("claude-session"),
            "prompt_id": .string("prompt-1"),
            "background_tasks": .array([]),
            "session_crons": .array([]),
        ])
        #expect(adapter.agentSignals(from: .hooksPush(kind: "stop", payload: stop), context: context)
            == [
                .init(sessionEpoch: epoch, turnID: "prompt-1", kind: .turnCompleted()),
                .init(sessionEpoch: epoch, turnID: "prompt-1", kind: .humanNeedChanged(nil)),
            ])

        #expect(adapter.agentSignals(from: .hooksPush(kind: "pretool", payload: stop), context: context).isEmpty)
        // A completed or failed tool can clear a resolved human need, but never changes the top-level turn.
        for kind in ["posttool", "posttoolfailure"] {
            #expect(adapter.agentSignals(from: .hooksPush(kind: kind, payload: stop), context: context)
                == [.init(sessionEpoch: epoch, turnID: "prompt-1", kind: .humanNeedChanged(nil))])
        }
        for kind in ["notification", "taskcompleted"] {
            #expect(adapter.agentSignals(from: .hooksPush(kind: kind, payload: stop), context: context).isEmpty)
        }

        let permission: JSONValue = .object([
            "session_id": .string("claude-session"),
            "prompt_id": .string("prompt-1"),
            "tool_name": .string("Bash"),
        ])
        #expect(adapter.agentSignals(
            from: .hooksPush(kind: "permission", payload: permission), context: context
        ) == [.init(sessionEpoch: epoch, turnID: "prompt-1", kind: .humanNeedChanged(.permission))])
    }

    @Test("Claude interaction tools map to input human need without becoming permissions")
    func claudeInputRequests() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        for hook in ["permission", "pretool"] {
            for tool in ["AskUserQuestion", "ExitPlanMode"] {
                let payload: JSONValue = .object([
                    "session_id": .string("claude-session"),
                    "prompt_id": .string("prompt-2"),
                    "tool_name": .string(tool),
                ])
                #expect(adapter.agentSignals(
                    from: .hooksPush(kind: hook, payload: payload), context: context
                ) == [.init(sessionEpoch: epoch, turnID: "prompt-2", kind: .humanNeedChanged(.input))])
            }
        }
    }

    @Test("Claude Stop aggregates every currently-known automatic-resume source")
    func claudeAutomaticResume() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        for resumeField in ["background_tasks", "session_crons"] {
            let stop: JSONValue = .object([
                "session_id": .string("claude-session"),
                "prompt_id": .string("prompt-1"),
                resumeField: .array([.object(["id": .string("resume-1")])]),
            ])
            #expect(adapter.agentSignals(from: .hooksPush(kind: "stop", payload: stop), context: context)
                == [
                    .init(sessionEpoch: epoch, turnID: "prompt-1", kind: .turnCompleted(resume: .init())),
                    .init(sessionEpoch: epoch, turnID: "prompt-1", kind: .humanNeedChanged(nil)),
                ])
        }
    }

    @Test("Claude rejects an interaction-span completion without prompt identity")
    func claudeInteractionSpanWithoutPromptIdentity() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        #expect(adapter.agentSignals(
            from: .traceSpanEnded(name: "claude_code.interaction", attributes: .object([
                "session.id": .string("claude-session"),
            ])),
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
        ) == [.init(sessionEpoch: epoch, turnID: "turn-1", kind: .turnStarted)])
        #expect(adapter.agentSignals(
            from: .rpcNotification(method: "turn/completed", params: params), context: context
        ) == [.init(sessionEpoch: epoch, turnID: "turn-1", kind: .turnCompleted())])
    }

    @Test("Codex current-thread malformed completion loses observation through the coordinator")
    func codexMalformedCompletionLosesObservation() async {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")

        for turn in [
            JSONValue.object([:]),
            .object(["id": .string("")]),
        ] {
            let coordinator = AgentObservationCoordinator()
            let state = MappedAgentState()
            let signals = adapter.agentSignals(
                from: .rpcNotification(
                    method: "turn/completed",
                    params: .object(["threadId": .string("thread-1"), "turn": turn])
                ),
                context: context
            )

            #expect(signals == [.init(sessionEpoch: epoch, kind: .turnCompleted())])
            await coordinator.submit(
                scope: context,
                signals: [.init(sessionEpoch: epoch, turnID: "turn-1", kind: .turnStarted)]
            ) { await state.apply($0, epoch: epoch) }
            await coordinator.submit(scope: context, signals: signals) {
                await state.apply($0, epoch: epoch)
            }

            #expect(await state.snapshot() == AgentState(turnStatus: .unavailable))
        }
    }

    @Test("Codex hooks do not compete with app-server agent state")
    func codexHooksAreStateSilent() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")
        for kind in ["permission", "stop", "session"] {
            #expect(adapter.agentSignals(
                from: .hooksPush(kind: kind, payload: .object([:])), context: context
            ).isEmpty)
        }
    }

    @Test("Codex status notifications atomically reconcile turn and human-needed dimensions")
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
            .init(sessionEpoch: epoch, kind: .turnReconciled(.running, humanNeed: .unspecified)),
        ])
        #expect(signals(.object(["type": .string("idle")]))
            == [
                .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting(), humanNeed: nil)),
            ])
        #expect(signals(.object(["type": .string("notLoaded")]))
            == [.init(sessionEpoch: epoch, kind: .observationLost)])
        #expect(signals(.object(["type": .string("systemError")]))
            == [.init(sessionEpoch: epoch, kind: .observationLost)])
    }

    @Test("Codex status snapshots atomically map every human-need flag combination")
    func codexHumanNeedSnapshots() {
        let adapter = CodexAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "thread-1")

        func signals(_ flags: [String]) -> [AgentSignal] {
            adapter.agentSignals(
                from: .rpcNotification(
                    method: "thread/status/changed",
                    params: .object([
                        "threadId": .string("thread-1"),
                        "status": .object([
                            "type": .string("active"),
                            "activeFlags": .array(flags.map(JSONValue.string)),
                        ]),
                    ])
                ),
                context: context
            )
        }

        for (flags, need) in [
            ([], nil),
            (["waitingOnApproval"], .permission),
            (["waitingOnUserInput"], .input),
            (["waitingOnApproval", "waitingOnUserInput"], .unspecified),
        ] as [([String], ProviderHumanNeed?)] {
            #expect(signals(flags) == [
                .init(sessionEpoch: epoch, kind: .turnReconciled(.running, humanNeed: need)),
            ])
        }
    }

    @Test("Claude maps known and ambiguous prompt requirements without changing turn state")
    func claudeHumanNeedMappings() {
        let adapter = ClaudeCodeAdapter()
        let context = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "claude-session")

        for (tool, need) in [
            ("Bash", .permission),
            ("AskUserQuestion", .input),
            ("", .unspecified),
        ] as [(String, ProviderHumanNeed)] {
            let payload: JSONValue = .object([
                "session_id": .string("claude-session"),
                "prompt_id": .string("prompt-1"),
                "tool_name": .string(tool),
            ])
            #expect(adapter.agentSignals(
                from: .hooksPush(kind: "permission", payload: payload), context: context
            ) == [
                .init(sessionEpoch: epoch, turnID: "prompt-1", kind: .humanNeedChanged(need)),
            ])
        }
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
                .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting(), humanNeed: nil)),
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
        #expect(adapter.agentSignals(
            from: .rpcNotification(
                method: "turn/completed",
                params: .object(["threadId": .string("thread-2"), "turn": .object([:])])
            ),
            context: context
        ).isEmpty)
    }
}

private actor MappedAgentState {
    private var state = AgentState(turnStatus: .unavailable)

    func apply(_ signals: [AgentSignal], epoch: Int) {
        for signal in signals {
            _ = AgentStateReducer.apply(signal, to: &state, currentSessionEpoch: epoch)
        }
    }

    func snapshot() -> AgentState { state }
}
