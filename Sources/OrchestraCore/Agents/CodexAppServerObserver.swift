import Foundation

/// Adapter-owned binding of one app-server socket to one Codex thread. Core sees only the generic
/// blocking source contract and can manufacture a fresh instance for each reconnect attempt.
final class CodexAppServerObservationSource: AgentObservationSource, @unchecked Sendable {
    private let binding: AgentObservationBinding
    private let observer: CodexAppServerObserver

    init(socketPath: String, binding: AgentObservationBinding) {
        self.binding = binding
        self.observer = CodexAppServerObserver(socketPath: socketPath)
    }

    func run(onObservation: @escaping @Sendable (RawTelemetry) -> Void) throws {
        try observer.run(binding: binding, onObservation: onObservation)
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

    func run(binding: AgentObservationBinding, onObservation: @escaping (RawTelemetry) -> Void) throws {
        defer { client.close() }
        let notify: CodexAppServerClient.NotificationHandler = { method, params in
            if method == "thread/started" {
                guard let thread = params["thread"], Self.isCandidate(thread, for: binding) else { return }
            }
            onObservation(.rpcNotification(method: method, params: params))
        }
        try client.openAndInitialize(
            clientName: "orchestra-status",
            clientTitle: "Orchestra status observer",
            onNotification: notify
        )
        if let threadId = binding.harnessSessionId, !threadId.isEmpty {
            let resumed = try client.call(
                "thread/resume",
                params: .object(["threadId": .string(threadId)]),
                onNotification: notify
            )
            onObservation(.rpcResponse(method: "thread/resume", result: resumed))
        } else {
            let loaded = try client.call(
                "thread/loaded/list",
                params: .object([:]),
                onNotification: notify
            )
            let loadedCandidates: [JSONValue] = try (loaded["data"]?.arrayValue ?? []).compactMap { value in
                guard let threadId = value.stringValue, !threadId.isEmpty else { return nil }
                let read = try client.call(
                    "thread/read",
                    params: .object([
                        "threadId": .string(threadId),
                        "includeTurns": .bool(false),
                    ]),
                    onNotification: notify
                )
                guard let thread = read["thread"], Self.isCandidate(thread, for: binding) else { return nil }
                return read
            }
            if loadedCandidates.count == 1 {
                onObservation(.rpcResponse(method: "thread/read", result: loadedCandidates[0]))
            }
        }

        while true {
            try client.receive(onNotification: notify)
        }
    }

    func shutdown() { client.shutdown() }

    private static func isCandidate(_ thread: JSONValue, for binding: AgentObservationBinding) -> Bool {
        guard let id = thread["id"]?.stringValue, !id.isEmpty,
              thread["cwd"]?.stringValue == binding.cwd,
              thread["ephemeral"]?.boolValue == false,
              thread["parentThreadId"]?.stringValue?.isEmpty != false,
              let createdAt = thread["createdAt"]?.intValue
        else { return false }
        guard let startedAfter = binding.startedAfter else { return true }
        return createdAt >= Int(floor(startedAfter.timeIntervalSince1970))
    }
}
