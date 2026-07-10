import Testing
import Foundation
@testable import OrchestraKit

/// A controllable transport for exercising `ControlClient`'s deadline / probe / ping paths without a
/// real daemon. Answers `version` calls (until `goDead()` / `answerVersion = false`), blocks `readLine`
/// until fed, and records the methods written in order (for the Task 6.3 barrier test).
final class StubTransport: Transport, @unchecked Sendable {
    private let cond = NSCondition()
    private var inbound: [Data] = []
    private var closed = false, dead = false
    var answerVersion = true
    private(set) var writes: [String] = []           // methods written, in order (for the barrier test)

    func goDead() { cond.lock(); dead = true; cond.signal(); cond.unlock() }
    func open() throws { cond.lock(); let d = dead; cond.unlock(); if d { throw OrchestraError.io("dead") } }

    func write(_ data: Data) -> Bool {
        let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: data)
        cond.lock()
        if let m = msg?.method { writes.append(m) }
        let isDead = dead
        if let m = msg?.method, m == "version", let id = msg?.id, answerVersion, !dead {
            inbound.append(#"{"id":\#(id),"result":{}}"#.data(using: .utf8)!); cond.signal()
        }
        // NOTE: the barrier test manually feeds a `subscribe`/`boardSnapshot` reply via feed(id:).
        cond.unlock()
        return !isDead
    }
    func feed(_ data: Data) { cond.lock(); inbound.append(data); cond.signal(); cond.unlock() }
    func readLine() -> Data? {
        cond.lock(); defer { cond.unlock() }
        while inbound.isEmpty && !closed && !dead { cond.wait() }
        return (closed || dead) ? nil : inbound.removeFirst()
    }
    func shutdown() { cond.lock(); closed = true; cond.signal(); cond.unlock() }
    func close()    { cond.lock(); closed = true; cond.signal(); cond.unlock() }
}

@Suite struct ControlClientTests {
    // A call against a dead-but-open transport (no EOF, no reply) throws within the deadline.
    @Test func test_callTimesOut() async throws {
        let stub = StubTransport()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200), pingInterval: .seconds(3600))
        try c.connect()
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await c.call("list", .object([:])) }
        #expect(ContinuousClock.now - start < .seconds(2)); c.close()
    }

    // The timer-arm-before-insert race (Codex B3): a near-zero timeout must still resolve exactly once
    // (throw), never double-resume (crash) and never leak (hang).
    @Test func test_callTimesOutNearZero() async throws {
        let stub = StubTransport()
        // probeTimeout defaults to 15s, so the near-zero CALL deadline can't racily fail connect()'s probe.
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .nanoseconds(1), pingInterval: .seconds(3600))
        try c.connect()
        await #expect(throws: (any Error).self) { _ = try await c.call("list", .object([:])) }
        c.close()
    }

    // The keepalive marks the connection degraded when pings stop returning.
    @Test func test_pingDetectsDeadTunnel() async throws {
        let stub = StubTransport()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200), pingInterval: .milliseconds(100))
        try c.connect(); #expect(c.state == .live)
        stub.answerVersion = false
        var degraded = false
        for _ in 0..<50 { if c.state == .retrying { degraded = true; break }; try? await _Concurrency.Task.sleep(for: .milliseconds(50)) }
        #expect(degraded); c.close()
    }

    // A dead-but-open tunnel on FIRST connect must not hang connect() forever (bounded probeVersion).
    @Test func test_firstConnectProbeTimesOut() async throws {
        let stub = StubTransport(); stub.answerVersion = false          // never answers the probe
        // probeTimeout short so the test doesn't wait the 15s default.
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .seconds(5),
                              pingInterval: .seconds(3600), probeTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) { try c.connect() }           // throws, doesn't hang
        #expect(ContinuousClock.now - start < .seconds(2)); c.close()
    }
}
