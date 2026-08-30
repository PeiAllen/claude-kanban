import Testing
import Foundation
@testable import OrchestraCore
import TestSupport

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

        let compact = await svc.handleHook(ref, event: .sessionStart, report: nil, source: .compact)
        #expect(compact == nil)   // don't re-orient mid-turn
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
        #expect(after.turnStatus == .unavailable)   // metadata reports are no longer status authority
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
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)
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
        #expect(await state(env.svc, card.id)?.humanNeed == .permission)

        _ = await env.svc.handleHook(
            card.shortId, event: .postToolUse, report: nil, source: nil,
            observedEpoch: epoch, observationPayload: prompt
        )
        #expect(await state(env.svc, card.id)?.humanNeed == nil)

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

    @Test("a provider SessionStart observed before the live landing survives the readiness handoff")
    func sessionStartBeforeLiveLanding() async throws {
        let adapter = HookSignalTestAdapter(capabilities: .claudeCode)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await env.svc.spawn(
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "hook-pre-live", agentId: adapter.id)
        )
        try await pollUntil("launch readiness waiter to register") {
            await env.svc.reconcile()
            return await env.svc.hasReadinessWaiter(card.id)
        }
        let launching = try #require(await env.svc.store.get(card.id))
        let epoch = launching.sessionEpoch
        #expect(launching.phase.kind == .launching)
        #expect(launching.agentSessionId == "hook-session")

        await env.svc.receivePushedAgentObservation(
            cardId: card.id,
            observedEpoch: epoch,
            raw: .hooksPush(kind: "session", payload: .object([
                "session_id": .string("hook-session"),
                "source": .string("startup"),
            ]))
        )
        try await env.svc.report(
            card.id,
            StatusReport(sessionSource: "startup"),
            observedEpoch: epoch
        )
        try await pollUntil("provider-confirmed launch to apply its buffered waiting state") {
            await state(env.svc, card.id)?.turnStatus == .waiting()
        }

        #expect(await state(env.svc, card.id)?.turnStatus == .waiting())
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
        let prompt: JSONValue = .object([
            "session_id": .string("hook-session"),
            "prompt_id": .string("prompt-a"),
        ])
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

    @Test("current live endpoint installs and refreshes while stale epoch, provider, and session reports cannot replace it")
    func messageEndpointIdentityFences() async throws {
        let senders = MessageSenderRecorder()
        let adapter = HookSignalTestAdapter(messageSenders: senders)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "message-fences", agentId: adapter.id)
        )
        let current = try #require(await env.svc.store.get(card.id))
        let epoch = current.sessionEpoch
        let first = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: try #require(current.agentSessionId),
            endpoint: .claudeHookRPC(socketPath: "/tmp/first.sock", token: "first-secret")
        )

        _ = await env.svc.handleHook(
            card.shortId, event: .statusLine, report: nil, source: nil,
            observedEpoch: epoch, messageEndpoint: first
        )
        #expect(senders.created.count == 1)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.identity == .init(
            providerId: adapter.id,
            sessionEpoch: epoch,
            harnessSessionId: first.harnessSessionId
        ))

        for rejected in [
            (epoch - 1, AgentMessageEndpointReport(
                providerId: adapter.id, harnessSessionId: first.harnessSessionId,
                endpoint: .claudeHookRPC(socketPath: "/tmp/stale.sock", token: "stale-secret"))),
            (epoch, AgentMessageEndpointReport(
                providerId: "other-provider", harnessSessionId: first.harnessSessionId,
                endpoint: .claudeHookRPC(socketPath: "/tmp/provider.sock", token: "provider-secret"))),
            (epoch, AgentMessageEndpointReport(
                providerId: adapter.id, harnessSessionId: "other-session",
                endpoint: .claudeHookRPC(socketPath: "/tmp/session.sock", token: "session-secret"))),
        ] {
            _ = await env.svc.handleHook(
                card.shortId, event: .statusLine, report: nil, source: nil,
                observedEpoch: rejected.0, messageEndpoint: rejected.1
            )
        }
        #expect(senders.created.count == 1)
        #expect(senders.created[0].shutdownCount == 0)

        let refreshed = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: first.harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: "/tmp/refreshed.sock", token: "refreshed-secret")
        )
        _ = await env.svc.handleHook(
            card.shortId, event: .statusLine, report: nil, source: nil,
            observedEpoch: epoch, messageEndpoint: refreshed
        )
        #expect(senders.created.count == 2)
        #expect(senders.created[0].shutdownCount == 1)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.endpoint == refreshed.endpoint)

        let nextSession = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: "next-session",
            endpoint: .claudeHookRPC(socketPath: "/tmp/next.sock", token: "next-secret")
        )
        _ = await env.svc.handleHook(
            card.shortId, event: .sessionStart,
            report: StatusReport(sessionId: nextSession.harnessSessionId, sessionSource: "clear"),
            source: .clear, observedEpoch: epoch, messageEndpoint: nextSession
        )
        #expect(senders.created.count == 3)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.identity.harnessSessionId == "next-session")

        let staleFormerSession = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: first.harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: "/tmp/former.sock", token: "former-secret")
        )
        _ = await env.svc.handleHook(
            card.shortId, event: .sessionStart,
            report: StatusReport(sessionId: staleFormerSession.harnessSessionId, sessionSource: "startup"),
            source: .startup, observedEpoch: epoch, messageEndpoint: staleFormerSession
        )
        #expect(senders.created.count == 3)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.identity.harnessSessionId == "next-session")
        #expect(await env.svc.store.get(card.id)?.agentSessionId == "next-session")

        let persisted = try String(contentsOfFile: env.base + "/tasks.json", encoding: .utf8)
        for secret in ["first-secret", "stale-secret", "provider-secret", "session-secret",
                       "refreshed-secret", "next-secret", "former-secret"] {
            #expect(!persisted.contains(secret))
        }
    }

    @Test("a rejected endpoint refresh clears the old credential-bound sender")
    func rejectedMessageEndpointRefreshClearsOldSender() async throws {
        let senders = MessageSenderRecorder()
        let adapter = HookSignalTestAdapter(messageSenders: senders)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "message-rejected-refresh", agentId: adapter.id)
        )
        let current = try #require(await env.svc.store.get(card.id))
        let harnessSessionId = try #require(current.agentSessionId)
        let first = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: "/tmp/first.sock", token: "first-secret")
        )
        _ = await env.svc.handleHook(
            card.shortId, event: .statusLine, report: nil, source: nil,
            observedEpoch: current.sessionEpoch, messageEndpoint: first
        )
        let installed = try #require(senders.created.first)

        let rejected = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: "/tmp/rejected.sock", token: "rejected-secret")
        )
        senders.reject(rejected.endpoint)
        _ = await env.svc.handleHook(
            card.shortId, event: .statusLine, report: nil, source: nil,
            observedEpoch: current.sessionEpoch, messageEndpoint: rejected
        )

        #expect(installed.shutdownCount == 1)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle == nil)
        #expect(await env.svc.runtime[card.id]?.pendingAgentMessageEndpoint == nil)
    }

    @Test("a current SessionStart endpoint buffers before live and installs at the live landing")
    func messageEndpointBuffersUntilLive() async throws {
        let senders = MessageSenderRecorder()
        let adapter = HookSignalTestAdapter(capabilities: .claudeCode, messageSenders: senders)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await env.svc.spawn(
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "message-buffer", agentId: adapter.id)
        )
        try await pollUntil("launch readiness waiter to register") {
            await env.svc.reconcile()
            return await env.svc.hasReadinessWaiter(card.id)
        }
        let launching = try #require(await env.svc.store.get(card.id))
        let endpoint = AgentMessageEndpointReport(
            providerId: adapter.id,
            harnessSessionId: try #require(launching.agentSessionId),
            endpoint: .claudeHookRPC(socketPath: "/tmp/buffered.sock", token: "buffered-secret")
        )

        _ = await env.svc.handleHook(
            card.shortId, event: .sessionStart, report: nil, source: .startup,
            observedEpoch: launching.sessionEpoch, messageEndpoint: endpoint
        )
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle == nil)
        #expect(await env.svc.runtime[card.id]?.pendingAgentMessageEndpoint?.endpoint == endpoint.endpoint)

        try await env.svc.report(
            card.id, StatusReport(sessionSource: "startup"), observedEpoch: launching.sessionEpoch
        )
        try await pollUntil("live landing to install buffered native-message handle") {
            await env.svc.reconcile()
            return await env.svc.runtime[card.id]?.agentMessageHandle != nil
        }

        #expect(senders.created.count == 1)
        #expect(await env.svc.runtime[card.id]?.pendingAgentMessageEndpoint == nil)
    }

    @Test("a late native endpoint cannot recreate runtime for a dead card")
    func deadCardEndpointDoesNotCreateRuntime() async throws {
        let env = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "message-dead")
        )
        let current = try #require(await env.svc.store.get(card.id))
        let report = AgentMessageEndpointReport(
            providerId: current.agentId,
            harnessSessionId: try #require(current.agentSessionId),
            endpoint: .claudeHookRPC(socketPath: "/tmp/dead.sock", token: "dead-secret")
        )
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)
        await env.svc.detachCardRuntime(card.id)

        await env.svc.receiveAgentMessageEndpoint(
            cardId: card.id,
            report: report,
            observedEpoch: current.sessionEpoch,
            event: .statusLine
        )

        #expect(await env.svc.runtime[card.id] == nil)
    }

    @Test("a late native endpoint cannot recreate runtime for an archived card")
    func archivedCardEndpointDoesNotCreateRuntime() async throws {
        let env = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "message-archived")
        )
        let current = try #require(await env.svc.store.get(card.id))
        let report = AgentMessageEndpointReport(
            providerId: current.agentId,
            harnessSessionId: try #require(current.agentSessionId),
            endpoint: .claudeHookRPC(socketPath: "/tmp/archived.sock", token: "archived-secret")
        )
        try await env.svc.archive(card.id)
        await env.svc.detachCardRuntime(card.id)

        await env.svc.receiveAgentMessageEndpoint(
            cardId: card.id,
            report: report,
            observedEpoch: current.sessionEpoch,
            event: .statusLine
        )

        #expect(await env.svc.runtime[card.id] == nil)
    }

    @Test("a live adapter-derived endpoint installs an exact sender without a hook report")
    func derivedMessageEndpointInstallsAtLive() async throws {
        let senders = MessageSenderRecorder()
        let adapter = HookSignalTestAdapter(
            messageSenders: senders,
            derivedMessageSocketPath: "/tmp/codex-derived.sock"
        )
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "derived-message-endpoint", agentId: adapter.id)
        )
        let live = try #require(await env.svc.store.get(card.id))

        #expect(senders.created.count == 1)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.identity == .init(
            providerId: adapter.id,
            sessionEpoch: live.sessionEpoch,
            harnessSessionId: "hook-session"
        ))
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.endpoint == .codexAppServer(
            socketPath: "/tmp/codex-derived.sock",
            threadId: "hook-session"
        ))
    }

    @Test("boot adoption rebuilds an adapter-derived sender for the surviving exact session")
    func bootAdoptionRebuildsDerivedMessageEndpoint() async throws {
        let senders = MessageSenderRecorder()
        let adapter = HookSignalTestAdapter(
            messageSenders: senders,
            derivedMessageSocketPath: "/tmp/codex-boot.sock"
        )
        let registry = AgentRegistry(adapters: [adapter])
        let env = TestEnv.make(registry: registry)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base),
                       branch: "derived-message-boot", agentId: adapter.id)
        )
        let persisted = try #require(await env.svc.store.get(card.id))
        #expect(senders.created.count == 1)

        let restarted = TestEnv.remake(base: env.base, registry: registry)
        restarted.sessions.setStampedEpoch(card.id, persisted.sessionEpoch)
        await restarted.svc.reconcilePhasesAtBoot()

        #expect(senders.created.count == 2)
        #expect(await restarted.svc.runtime[card.id]?.agentMessageHandle?.identity == .init(
            providerId: adapter.id,
            sessionEpoch: persisted.sessionEpoch,
            harnessSessionId: "hook-session"
        ))
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
    let capabilities: AgentCapabilities
    let messageSenders: MessageSenderRecorder?
    let derivedMessageSocketPath: String?

    init(capabilities: AgentCapabilities = .stub, messageSenders: MessageSenderRecorder? = nil,
         derivedMessageSocketPath: String? = nil) {
        self.capabilities = capabilities
        self.messageSenders = messageSenders
        self.derivedMessageSocketPath = derivedMessageSocketPath
    }

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
        if let derivedMessageSocketPath { return .unixSocket(path: derivedMessageSocketPath) }
        return ClaudeCodeAdapter().observationEndpoint(setup)
    }
    func messageEndpoint(
        observationEndpoint: AgentObservationEndpoint,
        harnessSessionId: String
    ) -> AgentMessageEndpoint? {
        guard let socketPath = observationEndpoint.unixSocketPath,
              derivedMessageSocketPath != nil
        else { return nil }
        return .codexAppServer(socketPath: socketPath, threadId: harnessSessionId)
    }
    func launchEnvironment(_ context: AdapterContext) -> [String: String] {
        ClaudeCodeAdapter().launchEnvironment(context)
    }
    func makeMessageSender(for endpoint: AgentMessageEndpoint) -> (any AgentMessageSender)? {
        messageSenders?.make(endpoint: endpoint)
    }
}

private final class MessageSenderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingMessageSender] = []
    private var rejectedEndpoint: AgentMessageEndpoint?

    var created: [RecordingMessageSender] { lock.withLock { storage } }

    func reject(_ endpoint: AgentMessageEndpoint) {
        lock.withLock { rejectedEndpoint = endpoint }
    }

    func make(endpoint: AgentMessageEndpoint) -> RecordingMessageSender? {
        lock.withLock {
            guard endpoint != rejectedEndpoint else { return nil }
            let sender = RecordingMessageSender(endpoint: endpoint)
            storage.append(sender)
            return sender
        }
    }
}

private final class RecordingMessageSender: AgentMessageSender, @unchecked Sendable {
    let endpoint: AgentMessageEndpoint
    private let lock = NSLock()
    private var shutdowns = 0

    init(endpoint: AgentMessageEndpoint) { self.endpoint = endpoint }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    func send(_ message: String) async throws {}
    func shutdown() { lock.withLock { shutdowns += 1 } }
}
