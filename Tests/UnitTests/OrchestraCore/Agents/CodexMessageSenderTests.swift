import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex native message sender")
struct CodexMessageSenderTests {
    @Test("each send uses a fresh initialized peer and ignores unrelated inbound messages")
    func oneShotRequestSequence() async throws {
        let resume: JSONValue = .object([
            "thread": .object(["id": .string("thread-1")]),
        ])
        let first = RecordingCodexPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.notification("thread/status/changed"),
            Self.serverRequest(id: 91),
            Self.response(id: 2, result: resume),
            Self.notification("turn/started"),
            Self.serverRequest(id: 92),
            Self.response(id: 3, result: .object([
                "turn": .object(["id": .string("turn-1")]),
            ])),
        ])
        let second = RecordingCodexPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: resume),
            Self.response(id: 3, result: .object([
                "turn": .object(["id": .string("turn-2")]),
            ])),
        ])
        let peers = CodexPeerFactory([first, second])
        let sender = CodexMessageSender(
            socketPath: "/runtime/codex.sock",
            threadId: "thread-1",
            peerFactory: { _ in peers.next() }
        )

        try await sender.send("first message")
        try await sender.send("second message")

        #expect(peers.makeCount == 2)
        #expect(first.didOpen && first.didClose)
        #expect(second.didOpen && second.didClose)
        #expect(first.sent.map { $0["method"]?.stringValue } == [
            "initialize", "initialized", "thread/resume", "turn/start",
        ])
        #expect(first.sent.map { $0["id"]?.intValue } == [1, nil, 2, 3])
        #expect(first.sent[0]["params"]?["clientInfo"]?["name"]?.stringValue == "orchestra-inbox")
        #expect(first.sent[2]["params"] == .object(["threadId": .string("thread-1")]))
        #expect(first.sent[3]["params"] == .object([
            "threadId": .string("thread-1"),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string("first message"),
            ])]),
        ]))
        #expect(!first.sent.contains { $0["id"]?.intValue == 91 || $0["id"]?.intValue == 92 })
        #expect(second.sent[3]["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue == "second message")
    }

    @Test("shutdown interrupts the active one-shot peer and rejects every later send")
    func shutdownInterruptsAndRejects() async throws {
        let peer = BlockingCodexPeer()
        let peers = CodexPeerFactory([peer])
        let sender = CodexMessageSender(
            socketPath: "/runtime/codex.sock",
            threadId: "thread-1",
            peerFactory: { _ in peers.next() }
        )
        let sendFinished = DispatchSemaphore(value: 0)
        let result = CodexSendResult()
        _Concurrency.Task {
            do { try await sender.send("blocked"); result.succeed() }
            catch { result.fail() }
            sendFinished.signal()
        }

        #expect(await Self.wait(peer.openedSignal) == .success)
        sender.shutdown()
        #expect(peer.shutdownCount == 1)
        #expect(await Self.wait(sendFinished) == .success)
        #expect(result.failed)
        #expect(peer.didClose)

        await #expect(throws: (any Error).self) { try await sender.send("too late") }
        #expect(peers.makeCount == 1)
    }

    @Test("a flood of unrelated notifications cannot extend one sender attempt past its deadline")
    func notificationFloodRespectsAbsoluteDeadline() async throws {
        let peer = NotificationFloodCodexPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: .object([
                "thread": .object(["id": .string("thread-1")]),
            ])),
        ])
        let sender = CodexMessageSender(
            socketPath: "/runtime/codex.sock",
            threadId: "thread-1",
            peerFactory: { _ in peer }
        )
        let finished = DispatchSemaphore(value: 0)
        let result = CodexSendResult()
        _Concurrency.Task {
            do { try await sender.send("deadline", timeout: 0.05); result.succeed() }
            catch { result.fail() }
            finished.signal()
        }

        let completedBeforeShutdown = await Self.wait(finished, timeout: 1) == .success
        sender.shutdown()
        if !completedBeforeShutdown {
            #expect(await Self.wait(finished) == .success)
        }

        #expect(completedBeforeShutdown)
        #expect(result.failed)
        #expect(peer.didClose)
    }

    @Test("a matching response already received at the deadline remains provider acceptance")
    func matchingResponseWinsAfterReceive() throws {
        let peer = LateMatchingResponseCodexPeer()
        let client = CodexAppServerClient(peer: peer)

        let result = try client.call(
            "turn/start",
            params: .object([:]),
            deadline: .now() + .milliseconds(100)
        )

        #expect(result == .object(["turn": .object(["id": .string("turn-1")])]))
    }

    private static func response(id: Int, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .int(id), "result": result])
    }

    private static func notification(_ method: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(["threadId": .string("thread-1")]),
        ])
    }

    private static func serverRequest(id: Int) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .object([:]),
        ])
    }

    private static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 10) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
            }
        }
    }
}

private class RecordingCodexPeer: CodexAppServerPeer, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [JSONValue]
    private var storedSent: [JSONValue] = []
    private var opened = false
    private var closed = false

    init(incoming: [JSONValue]) { self.incoming = incoming }

    var sent: [JSONValue] { lock.withLock { storedSent } }
    var didOpen: Bool { lock.withLock { opened } }
    var didClose: Bool { lock.withLock { closed } }

    func open() throws { lock.withLock { opened = true } }
    func send(_ message: JSONValue) throws { lock.withLock { storedSent.append(message) } }
    func receive() throws -> JSONValue {
        try lock.withLock {
            guard !incoming.isEmpty else { throw CodexAppServerError.connectionClosed }
            return incoming.removeFirst()
        }
    }
    func shutdown() {}
    func close() { lock.withLock { closed = true } }
}

private final class BlockingCodexPeer: RecordingCodexPeer, @unchecked Sendable {
    let openedSignal = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var shutdowns = 0

    init() { super.init(incoming: []) }

    var shutdownCount: Int { stateLock.withLock { shutdowns } }

    override func open() throws {
        try super.open()
        openedSignal.signal()
    }
    override func receive() throws -> JSONValue {
        _ = stopped.wait(timeout: .now() + 10)
        throw CodexAppServerError.connectionClosed
    }
    override func shutdown() {
        stateLock.withLock { shutdowns += 1 }
        stopped.signal()
    }
}

private final class NotificationFloodCodexPeer: RecordingCodexPeer, @unchecked Sendable {
    private let floodLock = NSLock()
    private var receiveCount = 0
    private var stopped = false

    override func receive() throws -> JSONValue {
        let setupResponse = floodLock.withLock { () -> Bool in
            receiveCount += 1
            return receiveCount <= 2
        }
        if setupResponse { return try super.receive() }
        Thread.sleep(forTimeInterval: 0.005)
        if floodLock.withLock({ stopped }) { throw CodexAppServerError.connectionClosed }
        return .object([
            "jsonrpc": .string("2.0"),
            "method": .string("thread/status/changed"),
            "params": .object(["threadId": .string("thread-1")]),
        ])
    }

    override func shutdown() { floodLock.withLock { stopped = true } }
}

private final class LateMatchingResponseCodexPeer: RecordingCodexPeer, @unchecked Sendable {
    init() { super.init(incoming: []) }

    override func receive() throws -> JSONValue {
        Thread.sleep(forTimeInterval: 0.15)
        return .object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "result": .object(["turn": .object(["id": .string("turn-1")])]),
        ])
    }
}

private final class CodexPeerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [any CodexAppServerPeer]
    private var count = 0

    init(_ peers: [any CodexAppServerPeer]) { self.peers = peers }
    var makeCount: Int { lock.withLock { count } }
    func next() -> any CodexAppServerPeer {
        lock.withLock {
            count += 1
            return peers.removeFirst()
        }
    }
}

private final class CodexSendResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false
    var failed: Bool { lock.withLock { didFail } }
    func succeed() { lock.withLock { didFail = false } }
    func fail() { lock.withLock { didFail = true } }
}
