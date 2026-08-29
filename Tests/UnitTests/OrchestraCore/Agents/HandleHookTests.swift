import Testing
import Foundation
@testable import OrchestraCore

@Suite struct HandleHookTests {
    private func state(_ service: OrchestraService, _ id: UUID) async -> AgentState? {
        await service.store.get(id)?.agentState
    }

    @Test("sessionStart returns the live orientation; compact skips it")
    func sessionStart() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let ref = card.id.uuidString

        let r = await svc.handleHook(ref, event: .sessionStart, report: nil, source: .startup)
        #expect(r?.additionalContext?.contains(card.shortId) == true)
        #expect(r?.continuation == nil)

        let compact = await svc.handleHook(ref, event: .sessionStart, report: nil, source: .compact)
        #expect(compact == nil)   // don't re-orient mid-turn
    }

    @Test("stop drains the inbox into the continuation")
    func stop() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let epoch = try #require(await svc.store.get(card.id)).sessionEpoch   // the fence reads sessionEpoch
        try await svc.send(card.id, "queued message")

        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil, observedEpoch: epoch)
        #expect(r?.continuation?.contains("queued message") == true)
        #expect(r?.additionalContext == nil)
    }

    @Test("a Stop claims its drain before applying the turn-completed observation")
    func stopClaimsBeforeTurnCompletion() async throws {
        let adapter = HookSignalTestAdapter()
        let env = TestEnv.make(grace: 2, registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b", agentId: adapter.id)
        )
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        try await env.svc.send(card.id, "DRAIN-ME")

        let payload: JSONValue = .object(["session_id": .string("hook-session")])
        let r = await env.svc.handleHook(
            card.id.uuidString,
            event: .stop,
            report: nil,
            source: nil,
            observedEpoch: epoch,
            stopHookActive: false,
            observationPayload: payload
        )

        #expect(r?.continuation?.contains("DRAIN-ME") == true)
        #expect(await state(env.svc, card.id)?.turnStatus == .waiting())
        #expect(try await env.svc.inboxPeek(card.id).first?.lease?.route == .stopDrain)
    }

    @Test("stop with an empty inbox yields no continuation")
    func stopEmpty() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))
        let epoch = try #require(await svc.store.get(card.id)).sessionEpoch
        let r = await svc.handleHook(card.id.uuidString, event: .stop, report: nil, source: nil, observedEpoch: epoch)
        #expect(r == nil)   // nil from an empty inbox (matching epoch), not from the fence
    }

    @Test("a telemetry event applies its report to the store and returns no response")
    func telemetry() async throws {
        let (svc, _, _, _, _, base) = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(base), branch: "b"))

        let r = await svc.handleHook(card.id.uuidString, event: .postToolUse,
                                     report: StatusReport(desc: "Running: ls"), source: nil)
        #expect(r == nil)
        let after = try await svc.resolveRef(card.id.uuidString)
        #expect(after.desc == "Running: ls")
        #expect(after.turnStatus == .running)   // legacy `run` is no longer status authority
    }

    @Test("fresh hook payloads update the authoritative provider-neutral state")
    func hookPayloadUpdatesAgentState() async throws {
        let adapter = HookSignalTestAdapter()
        let env = TestEnv.make(
            registry: AgentRegistry(adapters: [adapter]),
            traceHTTPBaseURL: "http://127.0.0.1:43181/test-token"
        )
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "hook-shadow", agentId: adapter.id)
        )
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        #expect(await state(env.svc, card.id)?.turnStatus == .running)
        let launchEnv = try #require(env.sessions.ensureEnv[env.sessions.sessionName(card.id)])
        #expect(launchEnv["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ==
                "http://127.0.0.1:43181/test-token/v1/traces/\(card.id.uuidString.lowercased())/\(epoch)")

        let prompt: JSONValue = .object([
            "session_id": .string("hook-session"),
            "prompt_id": .string("prompt-a"),
        ])
        _ = await env.svc.handleHook(
            card.shortId, event: .userPrompt, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: prompt
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)

        let permission: JSONValue = .object([
            "session_id": .string("hook-session"),
            "prompt_id": .string("prompt-a"),
            "tool_name": .string("Bash"),
        ])
        _ = await env.svc.handleHook(
            card.shortId, event: .permission, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: permission
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)
        #expect(await state(env.svc, card.id)?.hasRequest(kind: .permission) == true)

        _ = await env.svc.handleHook(
            card.shortId, event: .postToolUse, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: prompt
        )
        #expect(await state(env.svc, card.id)?.activeRequests.isEmpty == true)

        _ = await env.svc.handleHook(
            card.shortId, event: .statusLine, report: StatusReport(ctxPct: 12), source: nil,
            observedEpoch: epoch
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)

        await env.svc.receivePushedAgentObservation(
            cardId: card.id,
            observedEpoch: epoch,
            raw: .traceSpanEnded(
                name: "claude_code.interaction",
                attributes: .object([
                    "session.id": .string("hook-session"),
                    "prompt.id": .string("prompt-a"),
                ])
            )
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .waiting())

        let secondPrompt: JSONValue = .object([
            "session_id": .string("hook-session"),
            "prompt_id": .string("prompt-b"),
        ])
        _ = await env.svc.handleHook(
            card.shortId, event: .userPrompt, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: secondPrompt
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)

        let stop: JSONValue = .object([
            "session_id": .string("hook-session"),
            "prompt_id": .string("prompt-b"),
            "background_tasks": .array([.object(["id": .string("job-1")])]),
        ])
        _ = await env.svc.handleHook(
            card.shortId, event: .stop, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: stop
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .waiting(.init(resume: .init())))
    }

    @Test("hook observations are fenced by both launch epoch and current harness session")
    func hookPayloadIdentityFences() async throws {
        let adapter = HookSignalTestAdapter()
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "hook-fences", agentId: adapter.id)
        )
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let prompt: JSONValue = .object(["session_id": .string("hook-session")])
        _ = await env.svc.handleHook(
            card.shortId, event: .userPrompt, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: prompt
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)

        let wrongSession: JSONValue = .object(["session_id": .string("old-session")])
        _ = await env.svc.handleHook(
            card.shortId, event: .stop, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: wrongSession
        )
        _ = await env.svc.handleHook(
            card.shortId, event: .stop, report: nil, source: nil,
            observedEpoch: epoch + 1, observationPayload: prompt
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .running)
    }

    @Test("a delayed Claude OTLP completion cannot close the next prompt")
    func delayedClaudeCompletionCannotCloseNextPrompt() async throws {
        let adapter = HookSignalTestAdapter()
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "hook-turn-fence", agentId: adapter.id)
        )
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch

        func prompt(_ id: String) async {
            _ = await env.svc.handleHook(
                card.shortId, event: .userPrompt, report: nil, source: nil,
                observedEpoch: epoch,
                observationPayload: .object([
                    "session_id": .string("hook-session"),
                    "prompt_id": .string(id),
                ])
            )
        }

        await prompt("prompt-a")
        _ = await env.svc.handleHook(
            card.shortId, event: .stop, report: nil, source: nil,
            observedEpoch: epoch,
            observationPayload: .object([
                "session_id": .string("hook-session"),
                "prompt_id": .string("prompt-a"),
            ])
        )
        await prompt("prompt-b")

        await env.svc.receivePushedAgentObservation(
            cardId: card.id,
            observedEpoch: epoch,
            raw: .traceSpanEnded(
                name: "claude_code.interaction",
                attributes: .object([
                    "session.id": .string("hook-session"),
                    "prompt.id": .string("prompt-a"),
                ])
            )
        )

        #expect(await state(env.svc, card.id)?.turnStatus == .running)
    }

    @Test("unknown ref returns nil, never throws")
    func unknownRef() async {
        let (svc, _, _, _, _, _) = TestEnv.make()
        let r = await svc.handleHook("no-such-card", event: .stop, report: nil, source: nil)
        #expect(r == nil)
    }
}

private struct HookSignalTestAdapter: Adapter {
    let id = "hook-signals"
    let name = "Hook signals"
    let icon = "bolt"
    let bin = "fake-hook-agent"
    let enabled = true
    let capabilities = AgentCapabilities.stub

    func models() -> [AgentModel] { [AgentModel(id: "m1")] }
    func newSessionId() -> String? { "hook-session" }
    func start(_ ctx: AdapterContext) -> [String] { [bin] }
    func resume(_ ctx: AdapterContext) -> [String]? { nil }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        AgentSessionInfo(agentId: id, sessionId: current, transcriptPath: nil,
                         priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
    }
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal] {
        ClaudeCodeAdapter().agentSignals(from: raw, context: context)
    }
    func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint? {
        ClaudeCodeAdapter().observationEndpoint(setup)
    }
    func launchEnvironment(_ context: AdapterContext) -> [String: String] {
        ClaudeCodeAdapter().launchEnvironment(context)
    }
}
