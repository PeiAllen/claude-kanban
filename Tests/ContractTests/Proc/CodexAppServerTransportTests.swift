import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

@Suite("Codex app-server transport", .serialized)
struct CodexAppServerTransportTests {
    @Test("real UDS WebSocket composes upgrade, RPC setup, control frames, fragmentation, and close")
    func composedTransport() throws {
        let path = "/tmp/orch-codex-ws-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = CodexTransportServerResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }

            do {
                var pending = Data()
                let request = try Self.readHTTPRequest(client, pending: &pending)
                let key = try Self.webSocketKey(in: request)
                let response = "HTTP/1.1 101 Switching Protocols\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(WebSocketHandshake.accept(for: key))\r\n\r\n"
                guard UDS.writeAll(client, Data(response.utf8)) else {
                    throw CodexTransportServerError.writeFailed
                }

                let initialize = try Self.readJSON(client, pending: &pending)
                result.append(initialize)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": initialize["id"] ?? .int(-1),
                    "result": .object([:]),
                ]))

                result.append(try Self.readJSON(client, pending: &pending))
                let resume = try Self.readJSON(client, pending: &pending)
                result.append(resume)
                let resumeResult: JSONValue = .object([
                    "thread": .object([
                        "id": .string("thread-1"),
                        "status": .object(["type": .string("idle")]),
                    ]),
                ])
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": resume["id"] ?? .int(-1),
                    "result": resumeResult,
                ]))

                try Self.sendFrame(client, .init(
                    fin: true,
                    opcode: .ping,
                    payload: Data("pulse".utf8)
                ))
                let pong = try Self.readFrame(client, pending: &pending)
                result.setPong(pong)

                let notification = try JSONValue.object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("turn/started"),
                    "params": .object([
                        "threadId": .string("thread-1"),
                        "turn": .object(["id": .string("turn-1")]),
                    ]),
                ]).rawData()
                let midpoint = notification.count / 2
                try Self.sendFrame(client, .init(
                    fin: false,
                    opcode: .text,
                    payload: notification.prefix(midpoint)
                ))
                try Self.sendFrame(client, .init(
                    fin: true,
                    opcode: .continuation,
                    payload: notification.suffix(from: midpoint)
                ))
                try Self.sendFrame(client, .init(fin: true, opcode: .close, payload: Data()))
                result.setClose(try Self.readFrame(client, pending: &pending))
            } catch {
                result.fail(String(describing: error))
            }
        }
        server.stackSize = 1 << 20
        server.start()

        let observer = CodexAppServerObserver(socketPath: path)
        var observations: [RawTelemetry] = []
        #expect(throws: CodexAppServerError.connectionClosed) {
            try observer.run(threadId: "thread-1") { observations.append($0) }
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)

        #expect(result.error == nil)
        #expect(result.messages.map { $0["method"]?.stringValue } == [
            "initialize", "initialized", "thread/resume",
        ])
        #expect(result.messages[2]["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(result.pong == .init(fin: true, opcode: .pong, payload: Data("pulse".utf8)))
        #expect(result.close?.opcode == .close)
        #expect(observations == [
            .rpcResponse(method: "thread/resume", result: .object([
                "thread": .object([
                    "id": .string("thread-1"),
                    "status": .object(["type": .string("idle")]),
                ]),
            ])),
            .rpcNotification(method: "turn/started", params: .object([
                "threadId": .string("thread-1"),
                "turn": .object(["id": .string("turn-1")]),
            ])),
        ])
    }

    @Test("native sender composes exact initialize, resume, and turn/start sequence over real UDS WebSocket")
    func composedNativeSenderSequence() async throws {
        let path = "/tmp/orch-codex-send-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = CodexTransportServerResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }

            do {
                var pending = Data()
                try Self.upgrade(client, pending: &pending)

                let initialize = try Self.readJSON(client, pending: &pending)
                result.append(initialize)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": initialize["id"] ?? .int(-1),
                    "result": .object([:]),
                ]))

                result.append(try Self.readJSON(client, pending: &pending))
                let resume = try Self.readJSON(client, pending: &pending)
                result.append(resume)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("thread/status/changed"),
                    "params": .object([
                        "threadId": .string("thread-1"),
                        "status": .object(["type": .string("active")]),
                    ]),
                ]))
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(91),
                    "method": .string("item/commandExecution/requestApproval"),
                    "params": .object([:]),
                ]))
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": resume["id"] ?? .int(-1),
                    "result": .object([
                        "thread": .object([
                            "id": .string("thread-1"),
                            "status": .object(["type": .string("active")]),
                        ]),
                    ]),
                ]))

                let turnStart = try Self.readJSON(client, pending: &pending)
                result.append(turnStart)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("turn/started"),
                    "params": .object([
                        "threadId": .string("thread-1"),
                        "turn": .object(["id": .string("turn-1")]),
                    ]),
                ]))
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(92),
                    "method": .string("item/fileChange/requestApproval"),
                    "params": .object([:]),
                ]))
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": turnStart["id"] ?? .int(-1),
                    "result": .object([
                        "turn": .object(["id": .string("turn-1")]),
                    ]),
                ]))
                try Self.expectEOF(client, pending: &pending)
                result.setEOF()
            } catch {
                result.fail(String(describing: error))
            }
        }
        server.stackSize = 1 << 20
        server.start()

        let sender = try #require(CodexAdapter().makeMessageSender(for: .codexAppServer(
            socketPath: path,
            threadId: "thread-1"
        )))
        try await sender.send("hello from Orchestra")
        #expect(await Self.wait(finished) == .success)
        sender.shutdown()

        #expect(result.error == nil)
        #expect(result.sawEOF)
        #expect(result.messages.map { $0["method"]?.stringValue } == [
            "initialize", "initialized", "thread/resume", "turn/start",
        ])
        #expect(result.messages.map { $0["id"]?.intValue } == [1, nil, 2, 3])
        #expect(result.messages[0]["params"]?["clientInfo"]?["name"]?.stringValue == "orchestra-inbox")
        #expect(result.messages[2]["params"] == .object(["threadId": .string("thread-1")]))
        #expect(result.messages[3]["params"] == .object([
            "threadId": .string("thread-1"),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string("hello from Orchestra"),
            ])]),
        ]))
    }

    @Test("continuous unrelated notifications cannot outlive a real sender attempt deadline")
    func notificationFloodStopsAtAbsoluteDeadline() async throws {
        let path = "/tmp/orch-codex-flood-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = CodexTransportServerResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }

            do {
                var pending = Data()
                try Self.upgrade(client, pending: &pending)
                let initialize = try Self.readJSON(client, pending: &pending)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": initialize["id"] ?? .int(-1),
                    "result": .object([:]),
                ]))
                _ = try Self.readJSON(client, pending: &pending) // initialized
                let resume = try Self.readJSON(client, pending: &pending)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": resume["id"] ?? .int(-1),
                    "result": .object(["thread": .object(["id": .string("thread-1")])]),
                ]))
                _ = try Self.readJSON(client, pending: &pending) // turn/start

                let notification: JSONValue = .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("thread/status/changed"),
                    "params": .object(["threadId": .string("thread-1")]),
                ])
                let frame = try WebSocketFrameCodec.encode(
                    .init(fin: true, opcode: .text, payload: notification.rawData()),
                    maskKey: nil
                )
                for _ in 0..<400 {
                    guard UDS.writeAll(client, frame) else {
                        result.setEOF()
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                result.fail("sender did not stop at its deadline")
            } catch {
                result.fail(String(describing: error))
            }
        }
        server.stackSize = 1 << 20
        server.start()

        let sender = try #require(CodexAdapter().makeMessageSender(for: .codexAppServer(
            socketPath: path,
            threadId: "thread-1"
        )))
        await #expect(throws: (any Error).self) {
            try await sender.send("deadline", timeout: 0.1)
        }
        #expect(await Self.wait(finished) == .success)
        sender.shutdown()

        #expect(result.error == nil)
        #expect(result.sawEOF)
    }

    @Test("continuous WebSocket control frames cannot outlive a real sender attempt deadline")
    func controlFrameFloodStopsAtAbsoluteDeadline() async throws {
        let controlFrameCount = 4_000
        let path = "/tmp/orch-codex-control-flood-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = CodexTransportServerResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            let floodWriterDone = DispatchSemaphore(value: 0)
            var floodWriterStarted = false
            defer {
                closeFD(client)
                if floodWriterStarted {
                    _ = floodWriterDone.wait(timeout: .now() + 1)
                }
            }

            do {
                var pending = Data()
                try Self.upgrade(client, pending: &pending)
                let initialize = try Self.readJSON(client, pending: &pending)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": initialize["id"] ?? .int(-1),
                    "result": .object([:]),
                ]))
                _ = try Self.readJSON(client, pending: &pending) // initialized
                let resume = try Self.readJSON(client, pending: &pending)
                try Self.sendJSON(client, .object([
                    "jsonrpc": .string("2.0"),
                    "id": resume["id"] ?? .int(-1),
                    "result": .object(["thread": .object(["id": .string("thread-1")])]),
                ]))
                _ = try Self.readJSON(client, pending: &pending) // turn/start

                // Deliver one buffered batch. The server drains each pong, so an old peer cannot escape
                // its read deadline merely because its writes block.
                let frame = try WebSocketFrameCodec.encode(
                    .init(fin: true, opcode: .ping, payload: Data("pulse".utf8)),
                    maskKey: nil
                )
                let flood: Data = {
                    var data = Data()
                    for _ in 0..<controlFrameCount { data.append(frame) }
                    return data
                }()
                let floodWriter = Thread {
                    defer { floodWriterDone.signal() }
                    if !UDS.writeAll(client, flood) { result.setEOF() }
                }
                floodWriterStarted = true
                floodWriter.start()
                while true {
                    let response = try Self.readFrame(client, pending: &pending)
                    guard response.opcode == .pong else {
                        result.fail("expected pong while draining control-frame flood")
                        return
                    }
                    result.recordPong()
                }
            } catch CodexTransportServerError.connectionClosed {
                result.setEOF()
            } catch {
                result.fail(String(describing: error))
            }
        }
        server.stackSize = 1 << 20
        server.start()

        let sender = try #require(CodexAdapter().makeMessageSender(for: .codexAppServer(
            socketPath: path,
            threadId: "thread-1"
        )))
        await #expect(throws: (any Error).self) {
            try await sender.send("deadline", timeout: 0.1)
        }
        #expect(await Self.wait(finished) == .success)
        sender.shutdown()

        #expect(result.error == nil)
        #expect(result.sawEOF)
        #expect(result.pongCount > 0)
        #expect(result.pongCount < controlFrameCount)
    }

    @Test("WebSocket peer holds descriptor ownership while shutdown interrupts the live connection")
    func shutdownHoldsDescriptorOwnership() throws {
        let path = "/tmp/orch-codex-stop-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: path)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let result = CodexTransportServerResult()
        let finished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { finished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else {
                result.fail("accept failed")
                return
            }
            defer { closeFD(client) }
            do {
                var pending = Data()
                try Self.upgrade(client, pending: &pending)
                try Self.expectEOF(client, pending: &pending)
                result.setEOF()
            } catch {
                result.fail(String(describing: error))
            }
        }
        server.stackSize = 1 << 20
        server.start()

        let stateLock = NSLock()
        let shutdownObservation = CodexDescriptorShutdownObservation()
        let peer = WebSocketCodexAppServerPeer(
            socketPath: path,
            stateLock: stateLock,
            shutdownDescriptor: { fd in
                let acquiredOutsideLock = stateLock.try()
                if acquiredOutsideLock { stateLock.unlock() }
                shutdownObservation.store(wasLocked: !acquiredOutsideLock)
                shutdownFD(fd)
            }
        )
        try peer.open()
        peer.shutdown()
        peer.close()

        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(result.error == nil)
        #expect(result.sawEOF)
        #expect(shutdownObservation.wasLocked == true)
    }

    private static func upgrade(_ fd: Int32, pending: inout Data) throws {
        let request = try readHTTPRequest(fd, pending: &pending)
        let key = try webSocketKey(in: request)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketHandshake.accept(for: key))\r\n\r\n"
        guard UDS.writeAll(fd, Data(response.utf8)) else {
            throw CodexTransportServerError.writeFailed
        }
    }

    private static func readHTTPRequest(_ fd: Int32, pending: inout Data) throws -> String {
        let delimiter = Data("\r\n\r\n".utf8)
        while pending.range(of: delimiter) == nil {
            try readMore(fd, pending: &pending)
        }
        guard let range = pending.range(of: delimiter) else {
            throw CodexTransportServerError.invalidHandshake
        }
        let header = pending.subdata(in: pending.startIndex..<range.lowerBound)
        pending.removeSubrange(pending.startIndex..<range.upperBound)
        guard let text = String(data: header, encoding: .utf8) else {
            throw CodexTransportServerError.invalidHandshake
        }
        return text
    }

    private static func webSocketKey(in request: String) throws -> String {
        for line in request.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sec-websocket-key" {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        throw CodexTransportServerError.invalidHandshake
    }

    private static func readJSON(_ fd: Int32, pending: inout Data) throws -> JSONValue {
        let frame = try readFrame(fd, pending: &pending)
        guard frame.fin, frame.opcode == .text else {
            throw CodexTransportServerError.unexpectedFrame
        }
        return try JSONValue.parse(frame.payload)
    }

    private static func readFrame(_ fd: Int32, pending: inout Data) throws -> WebSocketFrame {
        while true {
            if let frame = try WebSocketFrameCodec.decode(from: &pending, expectedMask: true) {
                return frame
            }
            try readMore(fd, pending: &pending)
        }
    }

    private static func readMore(_ fd: Int32, pending: inout Data) throws {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            guard let count = UDS.read(fd, into: &bytes) else {
                throw CodexTransportServerError.connectionClosed
            }
            if count == 0 { continue }
            pending.append(contentsOf: bytes[0..<count])
            return
        }
    }

    private static func expectEOF(_ fd: Int32, pending: inout Data) throws {
        guard pending.isEmpty else { throw CodexTransportServerError.unexpectedFrame }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while let count = UDS.read(fd, into: &bytes) {
            if count > 0 { throw CodexTransportServerError.unexpectedFrame }
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10))
            }
        }
    }

    private static func sendJSON(_ fd: Int32, _ value: JSONValue) throws {
        try sendFrame(fd, .init(fin: true, opcode: .text, payload: try value.rawData()))
    }

    private static func sendFrame(_ fd: Int32, _ frame: WebSocketFrame) throws {
        let encoded = try WebSocketFrameCodec.encode(frame, maskKey: nil)
        guard UDS.writeAll(fd, encoded) else { throw CodexTransportServerError.writeFailed }
    }
}

private enum CodexTransportServerError: Error {
    case connectionClosed
    case invalidHandshake
    case unexpectedFrame
    case writeFailed
}

private final class CodexTransportServerResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [JSONValue] = []
    private var storedPong: WebSocketFrame?
    private var storedPongCount = 0
    private var storedClose: WebSocketFrame?
    private var storedSawEOF = false
    private var storedError: String?

    var messages: [JSONValue] { lock.withLock { storedMessages } }
    var pong: WebSocketFrame? { lock.withLock { storedPong } }
    var pongCount: Int { lock.withLock { storedPongCount } }
    var close: WebSocketFrame? { lock.withLock { storedClose } }
    var sawEOF: Bool { lock.withLock { storedSawEOF } }
    var error: String? { lock.withLock { storedError } }

    func append(_ message: JSONValue) { lock.withLock { storedMessages.append(message) } }
    func setPong(_ frame: WebSocketFrame) { lock.withLock { storedPong = frame } }
    func recordPong() { lock.withLock { storedPongCount += 1 } }
    func setClose(_ frame: WebSocketFrame) { lock.withLock { storedClose = frame } }
    func setEOF() { lock.withLock { storedSawEOF = true } }
    func fail(_ message: String) { lock.withLock { storedError = message } }
}

private final class CodexDescriptorShutdownObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasLocked: Bool?

    var wasLocked: Bool? { lock.withLock { storedWasLocked } }
    func store(wasLocked: Bool) { lock.withLock { storedWasLocked = wasLocked } }
}
