import XCTest
@testable import OrchestraiOS   // internal access to the app target's transport/push types

/// Server-free unit tests for the iOS SSH/PTY transport surface (review #10) and the Tailscale-target
/// guard (review #5). NO live sshd / no device: every assertion is over pure parsing, framing, and
/// policy logic. The live SSH attach stays covered by the manual harness; this locks the pure parts.
@MainActor
final class TransportTests: XCTestCase {

    // MARK: - SSHEndpoint.init?(target:) parsing (#10)

    func testParseUserAtHost() {
        let ep = SSHEndpoint(target: "me@my-mac.tailnet.ts.net")
        XCTAssertEqual(ep, SSHEndpoint(host: "my-mac.tailnet.ts.net", port: 22, user: "me"))
    }

    func testParseUserAtHostWithPort() {
        let ep = SSHEndpoint(target: "me@100.101.102.103:2222")
        XCTAssertEqual(ep, SSHEndpoint(host: "100.101.102.103", port: 2222, user: "me"))
    }

    func testParseHostColonPortWithoutUserIsNil() {
        // The target shape requires a user (an `@`) — the endpoint has no default user to fall back on,
        // so a bare `host:port` can't produce a valid endpoint.
        XCTAssertNil(SSHEndpoint(target: "my-mac.ts.net:2222"))
    }

    func testMemberwiseDefaultPortIs22() {
        XCTAssertEqual(SSHEndpoint(host: "h", user: "u").port, 22)
    }

    func testParseMalformedInputsAreNil() {
        XCTAssertNil(SSHEndpoint(target: ""))            // empty
        XCTAssertNil(SSHEndpoint(target: "   "))          // whitespace only
        XCTAssertNil(SSHEndpoint(target: "no-at-sign"))   // no user, no host split
        XCTAssertNil(SSHEndpoint(target: "@host.ts.net")) // empty user
        XCTAssertNil(SSHEndpoint(target: "me@"))          // empty host
    }

    func testParseBadPortIsNil() {
        // A present-but-invalid port must be rejected — not silently folded into the host string.
        XCTAssertNil(SSHEndpoint(target: "me@host.ts.net:notaport"))
        XCTAssertNil(SSHEndpoint(target: "me@host.ts.net:0"))       // 0 is not a usable port
        XCTAssertNil(SSHEndpoint(target: "me@host.ts.net:70000"))   // out of 1…65535 range
    }

    // MARK: - TerminalByteChannel framing / encoding (#10, via LoopbackChannel)

    func testLoopbackStartEmitsConnectedThenBannerWithCRLF() {
        let ch = LoopbackChannel(banner: "line1\nline2")
        var events: [TerminalChannelEvent] = []
        var output = ""
        ch.onEvent = { events.append($0) }
        ch.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        ch.start(cols: 80, rows: 24)
        XCTAssertEqual(events, [.connected])
        XCTAssertEqual(output, "line1\r\nline2")   // every \n is expanded to \r\n for the emulator
    }

    func testLoopbackSendEchoesAndExpandsCarriageReturn() {
        let ch = LoopbackChannel(banner: "")
        var output: [UInt8] = []
        ch.onOutput = { output.append(contentsOf: $0) }
        ch.start(cols: 80, rows: 24)
        output.removeAll()                          // drop the (empty) banner echo
        ch.send([0x41, 0x0d, 0x42])                 // "A", CR, "B"
        XCTAssertEqual(output, [0x41, 0x0d, 0x0a, 0x42])   // CR → CRLF so Return advances a line
    }

    func testLoopbackStartIsIdempotent() {
        let ch = LoopbackChannel(banner: "hi")
        var bannerCount = 0
        ch.onOutput = { _ in bannerCount += 1 }
        ch.start(cols: 80, rows: 24)
        ch.start(cols: 80, rows: 24)                // second start while open is a no-op
        XCTAssertEqual(bannerCount, 1)
    }

    func testLoopbackCloseAllowsRestart() {
        let ch = LoopbackChannel(banner: "hi")
        var bannerCount = 0
        ch.onOutput = { _ in bannerCount += 1 }
        ch.start(cols: 80, rows: 24)
        ch.close()
        ch.start(cols: 80, rows: 24)                // reconnect after close re-emits the banner
        XCTAssertEqual(bannerCount, 2)
    }

    // MARK: - iOS APNs registration seam (#10, PushController)

    func testDeviceTokenHexEncoding() {
        // APNs hands a raw Data blob; the daemon expects lowercase, zero-padded, 2 hex digits per byte.
        XCTAssertEqual(PushCoordinator.hexToken(from: Data([0x00, 0x0f, 0xa0, 0xff])), "000fa0ff")
        XCTAssertEqual(PushCoordinator.hexToken(from: Data()), "")
    }

    func testSetTokenDeduplicates() {
        let coord = PushCoordinator.shared
        coord.deviceToken = nil                     // clean slate (@testable direct access)
        defer { coord.deviceToken = nil }
        XCTAssertTrue(coord.setToken("aabb"))       // first registration → changed
        XCTAssertEqual(coord.deviceToken, "aabb")
        XCTAssertFalse(coord.setToken("aabb"))      // same token re-delivered on next launch → no-op
        XCTAssertTrue(coord.setToken("ccdd"))       // a genuinely new token → changed
        XCTAssertEqual(coord.deviceToken, "ccdd")
    }

    // MARK: - Tailscale-target guard (#5)

    func testTailnetGuardAcceptsCGNATAndMagicDNS() {
        // Tailscale CGNAT 100.64.0.0/10 boundaries + interior, and *.ts.net MagicDNS names.
        for host in ["100.64.0.0", "100.127.255.255", "100.101.102.103",
                     "my-mac.ts.net", "my-mac.tailnet-1234.ts.net", "TS.NET".lowercased()] {
            XCTAssertTrue(SSHEndpoint.isTailnetHost(host), "expected \(host) to be a tailnet host")
            XCTAssertNil(SSHEndpoint.tailnetRejectionReason(for: host))
        }
    }

    func testTailnetGuardRejectsNonTailnetHosts() {
        // Just-outside-CGNAT, RFC1918 LAN, loopback, and public hosts must all be refused.
        for host in ["100.63.255.255", "100.128.0.0", "10.0.0.5", "192.168.1.10",
                     "localhost", "127.0.0.1", "example.com", "my-mac.local", "ts.net.evil.com"] {
            XCTAssertFalse(SSHEndpoint.isTailnetHost(host), "expected \(host) to be rejected")
            XCTAssertNotNil(SSHEndpoint.tailnetRejectionReason(for: host))
        }
    }

    func testLoopbackTestEscapeIsOptInAndLoopbackOnly() {
        let on = ["ORCH_SSH_ALLOW_LOOPBACK": "1"]
        // Opt-in flag set: only loopback hosts are allowed — the escape for the isolated verify harness.
        for host in ["127.0.0.1", "localhost", "::1"] {
            XCTAssertTrue(SSHEndpoint.isTestLoopbackAllowed(host, env: on), "expected \(host) allowed with flag")
        }
        // Even with the flag, it NEVER widens to a real LAN/public host — it's loopback-only.
        for host in ["10.0.0.5", "192.168.1.10", "example.com", "100.64.0.1"] {
            XCTAssertFalse(SSHEndpoint.isTestLoopbackAllowed(host, env: on), "escape must stay loopback-only: \(host)")
        }
        // Without the opt-in flag, loopback stays rejected (the default the guard enforces in prod).
        XCTAssertFalse(SSHEndpoint.isTestLoopbackAllowed("127.0.0.1", env: [:]))
        XCTAssertFalse(SSHEndpoint.isTestLoopbackAllowed("127.0.0.1", env: ["ORCH_SSH_ALLOW_LOOPBACK": "0"]))
    }
}
