import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    /// Tear down the connection.
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

    public func close() {
        lock.withLock {
            if fd >= 0 {
                #if canImport(Glibc)
                _ = Glibc.close(fd)
                #else
                _ = Darwin.close(fd)
                #endif
                fd = -1
            }
            reader = nil
        }
    }
}
