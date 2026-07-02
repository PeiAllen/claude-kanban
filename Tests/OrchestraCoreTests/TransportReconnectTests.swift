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
        func open() throws { box.opened(self) }
        func write(_ data: Data) -> Bool { box.record(data); return true }
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
    // NOTE: real tunnel-death → reconnect against a live daemon is verified end-to-end in Workstream D
    // (D5). A ControlServer.stop()-based test can't stand in here: stop() closes only the listener, not
    // already-accepted client connections, so the link never actually drops.
}

actor StateBox {
    private(set) var values: [ConnectionState] = []
    func add(_ s: ConnectionState) { values.append(s) }
}
