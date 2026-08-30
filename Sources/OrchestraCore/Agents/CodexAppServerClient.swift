import Foundation

/// The small JSON-RPC choreography shared by Codex's passive observer and one-shot message sender.
/// It only correlates requests; each caller retains ownership of whether a notification has meaning.
final class CodexAppServerClient: @unchecked Sendable {
    typealias NotificationHandler = (String, JSONValue) -> Void

    private let peer: any CodexAppServerPeer
    private var nextID = 1

    init(peer: any CodexAppServerPeer) { self.peer = peer }

    func openAndResume(
        threadId: String,
        clientName: String,
        clientTitle: String,
        onNotification: NotificationHandler? = nil,
        deadline: DispatchTime? = nil
    ) throws -> JSONValue {
        try prepare(deadline)
        try peer.open()
        _ = try call(
            "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string(clientName),
                    "title": .string(clientTitle),
                    "version": .string("1"),
                ]),
            ]),
            onNotification: onNotification,
            deadline: deadline
        )
        try notify("initialized", params: .object([:]), deadline: deadline)
        return try call(
            "thread/resume",
            params: .object(["threadId": .string(threadId)]),
            onNotification: onNotification,
            deadline: deadline
        )
    }

    func call(
        _ method: String,
        params: JSONValue,
        onNotification: NotificationHandler? = nil,
        deadline: DispatchTime? = nil
    ) throws -> JSONValue {
        let id = nextID
        nextID += 1
        try prepare(deadline)
        try peer.send(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ]))

        while true {
            try prepare(deadline)
            let message = try peer.receive()
            try requireRemaining(deadline)
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
            handle(message, onNotification: onNotification)
        }
    }

    func receive(onNotification: NotificationHandler? = nil) throws {
        handle(try peer.receive(), onNotification: onNotification)
    }

    func shutdown() { peer.shutdown() }
    func close() { peer.close() }

    private func notify(_ method: String, params: JSONValue, deadline: DispatchTime?) throws {
        try prepare(deadline)
        try peer.send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func prepare(_ deadline: DispatchTime?) throws {
        try requireRemaining(deadline)
        peer.setAttemptDeadline(deadline)
    }

    private func requireRemaining(_ deadline: DispatchTime?) throws {
        guard let deadline else { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            throw CodexAppServerError.deadlineExceeded
        }
    }

    private func handle(_ message: JSONValue, onNotification: NotificationHandler?) {
        // App-server broadcasts approval/input requests to every attached peer and accepts the first
        // response. Neither the observer nor the sender may answer on behalf of the co-present TUI.
        guard message["id"] == nil,
              let method = message["method"]?.stringValue
        else { return }
        onNotification?(method, message["params"] ?? .object([:]))
    }
}
