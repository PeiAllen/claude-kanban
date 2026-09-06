import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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

    @Test("a saturated listener bounds the sender's connect before shutdown")
    func socketConnectDeadlineDoesNotRelyOnTaskCancellation() async throws {
        let path = Self.socketPath()
        let listener = try UDS.listen(path: path, backlog: 1)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        // Never accept. Fill the small listener queue first; later connects must wait at the kernel boundary
        // until their real deadline, rather than being rescued by cancelling their Swift task.
        var queued: [Int32] = []
        defer { for fd in queued { closeFD(fd) } }
        for _ in 0..<8 {
            if let fd = try? UDS.connect(path: path, ioTimeout: 0.025) { queued.append(fd) }
        }
        #expect(!queued.isEmpty)

        let sender = try #require(ClaudeCodeAdapter().makeMessageSender(for: .claudeHookRPC(
            socketPath: path,
            token: "runtime-secret"
        )))
        let result = SendResult()
        let finished = DispatchSemaphore(value: 0)
        _Concurrency.Task {
            result.markStarted()
            do {
                try await sender.send("connect deadline", timeout: 0.05)
                result.succeed()
            } catch {
                result.fail()
            }
            finished.signal()
        }

        let completed = await Self.wait(finished) == .success
        sender.shutdown()

        #expect(completed)
        #expect(result.failed)
        let startedAt = try #require(result.startedAt)
        let finishedAt = try #require(result.finishedAt)
        // The deadline itself is real production behavior (a `poll(2)`-bound connect against
        // `DispatchTime.now()`, see `UDSSocket.swift`) — this bound only checks it fires SOON after,
        // not instantly, so `deadlineMargin` is documented once, beside the sibling write-deadline
        // test below.
        #expect(finishedAt - startedAt < 50_000_000 + Self.deadlineMargin)
    }

    @Test("a peer that stops reading fails the socket-bound send deadline before shutdown")
    func socketWriteDeadlineDoesNotRelyOnTaskCancellation() async throws {
        let path = Self.socketPath()
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = SendResult()
        let serverStarted = DispatchSemaphore(value: 0)
        let releasePeer = DispatchSemaphore(value: 0)
        let serverFinished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { serverFinished.signal() }
            serverStarted.signal()
            let client = UDS.accept(listener)
            guard client >= 0 else { return }
            defer { closeFD(client) }
            var receiveBuffer: Int32 = 64 * 1024
            guard setsockopt(
                client, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { return }
            // A generous safety net, not the primary synchronization — the test signals `releasePeer`
            // once it is done. Kept clearly above the send's own deadline+margin ceiling (5s) so it
            // never fires first under load and short-circuits the intended sequencing.
            _ = releasePeer.wait(timeout: .now() + 60)
        }
        server.stackSize = 1 << 20
        server.start()
        #expect(await Self.wait(serverStarted) == .success)

        let sender = try #require(ClaudeCodeAdapter().makeMessageSender(for: .claudeHookRPC(
            socketPath: path,
            token: "runtime-secret"
        )))
        // Keep encoding well below the attempt deadline even under full-suite load. The peer's small
        // receive buffer makes this payload ample to force the real socket write into backpressure.
        let message = String(repeating: "x", count: 4 * 1024 * 1024)
        // Stamped here, not on the server thread: this measures `send`'s own observable duration —
        // the same boundary the sibling connect-deadline test above uses — rather than also folding in
        // accept()/setsockopt() skew and the 4MB encode that precede it.
        result.markStarted()
        do {
            try await sender.send(message, timeout: 2)
            result.succeed()
        } catch {
            result.fail()
        }

        sender.shutdown()
        releasePeer.signal()
        let peerClosed = await Self.wait(serverFinished) == .success

        #expect(peerClosed)
        #expect(result.failed)
        let finishedAt = try #require(result.finishedAt)
        let startedAt = try #require(result.startedAt)
        // The 2s deadline is real production behavior (a `poll(2)`-bound write against
        // `DispatchTime.now()`, see `writeUntilDeadline` in `UDSSocket.swift`) — pinning it here IS
        // the contract this suite exists for, so this stays a real wall-clock assertion rather than
        // an injected clock. But it must not race a stopwatch with thin headroom: measured under one
        // concurrent `xcodebuild`, this took 2.710s against the old 2.5s bound (a mere 500ms margin,
        // ~15% of the timeout) — the thread noticing "the deadline passed" and resuming through the
        // continuation needs real CPU time that a loaded machine doesn't hand out promptly.
        // `deadlineMargin` is generous enough to absorb that noise while staying far short of this
        // test's own 60s backstop (`releasePeer`'s wait), so a genuinely regressed deadline (one that
        // silently falls back to that backstop instead of firing on its own) still fails this bound.
        #expect(finishedAt - startedAt < 2_000_000_000 + Self.deadlineMargin)
    }

    /// Real-clock margin added on top of a configured send/connect timeout when asserting the
    /// operation finishes "soon after" its own deadline, not merely "eventually". Scheduling noise
    /// between "the deadline passed" and "this thread got CPU to notice and resume" grows under a
    /// loaded machine (concurrent `xcodebuild`/another card's build) — this margin absorbs that,
    /// never a broken deadline: a regressed one either fires close to on time (nowhere near this
    /// bound) or never fires at all (the test then hangs on its own backstop, not silently passes).
    /// Extrapolated, not guessed: the one measured overshoot (210ms over the old 2.5s bound, under a
    /// SINGLE concurrent build) scaled by this project's own documented worst-case build-contention
    /// multiplier (three concurrent builds run 520s each vs 165s alone, ~3.15x) gives ~2.2s — 3s
    /// leaves headroom above that without being so loose it stops catching a real regression. It is a
    /// flat addition, not scaled to each test's own configured deadline: the noise being absorbed is
    /// scheduler-noticing latency, which does not scale with how long the operation was told to wait.
    private static let deadlineMargin: UInt64 = 3_000_000_000   // 3s

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
            // A generous safety net, not the primary synchronization — the test signals `drain` once
            // it is done observing. Kept clearly above `Self.wait`'s own bound so it never fires
            // first under load and short-circuits the intended sequencing.
            _ = drain.wait(timeout: .now() + 60)
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

    /// Wait for a real OS thread (the in-process peer, spawned via `Thread`) to signal, off a
    /// `.userInitiated` queue rather than `.utility`: under a loaded machine, `.utility` work is the
    /// first thing the scheduler deprioritizes, so dispatching the WAIT itself on that QoS could eat
    /// into the very budget meant to absorb the peer thread's own scheduling delay. Measured: under one
    /// concurrent `swift build -c release`, a plain `Thread`'s accept()+read() cycle plus this wait's
    /// own dispatch missed the old 10s bound outright — 60s is the same order of magnitude already
    /// used for `pollUntil`'s real-world-load backstops elsewhere in this suite.
    private static func wait(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 60))
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
    private var startedAtNanos: UInt64?
    private var finishedAtNanos: UInt64?

    var failed: Bool { lock.withLock { didFail } }
    var startedAt: UInt64? { lock.withLock { startedAtNanos } }
    var finishedAt: UInt64? { lock.withLock { finishedAtNanos } }
    func markStarted() { lock.withLock { startedAtNanos = DispatchTime.now().uptimeNanoseconds } }
    func succeed() { lock.withLock { didFail = false; finishedAtNanos = DispatchTime.now().uptimeNanoseconds } }
    func fail() { lock.withLock { didFail = true; finishedAtNanos = DispatchTime.now().uptimeNanoseconds } }
}
