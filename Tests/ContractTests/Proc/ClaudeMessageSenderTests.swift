import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

@Suite("Claude native message sender — real UDS contract", .serialized)
struct ClaudeMessageSenderTests {
    @Test("writes exact JSON auth and user frames, then closes the connection")
    func exactFramesAndClose() async throws {
        let path = Self.socketPath()
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = SocketReadResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }
            result.store(Self.readToEOF(client))
        }
        server.stackSize = 1 << 20
        server.start()

        let sender = try #require(ClaudeCodeAdapter().makeMessageSender(for: .claudeHookRPC(
            socketPath: path,
            token: "runtime-secret"
        )))
        let message = "hello\nfrom \"Orchestra\""
        try await sender.send(message)
        #expect(await Self.wait(finished) == .success)
        sender.shutdown()

        #expect(result.error == nil)
        let bytes = try #require(result.data)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        try #require(lines.count == 3)
        #expect(lines[2].isEmpty)
        #expect(try JSONValue.parse(Data(lines[0])) == .object([
            "type": .string("auth"),
            "token": .string("runtime-secret"),
        ]))
        #expect(try JSONValue.parse(Data(lines[1])) == .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .string(message),
            ]),
        ]))
    }

    @Test("a connect failure does not poison a later send on the same sender")
    func connectionFailureDoesNotPoisonSender() async throws {
        let path = Self.socketPath()
        let sender = try #require(ClaudeCodeAdapter().makeMessageSender(for: .claudeHookRPC(
            socketPath: path,
            token: "runtime-secret"
        )))

        await #expect(throws: (any Error).self) { try await sender.send("before listener") }

        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = SocketReadResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }
            result.store(Self.readToEOF(client))
        }
        server.stackSize = 1 << 20
        server.start()

        try await sender.send("after listener")
        #expect(await Self.wait(finished) == .success)
        sender.shutdown()

        #expect(result.error == nil)
        let bytes = try #require(result.data)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        try #require(lines.count == 3)
        #expect(lines[2].isEmpty)
        #expect(try JSONValue.parse(Data(lines[0])) == .object([
            "type": .string("auth"),
            "token": .string("runtime-secret"),
        ]))
        #expect(try JSONValue.parse(Data(lines[1])) == .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .string("after listener"),
            ]),
        ]))
    }

    @Test("shutdown holds descriptor ownership while interrupting an in-flight write, then rejects later sends")
    func shutdownInterruptsWriteAndRejectsLaterSends() async throws {
        let path = Self.socketPath()
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let sawAuth = DispatchSemaphore(value: 0)
        let drain = DispatchSemaphore(value: 0)
        let serverFinished = DispatchSemaphore(value: 0)
        let serverResult = SocketReadResult()
        let server = Thread {
            defer { serverFinished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                serverResult.fail("accept failed")
                sawAuth.signal()
                return
            }
            defer { closeFD(client) }
            serverResult.store(Self.readFirstLine(client))
            sawAuth.signal()
            _ = drain.wait(timeout: .now() + 10)
            _ = Self.readToEOF(client)
        }
        server.stackSize = 1 << 20
        server.start()

        let stateLock = NSLock()
        let shutdownObservation = ShutdownObservation()
        let sender: any AgentMessageSender = ClaudeMessageSender(
            socketPath: path,
            token: "runtime-secret",
            stateLock: stateLock,
            shutdownDescriptor: { fd in
                let acquiredOutsideLock = stateLock.try()
                if acquiredOutsideLock { stateLock.unlock() }
                shutdownObservation.store(wasLocked: !acquiredOutsideLock)
                shutdownFD(fd)
            }
        )
        let sendFinished = DispatchSemaphore(value: 0)
        let sendResult = SendResult()
        _Concurrency.Task {
            do {
                try await sender.send(String(repeating: "x", count: 32 * 1024 * 1024))
                sendResult.succeed()
            } catch {
                sendResult.fail()
            }
            sendFinished.signal()
        }

        let authArrived = await Self.wait(sawAuth) == .success
        sender.shutdown()
        let sendStopped = await Self.wait(sendFinished) == .success
        drain.signal()
        let serverStopped = await Self.wait(serverFinished) == .success

        #expect(authArrived)
        #expect(sendStopped)
        #expect(serverStopped)
        #expect(sendResult.failed)
        #expect(shutdownObservation.wasLocked == true)
        let authLine = try #require(serverResult.data)
        #expect(try JSONValue.parse(authLine) == .object([
            "type": .string("auth"),
            "token": .string("runtime-secret"),
        ]))
        await #expect(throws: (any Error).self) { try await sender.send("after shutdown") }
    }

    private static func socketPath() -> String {
        "/tmp/orch-claude-msg-\(UUID().uuidString.prefix(8)).sock"
    }

    private static func readFirstLine(_ fd: Int32) -> Data? {
        var result = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while let count = UDS.read(fd, into: &byte) {
            guard count > 0 else { continue }
            result.append(byte[0])
            if byte[0] == 0x0A { return result }
        }
        return nil
    }

    private static func readToEOF(_ fd: Int32) -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while let count = UDS.read(fd, into: &bytes) {
            if count > 0 { result.append(contentsOf: bytes[0..<count]) }
        }
        return result
    }

    private static func wait(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10))
            }
        }
    }
}

private final class ShutdownObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasLocked: Bool?

    var wasLocked: Bool? { lock.withLock { storedWasLocked } }
    func store(wasLocked: Bool) { lock.withLock { storedWasLocked = wasLocked } }
}

private final class SocketReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedError: String?

    var data: Data? { lock.withLock { storedData } }
    var error: String? { lock.withLock { storedError } }

    func store(_ data: Data?) { lock.withLock { storedData = data } }
    func fail(_ error: String) { lock.withLock { storedError = error } }
}

private final class SendResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false

    var failed: Bool { lock.withLock { didFail } }
    func succeed() { lock.withLock { didFail = false } }
    func fail() { lock.withLock { didFail = true } }
}
