import Foundation
import Testing
@testable import OrchestraCore

@Suite("Transport + reconnect", .serialized)
struct TransportReconnectTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("UDSTransport open/write/readLine round-trips a ping against ControlServer")
    func udsRoundTrip() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let t = UDSTransport(socketPath: path)
        try t.open()
        defer { t.close() }
        let line = try RPCCodec.line(RPCRequest(id: 1, method: "ping"))
        #expect(t.write(line))
        let reply = try #require(t.readLine())
        let msg = try RPCCodec.decoder.decode(WireMessage.self, from: reply)
        #expect(msg.result?["ok"]?.boolValue == true)
    }

    // MARK: - reconnect (fake transport)

    /// A controllable fake transport. Each instance owns its own EOF signal + line queue (so closing a
    /// dead transport can't leak an EOF into the next one). The shared `FakeBox` counts opens/subscribes
    /// across reconnects and tracks the currently-open instance so a test can drop it mid-stream.
    final class FakeTransport: Transport, @unchecked Sendable {
        let box: FakeBox
        private let lock = NSLock()
        private let sema = DispatchSemaphore(value: 0)
        private var eofFlag = false
        private var lines: [Data] = []
        init(_ box: FakeBox) { self.box = box }
        func open() throws {
            box.opened(self)
            // Simulate "transport up, daemon dead" (SSH connects, daemon socket refuses): the stream EOFs
            // immediately, so the client's `version` probe reads nil and the open is rejected — never `.live`.
            if !box.answerVersion { close() }
        }
        func write(_ data: Data) -> Bool {
            box.record(data)
            // Stand in for a live daemon: answer the `version` probe (ControlClient now gates `.live` on
            // it, #10) so the fake reconnect flow reaches `.live` exactly as a real one does.
            if box.answerVersion, let req = try? RPCCodec.decoder.decode(RPCRequest.self, from: data),
               req.method == "version", let id = req.id {
                let resp = (try? RPCCodec.line(RPCResponse(id: id, result: .object(["version": .string("fake")])))) ?? Data()
                lock.withLock { lines.append(resp) }
                sema.signal()
            }
            return true
        }
        func readLine() -> Data? {
            while true {
                sema.wait()
                let r: Data?? = lock.withLock {
                    if eofFlag { return .some(nil) }
                    if !lines.isEmpty { return .some(lines.removeFirst()) }
                    return nil
                }
                if let r { return r }
            }
        }
        func close() { lock.withLock { eofFlag = true }; sema.signal() }
    }

    final class FakeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Data] = []
        private var opensCount = 0
        private weak var current: FakeTransport?
        /// When true (default), the fake answers the `version` probe so the client reaches `.live`. Set
        /// false to simulate "transport up, daemon dead" — the probe EOFs and the open is rejected.
        let answerVersion: Bool
        init(answerVersion: Bool = true) { self.answerVersion = answerVersion }
        func opened(_ t: FakeTransport) { lock.withLock { opensCount += 1; current = t } }
        func record(_ d: Data) { lock.withLock { writes.append(d) } }
        /// Simulate a mid-stream drop: EOF the currently-open transport only.
        func dropCurrent() { let t = lock.withLock { current }; t?.close() }
        var opens: Int { lock.withLock { opensCount } }
        var subscribeCount: Int {
            lock.withLock {
                writes.filter { (try? RPCCodec.decoder.decode(RPCRequest.self, from: $0))?.method == "subscribe" }.count
            }
        }
        /// The clientId carried by each `subscribe` frame that was written (in write order).
        var subscribeClientIds: [String?] {
            lock.withLock {
                writes.compactMap { try? RPCCodec.decoder.decode(RPCRequest.self, from: $0) }
                      .filter { $0.method == "subscribe" }
                      .map { $0.clientId }
            }
        }
    }

    @Test("dropped transport → state goes live → retrying → live and re-subscribes")
    func reconnectResubscribes() async throws {
        let box = FakeBox()
        let states = StateBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        client.onState = { s in _Concurrency.Task { await states.add(s) } }
        try client.connect()
        _ = client.subscribe()                                     // sends subscribe #1
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(box.subscribeCount == 1)

        box.dropCurrent()                                          // drop mid-stream
        try await _Concurrency.Task.sleep(for: .milliseconds(700)) // let backoff + reconnect run
        #expect(box.opens >= 2)                                    // reconnected with a fresh transport
        #expect(box.subscribeCount == 2)                           // re-subscribed on the new transport
        let seen = await states.values
        #expect(seen.contains(.retrying))
        #expect(seen.last == .live)
        client.close()
    }

    @Test("close() stops the client: it does not reconnect and ends in .down")
    func closeStopsReconnect() async throws {
        let box = FakeBox()
        let states = StateBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        client.onState = { s in _Concurrency.Task { await states.add(s) } }
        try client.connect()
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        client.close()
        try await _Concurrency.Task.sleep(for: .milliseconds(500))
        #expect(box.opens == 1)                                    // never reconnected after an intentional close
        #expect(await states.values.last == .down)
    }
    @Test("clientId is stamped on requests and preserved across a reconnect")
    func clientIdAcrossReconnect() async throws {
        let box = FakeBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app, clientId: "phone-xyz")
        try client.connect()
        _ = client.subscribe()                                       // subscribe #1
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        box.dropCurrent()                                            // force a reconnect
        try await _Concurrency.Task.sleep(for: .milliseconds(700))   // backoff + reconnect + re-subscribe
        let ids = box.subscribeClientIds
        #expect(ids.count >= 2)                                      // subscribed on both transports
        #expect(ids.allSatisfy { $0 == "phone-xyz" })               // SAME id after reconnect
        client.close()
    }

    @Test("an anonymous client (nil clientId) writes no clientId — CLI/MCP back-compat")
    func anonymousClientNoId() async throws {
        let box = FakeBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .cli)   // clientId defaults nil
        try client.connect()
        _ = client.subscribe()
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(box.subscribeClientIds.allSatisfy { $0 == nil })
        client.close()
    }

    // MARK: - the sync-card fixes

    @Test("connect() is idempotent — a second call opens no second transport, spawns no second runLoop (#4)")
    func idempotentConnect() async throws {
        let box = FakeBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        try client.connect()
        try client.connect()                                       // no-op: a loop is already live
        try await _Concurrency.Task.sleep(for: .milliseconds(150))
        #expect(box.opens == 1)                                    // exactly one open, one runLoop
        client.close()
    }

    @Test("onReconnect fires on the reconnect edge only, not on the first connect (#1)")
    func onReconnectFiresOnlyOnReconnect() async throws {
        let box = FakeBox()
        let hits = Counter()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        client.onReconnect = { _Concurrency.Task { await hits.bump() } }
        try client.connect()
        _ = client.subscribe()
        try await _Concurrency.Task.sleep(for: .milliseconds(150))
        #expect(await hits.value == 0)                             // NOT on the first connect
        box.dropCurrent()                                          // force a reconnect
        try await _Concurrency.Task.sleep(for: .milliseconds(700))
        #expect(box.opens >= 2)
        #expect(await hits.value >= 1)                             // fired on the reconnect (re-assert hook)
        client.close()
    }

    @Test("a daemon that never answers `version` never reaches .live — version-gated open (#10)")
    func versionGateBlocksLive() async throws {
        let box = FakeBox(answerVersion: false)                    // transport opens, daemon is dead
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        #expect(throws: (any Error).self) { try client.connect() } // probe EOFs → open rejected
        #expect(client.state != .live)
        client.close()
    }

    // NOTE: real tunnel-death → reconnect against a live daemon is verified end-to-end in Workstream D
    // (D5). A ControlServer.stop()-based test can't stand in here: stop() closes only the listener, not
    // already-accepted client connections, so the link never actually drops.
}

actor StateBox {
    private(set) var values: [ConnectionState] = []
    func add(_ s: ConnectionState) { values.append(s) }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
