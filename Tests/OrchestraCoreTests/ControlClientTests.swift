import Testing
import Foundation
import TestSupport
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
    // A call against a dead-but-open transport (no EOF, no reply) is BOUNDED: it fails via the call-timeout
    // path rather than parking forever.
    //
    // This asserts the BEHAVIOR (which failure fired), not its wall-clock duration. It used to assert
    // `elapsed < 2s` around a 200ms deadline, which is a latency claim the product never made: under
    // `--parallel` the timer fires on time but its continuation is not scheduled until the machine has a
    // thread free, so the measurement is of suite load, not of ControlClient. Measured: 0.26s alone,
    // 21.2s under full-suite load — while the timeout itself fired correctly in both.
    //
    // Matching the error is also STRICTLY STRONGER than the old bound: `throws: (any Error).self` + "fast"
    // would have passed on a write failure or an EOF, i.e. on the timeout NOT firing. The message pins the
    // call-timeout path specifically.
    @Test func test_callTimesOut() async throws {
        let stub = StubTransport()
        let clock = TestClock()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200),
                              pingInterval: .seconds(3600), clock: clock)
        try c.connect()
        let call = _Concurrency.Task { _ = try await c.call("list", .object([:])) }
        await clock.parked(2)                    // the ping loop (3600s) + THIS call's deadline timer
        clock.advance(by: .milliseconds(200))    // fire the call deadline; the ping stays parked
        let err = await #expect(throws: OrchestraError.self) { _ = try await call.value }
        guard case .io(let msg)? = err else { Issue.record("expected .io, got \(String(describing: err))"); return }
        #expect(msg.contains("timed out"))          // the call-timeout path fired — not a write/EOF failure
        #expect(msg.contains("list"))               // and it is THIS call that was bounded
        c.close()
    }

    // The timer-arm-before-insert race (Codex B3): a near-zero timeout must still resolve exactly once
    // (throw), never double-resume (crash) and never leak (hang).
    @Test func test_callTimesOutNearZero() async throws {
        let stub = StubTransport()
        let clock = TestClock()
        // probeTimeout defaults to 15s, so the near-zero CALL deadline can't racily fail connect()'s probe.
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .nanoseconds(1),
                              pingInterval: .seconds(3600), clock: clock)
        try c.connect()
        let call = _Concurrency.Task { _ = try await c.call("list", .object([:])) }
        await clock.parked(2)                    // ping loop + the near-zero deadline timer
        clock.advance(by: .milliseconds(1))
        await #expect(throws: (any Error).self) { _ = try await call.value }
        c.close()
    }

    // The keepalive marks the connection degraded when pings stop returning.
    @Test func test_pingDetectsDeadTunnel() async throws {
        let stub = StubTransport()
        let clock = TestClock()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200),
                              pingInterval: .milliseconds(100), clock: clock)
        try c.connect(); #expect(c.state == .live)
        stub.answerVersion = false
        await clock.parked(1)                        // the ping loop is parked on its interval
        clock.advance(by: .milliseconds(100))        // fire a ping → it issues `version`, never answered
        await clock.parked(1, deadlineAtLeast: .milliseconds(150))   // that call's 200ms deadline parked
        clock.advance(by: .milliseconds(200))        // fire the deadline → ping fails → .retrying
        try await pollUntil("state degrades to .retrying") { c.state == .retrying }
        c.close()
    }

    // A dead-but-open tunnel on FIRST connect must not hang connect() forever (bounded probeVersion).
    // As in `test_callTimesOut`: assert WHICH failure fired, not how long it took. The old `< 2s` bound
    // measured suite load rather than the probe watchdog, and would have passed on an unrelated fast
    // failure (e.g. the probe's own write failing) — the message pins the watchdog path that this test
    // exists to prove.
    @Test func test_firstConnectProbeTimesOut() async throws {
        let stub = StubTransport(); stub.answerVersion = false          // never answers the probe
        let clock = TestClock()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .seconds(5),
                              pingInterval: .seconds(3600), probeTimeout: .milliseconds(200), clock: clock)
        // `connect()` BLOCKS its thread in readLine until the watchdog shuts the transport, so run it
        // on a GCD thread (not the cooperative pool) and drive the watchdog from the test clock.
        let connecting = _Concurrency.Task { () -> Error? in
            await withCheckedContinuation { (cont: CheckedContinuation<Error?, Never>) in
                DispatchQueue.global().async {
                    do { try c.connect(); cont.resume(returning: nil) }
                    catch { cont.resume(returning: error) }
                }
            }
        }
        await clock.parked(1, deadlineAtLeast: .milliseconds(150))   // the probe watchdog is armed
        clock.advance(by: .milliseconds(200))                        // fire it → shutdown → readLine nil → throw
        let err = await connecting.value                             // throws, doesn't hang
        guard case OrchestraError.io(let msg)? = err else { Issue.record("expected .io, got \(String(describing: err))"); return }
        #expect(msg.contains("version probe"))      // the probe watchdog shut the transport → connect threw
        c.close()
    }

    // subscribeWithRev does not auto-issue; the awaited subscribe completes (ack fed) BEFORE any snapshot.
    @Test func test_subscribeAwaitedBeforeSnapshot() async throws {
        let stub = StubTransport()
        // A TestClock the test never advances: the call deadline can NOT fire, so a starved scheduler
        // can never turn the awaited subscribe ack into a spurious timeout (the old 5s-flake).
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(5),
                              pingInterval: .seconds(3600), clock: TestClock())
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
        let clock = TestClock()
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .milliseconds(200),
                              pingInterval: .seconds(3600), clock: clock)
        let reconnected = _Locked(false)
        c.onReconnect = { reconnected.value = true }
        try c.connect()
        _ = c.subscribeWithRev()                                      // sets `subscribed` so the reconnect re-subscribes
        (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects → subscribe deadline-fails
        // Drive TWO full failed-re-subscribe cycles deterministically: each reconnect's detached
        // `subscribe` call parks its 200ms deadline on the test clock; firing it fails the barrier →
        // forceReconnect → (real backoff on the reader thread) → next attempt.
        for cycle in 1...2 {
            try await pollUntil("re-subscribe attempt #\(cycle) issued") {
                stub.writes.filter { $0 == "subscribe" }.count >= cycle
            }
            await clock.parked(2)                     // ping (3600s) + this subscribe's deadline timer
            clock.advance(by: .milliseconds(250))     // fail the barrier → forces the next reconnect
        }
        #expect(reconnected.value == false)                           // onReconnect NEVER fired → never snapshots unsubscribed
        c.close()
    }

    // The POSITIVE reconnect path (would have caught Opus NB-1): when subscribe IS answered on reconnect,
    // onReconnect MUST fire — proving the ack is actually read (reader live after break), not deadlocked.
    @Test func test_subscribeSuccessFiresOnReconnect() async throws {
        let stub = StubTransport(); stub.answerVersion = true; stub.answerSubscribe = true; stub.reopenOnConnect = true
        // TestClock pins the 2s call deadline: it can never fire, so `onReconnect` firing proves the
        // ack was READ (reader live after the break), not that a timeout resolved the call.
        let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(2),
                              pingInterval: .seconds(3600), clock: TestClock())
        let reconnected = _Locked(false)
        c.onReconnect = { reconnected.value = true }
        try c.connect()
        _ = c.subscribeWithRev()                                      // subscribed = true
        (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects, subscribe acked
        try await pollUntil("onReconnect fires after the acked re-subscribe") { reconnected.value }
        c.close()
    }
}
