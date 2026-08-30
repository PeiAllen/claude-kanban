import Foundation
import OrchestraKit

/// One-shot JSONL delivery into Claude Code's cross-session inbound socket. The serial queue owns every
/// blocking socket operation so no connect or write can park Swift's cooperative executor. `shutdown()`
/// only wakes the active descriptor; the queue that opened it remains its sole closer.
final class ClaudeMessageSender: AgentMessageSender, @unchecked Sendable {
    private struct AuthFrame: Encodable {
        let type = "auth"
        let token: String
    }

    private struct UserFrame: Encodable {
        struct Message: Encodable {
            let role = "user"
            let content: String
        }

        let type = "user"
        let message: Message
    }

    private enum Failure: Error {
        case shutDown
        case writeFailed
    }

    private let socketPath: String
    private let token: String
    private let shutdownDescriptor: @Sendable (Int32) -> Void
    private let queue = DispatchQueue(label: "com.orchestra.claude-message-sender", qos: .utility)
    private let stateLock: NSLock
    private var isShutDown = false
    private var activeFD: Int32?

    init(
        socketPath: String,
        token: String,
        stateLock: NSLock = NSLock(),
        shutdownDescriptor: @escaping @Sendable (Int32) -> Void = shutdownFD
    ) {
        self.socketPath = socketPath
        self.token = token
        self.stateLock = stateLock
        self.shutdownDescriptor = shutdownDescriptor
    }

    func send(_ message: String) async throws {
        try await send(message, timeout: 15)
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
            if let activeFD { shutdownDescriptor(activeFD) }
        }
    }

    private func sendBlocking(_ message: String, timeout: TimeInterval) throws {
        guard stateLock.withLock({ !isShutDown }) else { throw Failure.shutDown }
        let deadline = DispatchTime.now() + .nanoseconds(Int(max(0, timeout) * 1_000_000_000))
        let frames = try [
            Self.jsonLine(AuthFrame(token: token)),
            Self.jsonLine(UserFrame(message: .init(content: message))),
        ]
        guard stateLock.withLock({ !isShutDown }) else { throw Failure.shutDown }

        let fd = try UDS.connect(path: socketPath, ioTimeout: Self.remainingTime(until: deadline))
        let accepted = stateLock.withLock {
            guard !isShutDown else { return false }
            activeFD = fd
            return true
        }
        guard accepted else {
            closeFD(fd)
            throw Failure.shutDown
        }
        defer {
            stateLock.withLock {
                if activeFD == fd { activeFD = nil }
            }
            closeFD(fd)
        }

        for frame in frames {
            guard UDS.writeAll(fd, frame, deadline: deadline) else { throw Failure.writeFailed }
        }
    }

    private static func remainingTime(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return 0 }
        return TimeInterval(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private static func jsonLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}
