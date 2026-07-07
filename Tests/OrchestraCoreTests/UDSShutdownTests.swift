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

/// FIX 1 — fd close-while-blocked-read. The socket-lifecycle guarantee: a thread parked in a blocking
/// `read(2)` is woken by `shutdown(SHUT_RDWR)` (NOT by `close(2)`, which on Linux leaves the reader
/// blocked forever), and the *reader* owns the subsequent `close()`. These tests assert the wake-up
/// mechanism on the production paths (`UDS.read` and `UDSTransport.readLine`). They pass on Darwin
/// (where `close` happens to wake too) and on Linux (where only `shutdown` does).
@Suite("UDS — shutdown wakes a blocked reader; reader owns close", .serialized)
struct UDSShutdownTests {
    /// Short socket path (sun_path limit ~104). Tests run unsandboxed so /tmp is writable.
    static func sock() -> String { "/tmp/orch-shut-\(UUID().uuidString.prefix(8)).sock" }

    @Test("shutdownFD unblocks a thread parked in read(2); the reader then owns close()")
    func shutdownWakesBlockedRead() throws {
        let path = Self.sock()
        let serverFd = try UDS.listen(path: path)
        defer { closeFD(serverFd); unlink(path) }
        let clientFd = try UDS.connect(path: path)
        defer { closeFD(clientFd) }                 // peer stays open: no data, no natural EOF
        let conn = UDS.accept(serverFd)
        #expect(conn >= 0)

        // Reader parks in read(2) — nothing will ever arrive on this connection.
        let woke = DispatchSemaphore(value: 0)
        let reader = Thread {
            var buf = [UInt8](repeating: 0, count: 1024)
            while UDS.read(conn, into: &buf) != nil {}   // nil == EOF/error → loop exits
            closeFD(conn)                                // reader owns the close
            woke.signal()
        }
        reader.stackSize = 1 << 20
        reader.start()

        Thread.sleep(forTimeInterval: 0.1)               // let the reader reach the blocking read()
        shutdownFD(conn)                                 // wake it WITHOUT closing the fd

        // Generous bound: the wake is instant; the ceiling only guards against a starved reader thread
        // under parallel-suite load (a false negative), never against real behavior. Under the OLD
        // close-only path on Linux this would hang forever.
        #expect(woke.wait(timeout: .now() + 10) == .success)
    }

    @Test("UDSTransport.shutdown() unblocks a blocked readLine(); close() then releases the fd")
    func transportShutdownUnblocksReadLine() throws {
        let path = Self.sock()
        let serverFd = try UDS.listen(path: path)
        defer { closeFD(serverFd); unlink(path) }

        let t = UDSTransport(socketPath: path)
        try t.open()
        let conn = UDS.accept(serverFd)                  // server side kept open: sends nothing
        #expect(conn >= 0)
        defer { closeFD(conn) }

        let done = DispatchSemaphore(value: 0)
        let sawEOF = LockedBool()
        let reader = Thread {
            let line = t.readLine()                      // blocks: no data, no EOF from the peer
            sawEOF.set(line == nil)
            done.signal()
        }
        reader.stackSize = 1 << 20
        reader.start()

        Thread.sleep(forTimeInterval: 0.1)
        t.shutdown()                                     // must wake the blocked readLine WITHOUT close()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(sawEOF.get())                            // readLine returned nil (EOF observed)
        t.close()                                        // reader-owns-close in prod; release the fd here
    }
}

/// Minimal thread-safe Bool for cross-thread test assertions.
final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
