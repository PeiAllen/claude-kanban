import Foundation
import Dispatch

/// Bridges an adapter's blocking observation connection into Swift concurrency without occupying a
/// cooperative executor worker. The stream preserves the source callback's order, while cancellation
/// synchronously shuts the source down so its dispatch worker cannot leak across a session replacement.
struct AgentObservationIngress: Sendable {
    let source: any AgentObservationSource

    func stream() -> AsyncThrowingStream<RawTelemetry, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                source.shutdown()
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try source.run { raw in
                        _ = continuation.yield(raw)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
