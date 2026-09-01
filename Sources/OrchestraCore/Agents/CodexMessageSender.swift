import Foundation

/// A one-shot app-server submission. Every send owns a fresh peer so notifications not consumed while
/// awaiting its response cannot become state or contaminate a later message attempt.
final class CodexMessageSender: AgentMessageSender, @unchecked Sendable {
    private enum Failure: Error {
        case shutDown
    }

    private let socketPath: String
    private let threadId: String
    private let peerFactory: @Sendable (String, TimeInterval) -> any CodexAppServerPeer
    private let queue = DispatchQueue(label: "com.orchestra.codex-message-sender", qos: .utility)
    private let stateLock = NSLock()
    private var isShutDown = false
    private var activePeer: (any CodexAppServerPeer)?

    init(socketPath: String, threadId: String) {
        self.socketPath = socketPath
        self.threadId = threadId
        self.peerFactory = { WebSocketCodexAppServerPeer(socketPath: $0, ioTimeout: $1) }
    }

    init(
        socketPath: String,
        threadId: String,
        peerFactory: @escaping @Sendable (String) -> any CodexAppServerPeer
    ) {
        self.socketPath = socketPath
        self.threadId = threadId
        self.peerFactory = { path, _ in peerFactory(path) }
    }

    func send(_ message: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try sendBlocking(message, timeout: timeout)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        stateLock.withLock {
            isShutDown = true
            activePeer?.shutdown()
        }
    }

    private func sendBlocking(_ message: String, timeout: TimeInterval) throws {
        guard stateLock.withLock({ !isShutDown }) else { throw Failure.shutDown }
        let deadline = DispatchTime.now() + .nanoseconds(Int(max(0, timeout) * 1_000_000_000))
        let peer = peerFactory(socketPath, timeout)
        let accepted = stateLock.withLock {
            guard !isShutDown else { return false }
            activePeer = peer
            return true
        }
        guard accepted else { throw Failure.shutDown }
        defer {
            stateLock.withLock {
                if activePeer === peer { activePeer = nil }
            }
            peer.close()
        }

        let client = CodexAppServerClient(peer: peer)
        _ = try client.openAndResume(
            threadId: threadId,
            clientName: "orchestra-inbox",
            clientTitle: "Orchestra inbox sender",
            deadline: deadline
        )
        guard stateLock.withLock({ !isShutDown }) else { throw Failure.shutDown }
        _ = try client.call(
            "turn/start",
            params: .object([
                "threadId": .string(threadId),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(message),
                ])]),
            ]),
            deadline: deadline
        )
    }
}
