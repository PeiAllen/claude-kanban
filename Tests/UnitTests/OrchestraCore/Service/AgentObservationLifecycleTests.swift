import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Agent observation source lifecycle")
struct AgentObservationLifecycleTests {
    private func state(_ service: OrchestraService, _ id: UUID) async -> AgentState? {
        await service.store.get(id)?.agentState
    }

    @Test("launch carries the endpoint; live owns one observer and leaving live tears it down")
    func liveLifecycle() async throws {
        let feed = ObservationTestFeed()
        let adapter = ObservationTestAdapter(feed: feed)
        let clock = TestClock()
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]), clock: clock)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "observed", agentId: adapter.id)
        )

        let endpoint = "\(env.base)/state/observed-\(card.shortId).sock"
        #expect(env.sessions.ensureArgv[env.sessions.sessionName(card.id)] == ["fake-observed", endpoint])
        try await pollUntil("first observation source to start") {
            feed.source(at: 0)?.isStarted == true
        }
        #expect(feed.requests == [.init(endpoint: .unixSocket(path: endpoint), sessionId: "thread-1")])
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)
        #expect(await env.svc.agentObservationActive(card.id))

        let first = try #require(feed.source(at: 0))
        first.emit(.rpcNotification(
            method: "test/turn-started",
            params: .object(["turn_id": .string("turn-1")])
        ))
        try await pollUntil("started turn to reach the durable reducer") {
            await state(env.svc, card.id)?.turnStatus == .running
        }
        first.emit(.rpcNotification(
            method: "test/turn-completed",
            params: .object(["turn_id": .string("turn-1")])
        ))
        try await pollUntil("completed turn to reach the durable reducer") {
            await state(env.svc, card.id)?.turnStatus == .waiting()
        }
        #expect(await state(env.svc, card.id)?.turnStatus == .waiting())

        first.disconnect()
        try await pollUntil("disconnect to make observation unavailable") {
            await state(env.svc, card.id)?.turnStatus == .unavailable
        }
        try await pollUntil("observer to reconnect with a fresh source") {
            // The service clock also owns unrelated debounce/timeout sleepers, so waiting for an
            // undifferentiated parked sleeper can advance before the reconnect sleep exists. Advance
            // inside convergence instead: whichever poll follows the reconnect's park releases it.
            clock.advance(by: .milliseconds(250))
            await _Concurrency.Task.yield()
            return feed.source(at: 1)?.isStarted == true
        }
        let second = try #require(feed.source(at: 1))
        second.emit(.rpcNotification(
            method: "test/turn-started",
            params: .object(["turn_id": .string("turn-2")])
        ))
        try await pollUntil("reconnected source to restore running") {
            await state(env.svc, card.id)?.turnStatus == .running
        }

        _ = await env.svc.transition(card.id, to: .relaunching)
        try await pollUntil("leaving live to shut down the observer") { second.wasShutdown }
        #expect(await state(env.svc, card.id) == nil)
        #expect(!(await env.svc.agentObservationActive(card.id)))
    }

    @Test("a session rollover replaces the subscription and resets the dark snapshot")
    func sessionRollover() async throws {
        let feed = ObservationTestFeed()
        let adapter = ObservationTestAdapter(feed: feed)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "rollover", agentId: adapter.id)
        )
        try await pollUntil { feed.source(at: 0)?.isStarted == true }
        let old = try #require(feed.source(at: 0))
        old.emit(.rpcNotification(
            method: "test/turn-started",
            params: .object(["turn_id": .string("turn-1")])
        ))
        old.emit(.rpcNotification(
            method: "test/turn-completed",
            params: .object(["turn_id": .string("turn-1")])
        ))
        try await pollUntil { await state(env.svc, card.id)?.turnStatus == .waiting() }

        try await env.svc.report(card.id, StatusReport(sessionId: "thread-2"))
        try await pollUntil("new session observation source to replace the old one") {
            feed.source(at: 1)?.isStarted == true && old.wasShutdown
        }
        #expect(feed.requests.last?.sessionId == "thread-2")
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)

        let replacement = try #require(feed.source(at: 1))
        replacement.emit(.rpcNotification(
            method: "test/turn-started",
            params: .object(["turn_id": .string("turn-2")])
        ))
        try await pollUntil { await state(env.svc, card.id)?.turnStatus == .running }
    }

    @Test("late session binding arms an observer without a status transition")
    func lateSessionBinding() async throws {
        let feed = ObservationTestFeed()
        let adapter = ObservationTestAdapter(feed: feed, initialSessionId: nil)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: TestEnv.repo(env.base),
                       branch: "late-bind", agentId: adapter.id)
        )
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)
        #expect(feed.requests.isEmpty)

        try await env.svc.report(card.id, StatusReport(sessionId: "thread-late"))

        try await pollUntil("late-bound observation source to start") {
            feed.source(at: 0)?.isStarted == true
        }
        #expect(feed.requests == [.init(
            endpoint: .unixSocket(path: "\(env.base)/state/observed-\(card.shortId).sock"),
            sessionId: "thread-late"
        )])
    }

    @Test("an unavailable session rollover replaces its observer without a status transition")
    func unavailableSessionRollover() async throws {
        let feed = ObservationTestFeed()
        let adapter = ObservationTestAdapter(feed: feed)
        let env = TestEnv.make(registry: AgentRegistry(adapters: [adapter]))
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: TestEnv.repo(env.base),
                       branch: "dark-rollover", agentId: adapter.id)
        )
        try await pollUntil { feed.source(at: 0)?.isStarted == true }
        let old = try #require(feed.source(at: 0))
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)

        try await env.svc.report(card.id, StatusReport(sessionId: "thread-2"))

        try await pollUntil("unavailable rollover to replace its observer") {
            feed.source(at: 1)?.isStarted == true && old.wasShutdown
        }
        #expect(feed.requests.last?.sessionId == "thread-2")
        #expect(await state(env.svc, card.id)?.turnStatus == .unavailable)
    }

    @Test("boot adoption reconstructs a live card's observer from durable card and session identity")
    func bootAdoption() async throws {
        let original = TestEnv.make()
        let repo = TestEnv.repo(original.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            original.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "boot")
        )
        let durable = try #require(await original.svc.store.get(card.id))
        let sessionId = try #require(durable.agentSessionId)

        let feed = ObservationTestFeed()
        let adapter = ObservationTestAdapter(feed: feed, id: "claude-code")
        let restarted = TestEnv.remake(
            base: original.base,
            registry: AgentRegistry(adapters: [adapter])
        )
        restarted.sessions.setStampedEpoch(card.id, durable.sessionEpoch)

        await restarted.svc.reconcilePhasesAtBoot()
        try await pollUntil("boot-adopted observation source to start") {
            feed.source(at: 0)?.isStarted == true
        }
        #expect(feed.requests.first?.sessionId == sessionId)
        #expect(await state(restarted.svc, card.id)?.turnStatus == .unavailable)

        _ = await restarted.svc.transition(card.id, to: .relaunching)
    }
}

private enum ObservationTestError: Error {
    case disconnected
}

private final class ObservationTestSource: AgentObservationSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var callback: (@Sendable (RawTelemetry) -> Void)?
    private var stopped = false
    private var disconnected = false
    private var started = false
    private var shutdownCalled = false

    var isStarted: Bool { condition.withLock { started } }
    var wasShutdown: Bool { condition.withLock { shutdownCalled } }

    func run(onObservation: @escaping @Sendable (RawTelemetry) -> Void) throws {
        condition.lock()
        callback = onObservation
        started = true
        condition.broadcast()
        while !stopped && !disconnected { condition.wait() }
        let lost = disconnected
        condition.unlock()
        if lost { throw ObservationTestError.disconnected }
    }

    func emit(_ raw: RawTelemetry) {
        let callback = condition.withLock { self.callback }
        callback?(raw)
    }

    func disconnect() {
        condition.withLock {
            disconnected = true
            condition.broadcast()
        }
    }

    func shutdown() {
        condition.withLock {
            shutdownCalled = true
            stopped = true
            condition.broadcast()
        }
    }
}

private final class ObservationTestFeed: @unchecked Sendable {
    struct Request: Equatable {
        var endpoint: AgentObservationEndpoint
        var sessionId: String
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var sources: [ObservationTestSource] = []

    var requests: [Request] { lock.withLock { storedRequests } }

    func makeSource(endpoint: AgentObservationEndpoint, sessionId: String) -> ObservationTestSource {
        lock.withLock {
            let source = ObservationTestSource()
            storedRequests.append(.init(endpoint: endpoint, sessionId: sessionId))
            sources.append(source)
            return source
        }
    }

    func source(at index: Int) -> ObservationTestSource? {
        lock.withLock { sources.indices.contains(index) ? sources[index] : nil }
    }
}

private struct ObservationTestAdapter: Adapter {
    let feed: ObservationTestFeed
    let id: String
    let initialSessionId: String?
    let name = "Observed"
    let icon = "eye"
    let bin = "fake-observed"
    let enabled = true
    let capabilities = AgentCapabilities.stub

    init(feed: ObservationTestFeed, id: String = "observed", initialSessionId: String? = "thread-1") {
        self.feed = feed
        self.id = id
        self.initialSessionId = initialSessionId
    }

    func models() -> [AgentModel] { [AgentModel(id: "m1")] }
    func newSessionId() -> String? { initialSessionId }
    func start(_ ctx: AdapterContext) -> [String] {
        [bin, ctx.observationEndpoint?.unixSocketPath ?? "missing-endpoint"]
    }
    func resume(_ ctx: AdapterContext) -> [String]? { nil }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        AgentSessionInfo(agentId: id, sessionId: current, transcriptPath: nil,
                         priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
    }
    func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint? {
        .unixSocket(path: "\(setup.runtimeStateDir)/observed-\(setup.cardRef).sock")
    }
    func makeObservationSource(
        endpoint: AgentObservationEndpoint,
        harnessSessionId: String
    ) -> (any AgentObservationSource)? {
        feed.makeSource(endpoint: endpoint, sessionId: harnessSessionId)
    }
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal] {
        guard case .rpcNotification(let method, let params) = raw,
              let turnID = params["turn_id"]?.stringValue, !turnID.isEmpty
        else { return [] }
        switch method {
        case "test/turn-started":
            return [.init(sessionEpoch: context.sessionEpoch, turnID: turnID, kind: .turnStarted)]
        case "test/turn-completed":
            return [.init(sessionEpoch: context.sessionEpoch, turnID: turnID, kind: .turnCompleted())]
        default:
            return []
        }
    }
}
