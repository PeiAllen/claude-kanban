import Foundation

/// A thread-safe NDJSON line buffer that bridges asynchronous byte delivery to a synchronous,
/// blocking `readLine()`.
///
/// `UDSTransport` reads lines from an fd via `LineReader`; the iOS SSH control transport instead
/// receives bytes asynchronously on a swift-nio-ssh child channel (`channelRead`). This buffer lets
/// the NIO side `append(_:)` inbound bytes from any thread while a `ControlClient` read pump blocks in
/// `readLine()` — mirroring `LineReader`'s contract: one line per call without the trailing `\n`, and
/// `nil` once the stream ends (dropping any incomplete trailing frame).
public final class ControlLineBuffer: @unchecked Sendable {
    private let cond = NSCondition()
    private var pending = Data()       // bytes not yet terminated by a newline
    private var lines: [Data] = []     // complete frames, newline-stripped, FIFO
    private var eof = false

    public init() {}

    /// Append inbound bytes; extract any complete newline-terminated frames and wake a blocked reader.
    public func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        cond.lock()
        pending.append(contentsOf: bytes)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            lines.append(line)
            pending.removeSubrange(pending.startIndex...nl)
        }
        cond.signal()
        cond.unlock()
    }

    /// Block until the next complete frame is available; return it without the trailing `\n`.
    /// Returns `nil` at end-of-stream (any incomplete trailing frame is dropped).
    public func readLine() -> Data? {
        cond.lock()
        defer { cond.unlock() }
        while lines.isEmpty && !eof { cond.wait() }
        if !lines.isEmpty { return lines.removeFirst() }
        return nil
    }

    /// Mark the stream ended and wake all blocked readers. Drops any incomplete trailing frame.
    public func signalEOF() {
        cond.lock()
        eof = true
        cond.broadcast()
        cond.unlock()
    }
}
