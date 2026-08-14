import Foundation

/// One persistent, read-only subscription to a Codex app-server thread. The observer owns provider RPC
/// choreography but emits only raw provider messages; `CodexAdapter.agentSignals` remains the sole place
/// that interprets them as turn state.
final class CodexAppServerObserver: @unchecked Sendable {
    private let peer: any CodexAppServerPeer
    private var nextID = 1

    convenience init(socketPath: String) {
        self.init(peer: WebSocketCodexAppServerPeer(socketPath: socketPath))
    }

    init(peer: any CodexAppServerPeer) { self.peer = peer }

    func run(threadId: String, onObservation: (RawTelemetry) -> Void) throws {
        defer { peer.close() }
        try peer.open()

        _ = try call(
            "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("orchestra-status"),
                    "title": .string("Orchestra status observer"),
                    "version": .string("1"),
                ]),
            ]),
            onObservation: onObservation
        )
        try notify("initialized", params: .object([:]))
        let resumed = try call(
            "thread/resume",
            params: .object(["threadId": .string(threadId)]),
            onObservation: onObservation
        )
        onObservation(.rpcResponse(method: "thread/resume", result: resumed))

        while true {
            try handle(peer.receive(), onObservation: onObservation)
        }
    }

    func shutdown() { peer.shutdown() }

    private func call(
        _ method: String,
        params: JSONValue,
        onObservation: (RawTelemetry) -> Void
    ) throws -> JSONValue {
        let id = nextID
        nextID += 1
        try peer.send(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ]))

        while true {
            let message = try peer.receive()
            if message["id"]?.intValue == id, message["method"] == nil {
                if let error = message["error"] {
                    throw CodexAppServerError.rpcError(
                        code: error["code"]?.intValue ?? -1,
                        message: error["message"]?.stringValue ?? "unknown app-server error"
                    )
                }
                guard let result = message["result"] else {
                    throw CodexAppServerError.protocolViolation("JSON-RPC response missing result")
                }
                return result
            }
            try handle(message, onObservation: onObservation)
        }
    }

    private func notify(_ method: String, params: JSONValue) throws {
        try peer.send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func handle(_ message: JSONValue, onObservation: (RawTelemetry) -> Void) throws {
        guard let method = message["method"]?.stringValue else { return }
        if let id = message["id"] {
            // This connection observes only. Approval and input requests remain owned by the co-present
            // stock TUI; explicitly declining prevents this subscriber from accidentally claiming them.
            try peer.send(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .int(-32601),
                    "message": .string("Orchestra status observer does not handle server requests"),
                ]),
            ]))
            return
        }
        onObservation(.rpcNotification(method: method, params: message["params"] ?? .object([:])))
    }
}
