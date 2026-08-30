import Foundation

/// Adapter-owned binding of one app-server socket to one Codex thread. Core sees only the generic
/// blocking source contract and can manufacture a fresh instance for each reconnect attempt.
final class CodexAppServerObservationSource: AgentObservationSource, @unchecked Sendable {
    private let threadId: String
    private let observer: CodexAppServerObserver

    init(socketPath: String, threadId: String) {
        self.threadId = threadId
        self.observer = CodexAppServerObserver(socketPath: socketPath)
    }

    func run(onObservation: @escaping @Sendable (RawTelemetry) -> Void) throws {
        try observer.run(threadId: threadId, onObservation: onObservation)
    }

    func shutdown() { observer.shutdown() }
}

/// One persistent, read-only subscription to a Codex app-server thread. The observer owns provider RPC
/// choreography but emits only raw provider messages; `CodexAdapter.agentSignals` remains the sole place
/// that interprets them as turn state.
final class CodexAppServerObserver: @unchecked Sendable {
    private let client: CodexAppServerClient

    convenience init(socketPath: String) {
        self.init(peer: WebSocketCodexAppServerPeer(socketPath: socketPath))
    }

    init(peer: any CodexAppServerPeer) { self.client = CodexAppServerClient(peer: peer) }

    func run(threadId: String, onObservation: @escaping (RawTelemetry) -> Void) throws {
        defer { client.close() }
        let notify: CodexAppServerClient.NotificationHandler = { method, params in
            onObservation(.rpcNotification(method: method, params: params))
        }
        let resumed = try client.openAndResume(
            threadId: threadId,
            clientName: "orchestra-status",
            clientTitle: "Orchestra status observer",
            onNotification: notify
        )
        onObservation(.rpcResponse(method: "thread/resume", result: resumed))

        while true {
            try client.receive(onNotification: notify)
        }
    }

    func shutdown() { client.shutdown() }
}
