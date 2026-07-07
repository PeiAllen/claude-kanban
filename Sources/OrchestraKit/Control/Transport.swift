import Foundation

/// Observable link state the UI binds to. `connecting` = first attempt; `live` = connected + (re)subscribed;
/// `retrying` = dropped, backing off; `down` = intentionally closed.
public enum ConnectionState: String, Sendable, Equatable {
    case connecting, live, retrying, down
}

/// The swap point between the client and its byte transport. `UDSTransport` is the only concrete impl
/// today (current UDS behavior); a future WebSocket/tailnet transport plugs in here without touching
/// `ControlClient`. One instance == one live connection: after `close()` (or EOF), the client makes a
/// FRESH transport to reconnect.
public protocol Transport: AnyObject, Sendable {
    /// Establish the connection. Throws on failure.
    func open() throws
    /// Write one already-newline-terminated frame. `false` if the link is broken.
    func write(_ data: Data) -> Bool
    /// Block for the next inbound NDJSON line (without trailing '\n'); `nil` on EOF/close.
    func readLine() -> Data?
    /// Wake any thread blocked in `readLine()` by half-closing the link, WITHOUT releasing the fd — so
    /// `readLine()` returns `nil` and the reader loop exits. Idempotent. The *reader* owns `close()`:
    /// teardown/other threads call `shutdown()` to unblock the reader, then the reader closes. This
    /// avoids (a) a leaked reader thread on Linux, where `close(2)` does not wake a blocked `read(2)`,
    /// and (b) recycled-fd cross-wiring, where closing an fd a reader still holds lets a new connection
    /// reuse the number under the zombie reader.
    func shutdown()
    /// Tear down the connection (release the fd). Called by the reader once its loop has exited.
    func close()
}

/// AF_UNIX transport — the current behavior, extracted behind `Transport`.
public final class UDSTransport: Transport, @unchecked Sendable {
    private let socketPath: String
    private var fd: Int32 = -1
    private var reader: LineReader?
    private let lock = NSLock()

    public init(socketPath: String) { self.socketPath = socketPath }

    public func open() throws {
        let f = try UDS.connect(path: socketPath)
        lock.withLock { fd = f; reader = LineReader(fd: f) }
    }

    public func write(_ data: Data) -> Bool {
        lock.withLock {
            guard fd >= 0 else { return false }
            return UDS.writeAll(fd, data)
        }
    }

    public func readLine() -> Data? { reader?.next() }

    /// Wake a blocked `readLine()` (half-close) without releasing the fd — the reader owns `close()`.
    public func shutdown() {
        lock.withLock { if fd >= 0 { shutdownFD(fd) } }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 { closeFD(fd); fd = -1 }
            reader = nil
        }
    }
}
