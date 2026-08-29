import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Blocking agent-observation ingress")
struct AgentObservationIngressTests {
    @Test("a blocking source becomes an ordered async sequence")
    func orderedSequence() async throws {
        let source = IngressTestSource()
        let ingress = AgentObservationIngress(source: source)
        let reader = _Concurrency.Task { () -> [RawTelemetry] in
            var received: [RawTelemetry] = []
            do {
                for try await raw in ingress.stream() { received.append(raw) }
            } catch is IngressTestError {
                // A provider disconnect terminates this connection attempt after draining prior events.
            } catch {
                Issue.record("unexpected ingress error: \(error)")
            }
            return received
        }

        try await pollUntil("blocking source to start") { source.isStarted }
        let first = RawTelemetry.rpcNotification(method: "one", params: .object([:]))
        let second = RawTelemetry.rpcNotification(method: "two", params: .object([:]))
        source.emit(first)
        source.emit(second)
        source.disconnect()

        #expect(await reader.value == [first, second])
    }

    @Test("cancelling the async consumer synchronously shuts down the blocking source")
    func cancellationUnblocksSource() async throws {
        let source = IngressTestSource()
        let ingress = AgentObservationIngress(source: source)
        let reader = _Concurrency.Task {
            do {
                for try await _ in ingress.stream() {}
            } catch {}
        }

        try await pollUntil("blocking source to start") { source.isStarted }
        reader.cancel()
        _ = await reader.value

        try await pollUntil("cancelled ingress to shut down its source") { source.wasShutdown }
    }
}

private enum IngressTestError: Error {
    case disconnected
}

private final class IngressTestSource: AgentObservationSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var callback: (@Sendable (RawTelemetry) -> Void)?
    private var started = false
    private var disconnected = false
    private var stopped = false
    private var shutdownCalled = false

    var isStarted: Bool { condition.withLock { started } }
    var wasShutdown: Bool { condition.withLock { shutdownCalled } }

    func run(onObservation: @escaping @Sendable (RawTelemetry) -> Void) throws {
        condition.lock()
        callback = onObservation
        started = true
        condition.broadcast()
        while !disconnected && !stopped { condition.wait() }
        let lost = disconnected
        condition.unlock()
        if lost { throw IngressTestError.disconnected }
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
