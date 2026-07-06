import XCTest
import Crypto
@preconcurrency import NIOSSH
@testable import OrchestraiOS
import OrchestraKit

/// P1 — the **loopback board-over-SSH end-to-end proof**: the one integration test that drives the real
/// SSH path (`SSHControlTransport` → throwaway `sshd` → `nc -U` → isolated `orchestrad`) and asserts the
/// board's `ControlClient` actually reaches `.live` and round-trips a `version` RPC — no device needed.
///
/// This is **not** a unit test; it needs the harness up. It is gated on two env vars set only by
/// `scripts/ios-board-over-ssh-verify.sh`, so an ordinary offline unit run (or CI without `sshd`)
/// **skips** it rather than failing:
///
///   - `ORCH_E2E_SSH_TARGET`  — `user@127.0.0.1:<port>` of the throwaway sshd
///   - `ORCH_E2E_DAEMON_SOCK` — absolute path to the isolated `orchestrad.sock` the bridge `nc -U`s
///
/// The harness passes them into the Simulator test runner via the `TEST_RUNNER_` prefix. It also sets
/// `ORCH_SSH_ALLOW_LOOPBACK=1` (the DEBUG-only escape from the tailnet guard, since 127.0.0.1 is not a
/// tailnet host). The device's own Keychain key (already trusted in the sshd's `authorized_keys` by the
/// harness) is the auth identity — exactly the production path.
final class BoardOverSSHE2ETests: XCTestCase {

    /// The daemon's `version` reply shape (`{"version": "…"}`) — the local mirror of `BoardModel`'s.
    private struct VersionInfo: Decodable { let version: String }

    private func requireEnv(_ name: String) throws -> String {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else {
            throw XCTSkip("e2e disabled: \(name) unset (run scripts/ios-board-over-ssh-verify.sh)")
        }
        return v
    }

    /// The isolated daemon socket the bridge `nc -U`s (set by the harness).
    private func daemonSock() throws -> String { try requireEnv("ORCH_E2E_DAEMON_SOCK") }

    /// Build the shared `IOSSSHSession` for the harness's sshd, with a fresh TOFU pin. This is the ONE
    /// authenticated connection the board's control transport (and, folded, terminals) multiplex over.
    private func makeSession() throws -> IOSSSHSession {
        let target = try requireEnv("ORCH_E2E_SSH_TARGET")
        guard let endpoint = SSHEndpoint(target: target) else {
            throw XCTSkip("e2e: ORCH_E2E_SSH_TARGET '\(target)' is not user@host[:port]")
        }
        // Fresh TOFU: the throwaway sshd's host key is regenerated each run, so clear any pin left by a
        // prior run to 127.0.0.1 or the first connect would hit a `hostKeyChanged` refusal.
        try? SSHHostKeyPinStore().reset(host: endpoint.host)
        let privateKey = NIOSSHPrivateKey(ed25519Key: try SSHKeyStore.loadOrCreateIdentity())
        return IOSSSHSession(endpoint: endpoint, group: TerminalRuntime.group, privateKey: privateKey)
    }

    /// A `ControlClient` over the real SSH control transport backed by `session`. Mirrors exactly what
    /// `BoardModel.activate` does on a device (via the `RemoteControlTransportProvider`), but assembled
    /// directly so the test owns the lifecycle.
    private func makeClient(over session: IOSSSHSession, sock: String) -> ControlClient {
        ControlClient(transport: { SSHControlTransport(session: { session }, remoteSocketPath: sock) },
                      source: .app)
    }

    /// The daemon's `version`, round-tripped over an SSH-backed control client.
    private func version(_ client: ControlClient) async throws -> String {
        try await client.call("version").decode(VersionInfo.self).version
    }

    /// Poll `client.state` until it equals `want` or the timeout elapses. `ControlClient` publishes state
    /// off the caller's thread, so a short poll is the simplest cross-thread wait.
    private func waitForState(_ client: ControlClient, _ want: ConnectionState,
                              timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if client.state == want { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return client.state == want
    }

    // MARK: the proof

    /// Board reaches `.live` over SSH and a `version` RPC round-trips through the exec bridge.
    func testBoardGoesLiveOverSSHAndVersionRoundTrips() async throws {
        let session = try makeSession()
        let client = makeClient(over: session, sock: try daemonSock())
        defer { client.close(); session.close() }

        try client.connect()                                   // synchronous first open — throws on hard fail
        XCTAssertEqual(client.state, .live, "board did not reach .live over the SSH control bridge")

        let v = try await version(client)
        XCTAssertFalse(v.isEmpty, "version RPC returned empty over SSH")
        XCTAssertEqual(v, OrchestraVersion.current, "version over SSH must match the daemon build")
    }

    /// Background→foreground: dropping the shared session forces `.retrying`, and the SAME session
    /// lazily reconnects to `.live` — the core "never cache the session" reconnect path.
    func testReconnectAfterSessionDrop() async throws {
        let session = try makeSession()
        let client = makeClient(over: session, sock: try daemonSock())
        defer { client.close(); session.close() }

        try client.connect()
        XCTAssertEqual(client.state, .live)

        session.close()                                        // simulate the connection dropping on suspend
        XCTAssertTrue(waitForState(client, .retrying, timeout: 10),
                      "client should observe the drop and enter .retrying")
        XCTAssertTrue(waitForState(client, .live, timeout: 20),
                      "client should lazily reconnect the shared session to .live")

        // A live RPC after reconnect proves the fresh child channel actually works, not just the state flag.
        let v = try await version(client)
        XCTAssertEqual(v, OrchestraVersion.current)
    }

    /// The **multiplex-fold proof**: ONE `IOSSSHSession` (one auth, one tailnet guard, one TOFU pin) vends
    /// TWO independent control channels concurrently, both reaching `.live` and round-tripping `version`.
    /// The board and a folded terminal are exactly two such consumers of the single shared session.
    func testSessionMultiplexesTwoControlChannels() async throws {
        let session = try makeSession()
        let sock = try daemonSock()
        let board = makeClient(over: session, sock: sock)      // stand-in for the board control channel
        let aux = makeClient(over: session, sock: sock)        // stand-in for a folded terminal's channel
        defer { board.close(); aux.close(); session.close() }

        try board.connect()
        try aux.connect()
        XCTAssertEqual(board.state, .live)
        XCTAssertEqual(aux.state, .live, "second channel on the SAME session failed to open — no multiplex")

        // Both channels round-trip independently over the one authenticated connection.
        let va = try await version(board)
        let vb = try await version(aux)
        XCTAssertEqual(va, OrchestraVersion.current)
        XCTAssertEqual(vb, OrchestraVersion.current)
    }
}
