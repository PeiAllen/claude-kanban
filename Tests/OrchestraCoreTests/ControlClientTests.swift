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
    /// When true, `write` auto-answers a `subscribe` RPC (so the reconnect re-subscribe / barrier acks).
    /// Default false — the failure test relies on subscribe NOT being answered; the success/positive
    /// tests opt in.
    var answerSubscribe = false
    /// When true, `open()` resets `closed` so the runLoop can reconnect through this same instance (the
    /// reconnect tests reuse one transport across the drop → re-open cycle rather than a fresh factory).
    var reopenOnConnect = false
    private(set) var writes: [String] = []           // methods written, in order (for the barrier test)

    func goDead() { cond.lock(); dead = true; cond.signal(); cond.unlock() }
    func open() throws {
        cond.lock(); let d = dead; if reopenOnConnect { closed = false }; cond.unlock()
        if d { throw OrchestraError.io("dead") }
    }

    func write(_ data: Data) -> Bool {
        let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: data)
        cond.lock()
        if let m = msg?.method { writes.append(m) }
        let isDead = dead
        if let m = msg?.method, let id = msg?.id, !dead {
            if m == "version", answerVersion {
                inbound.append(#"{"id":\#(id),"result":{}}"#.data(using: .utf8)!); cond.signal()
            } else if m == "subscribe", answerSubscribe {
                inbound.append(#"{"id":\#(id),"result":{}}"#.data(using: .utf8)!); cond.signal()
            }
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

/// Tiny thread-safe box for the reconnect tests (`onReconnect` fires off the runLoop thread).
final class _Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
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

    // subscribeWithRev does not auto-issue; the awaited subscribe completes (ack fed) BEFORE any snapshot.
    @Test func test_subscribeAwaitedBeforeSnapshot() async throws {
        let stub = StubTransport()
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(5), pingInterval: .seconds(3600))
        try c.connect()
        _ = c.subscribeWithRev()
        #expect(!stub.writes.contains("subscribe"))                   // NOT auto-issued — caller owns the barrier
        stub.answerSubscribe = true                                   // arrange the stub to ack subscribe
        try await c.call("subscribe")                                 // AWAITED — returns only after the ack
        #expect(stub.writes.contains("subscribe"))
        #expect(!stub.writes.contains("boardSnapshot"))               // snapshot issued only after, by the caller
        c.close()
    }

    // B2 failure-open guard: if the reconnect re-subscribe FAILS, onReconnect must NOT fire (no snapshot
    // while unsubscribed). The critical invariant is "onReconnect not fired" — state oscillates during the
    // retry loop (openOnce briefly sets .live before the detached subscribe fails), so we do NOT assert on it.
    @Test func test_subscribeFailureDoesNotFireOnReconnect() async throws {
        let stub = StubTransport(); stub.answerVersion = true; stub.answerSubscribe = false; stub.reopenOnConnect = true
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .milliseconds(200), pingInterval: .seconds(3600))
        let reconnected = _Locked(false)
        c.onReconnect = { reconnected.value = true }
        try c.connect()
        _ = c.subscribeWithRev()                                      // sets `subscribed` so the reconnect re-subscribes
        (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects → subscribe deadline-fails
        try? await _Concurrency.Task.sleep(for: .seconds(1))          // several failed subscribe attempts
        #expect(reconnected.value == false)                           // onReconnect NEVER fired → never snapshots unsubscribed
        c.close()
    }

    // The POSITIVE reconnect path (would have caught Opus NB-1): when subscribe IS answered on reconnect,
    // onReconnect MUST fire — proving the ack is actually read (reader live after break), not deadlocked.
    @Test func test_subscribeSuccessFiresOnReconnect() async throws {
        let stub = StubTransport(); stub.answerVersion = true; stub.answerSubscribe = true; stub.reopenOnConnect = true
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(2), pingInterval: .seconds(3600))
        let reconnected = _Locked(false)
        c.onReconnect = { reconnected.value = true }
        try c.connect()
        _ = c.subscribeWithRev()                                      // subscribed = true
        (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects, subscribe acked
        var fired = false
        for _ in 0..<40 { if reconnected.value { fired = true; break }; try? await _Concurrency.Task.sleep(for: .milliseconds(50)) }
        #expect(fired)                                               // fired well under the 2s callTimeout → ack WAS read
        c.close()
    }
}
