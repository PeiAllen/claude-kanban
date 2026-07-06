import XCTest
import Crypto
@preconcurrency import NIOSSH
@testable import OrchestraiOS
import OrchestraKit

/// P1 — server-free unit tests for the iOS board-over-SSH control transport: the UDS bridge command
/// (nc/socat + tilde handling), endpoint derivation from the active connection, and the "never cache the
/// session" box invariant. The live SSH pump stays covered by the loopback e2e harness.
final class ControlTransportTests: XCTestCase {

    // MARK: bridgeCommand / shellArg

    func testBridgeCommandForTildePathExpandsHomeAndKeepsSpaces() {
        let cmd = SSHControlTransport.bridgeCommand(sock: Connection.defaultMacSocketPath)
        // ~/ must become "$HOME/…" (double-quoted so the space in "Application Support" survives), and
        // the socat fallback must reference the same expanded, quoted path.
        XCTAssertTrue(cmd.contains("\"$HOME/Library/Application Support/Orchestra/orchestrad.sock\""), cmd)
        XCTAssertTrue(cmd.contains("nc -U "), cmd)
        XCTAssertTrue(cmd.contains("socat - UNIX-CONNECT:"), cmd)
        XCTAssertFalse(cmd.contains("~/"), cmd)   // no unexpanded tilde
    }

    func testBridgeCommandForAbsolutePathIsSingleQuoted() {
        let cmd = SSHControlTransport.bridgeCommand(sock: "/tmp/orchestrad.sock")
        XCTAssertTrue(cmd.contains("nc -U '/tmp/orchestrad.sock'"), cmd)
        XCTAssertTrue(cmd.contains("socat - UNIX-CONNECT:'/tmp/orchestrad.sock'"), cmd)
    }

    func testShellArgTildeVsAbsolute() {
        XCTAssertEqual(SSHControlTransport.shellArg("~/x/y.sock"), "\"$HOME/x/y.sock\"")
        XCTAssertEqual(SSHControlTransport.shellArg("/var/run/x.sock"), "'/var/run/x.sock'")
    }

    // MARK: SSHEndpoint.resolve(connection:)

    func testResolveDerivesEndpointFromActiveConnection() {
        let conn = Connection.mac(sshTarget: "me@my-mac.tailnet.ts.net")
        let ep = SSHEndpoint.resolve(connection: conn)
        XCTAssertEqual(ep?.host, "my-mac.tailnet.ts.net")
        XCTAssertEqual(ep?.user, "me")
    }

    func testResolveIsNilForLocalConnection() {
        XCTAssertNil(SSHEndpoint.resolve(connection: .local))
        XCTAssertNil(SSHEndpoint.resolve(connection: nil))
    }

    func testConnectionSSHEndpointParsesTarget() {
        XCTAssertEqual(Connection.mac(sshTarget: "u@h.ts.net:2222").sshEndpoint?.port, 2222)
    }

    // MARK: CurrentSessionBox — the "never cache" invariant

    func testSessionBoxReturnsTheCurrentSessionAfterRebuild() {
        let box = CurrentSessionBox()
        XCTAssertNil(box.current())
        let a = Self.makeSession(host: "a.tailnet.ts.net")
        let b = Self.makeSession(host: "b.tailnet.ts.net")
        box.set(a)
        XCTAssertTrue(box.current() === a)
        box.set(b)                                  // reconnect / switch rebuilds the session
        XCTAssertTrue(box.current() === b, "provider must yield the NEW session, never a stale one")
        box.set(nil)
        XCTAssertNil(box.current())
    }

    private static func makeSession(host: String) -> IOSSSHSession {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        return IOSSSHSession(endpoint: SSHEndpoint(host: host, user: "me"),
                             group: TerminalRuntime.group, privateKey: key)
    }
}
