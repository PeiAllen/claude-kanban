import Foundation
import Testing
@testable import OrchestraCore

#if canImport(Darwin)
import Darwin
#endif

@Suite("UDS — SIGPIPE suppression on peer-closed sockets", .serialized)
struct UDSSigPipeTests {

    /// Short socket path (sun_path limit ~104). Tests run unsandboxed so /tmp is writable.
    static func sock() -> String { "/tmp/orch-sig-\(UUID().uuidString.prefix(8)).sock" }

    /// Regression: archiving a card from the agent running *inside* that card's session kills the
    /// session — and the client connection the request arrived on — before the daemon writes its
    /// response. A plain `write(2)` to a peer-closed SOCK_STREAM raises SIGPIPE, whose default
    /// disposition terminates the daemon (launchd then relaunches it → the spurious "orchestrad
    /// crashed" popup). `UDS` sets `SO_NOSIGPIPE`, so the write returns EPIPE and `writeAll` reports
    /// a broken connection instead. If this regresses, this test process is SIGPIPE-killed outright.
    @Test("write to a connection whose peer closed returns false, never SIGPIPE-kills the process")
    func writeToClosedPeerDoesNotCrash() throws {
        let path = Self.sock()
        let serverFd = try UDS.listen(path: path)
        defer { close(serverFd); unlink(path) }

        let clientFd = try UDS.connect(path: path)
        let conn = UDS.accept(serverFd)
        #expect(conn >= 0)
        defer { if conn >= 0 { close(conn) } }

        // The peer goes away abruptly (the killed session took its client with it).
        close(clientFd)
        Thread.sleep(forTimeInterval: 0.05)   // let the close propagate before we write

        // A stream socket may buffer the first write before surfacing EPIPE, so loop. Without the
        // fix the very first write that reaches the dead peer delivers SIGPIPE and never returns.
        var sawBroken = false
        for _ in 0..<10 where !UDS.writeAll(conn, Data("{\"event\":\"x\"}\n".utf8)) {
            sawBroken = true
            break
        }
        #expect(sawBroken)   // reached only because the process survived the writes
    }
}
