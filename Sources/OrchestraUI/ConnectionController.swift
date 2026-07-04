#if os(macOS)
import Foundation
import OrchestraCore

/// App-side activation of a `Connection`: resolves the LOCAL socket path the `ControlClient` transport
/// should target, and (for remotes) owns the SSH master tunnel. `.local` returns `Config.socketPath`
/// with no SSH; `.remote` spins up an `SSHMaster` and returns its forwarded local socket.
///
/// Host-only (macOS): it drives SSH via `Proc`. iOS reaches the daemon over the dev transport (F3),
/// so the whole type is `#if os(macOS)`-fenced and `BoardModel.connectionController` exists only there.
@MainActor
public final class ConnectionController: ObservableObject {
    @Published private(set) var state: ConnectionState = .down
    /// Set by `BoardModel` so a dropped tunnel triggers a reconnect (respawn master → reconnect client).
    var onTunnelExit: (() -> Void)?

    private var sshMaster: SSHMaster?

    public init() {}

    /// Activate `conn` and return the local socket path for the transport. Throws if the tunnel fails.
    func localSocketPath(for conn: Connection) async throws -> String {
        switch conn.kind {
        case .local:
            state = .live
            return Config.socketPath
        case .remote:
            state = .connecting
            let m = SSHMaster(connection: conn)
            m.onUnexpectedExit = { [weak self] in
                _Concurrency.Task { @MainActor in
                    guard let self, self.sshMaster === m else { return }   // ignore a superseded master
                    self.state = .retrying
                    self.onTunnelExit?()
                }
            }
            try await m.start()
            sshMaster = m
            state = .live
            return m.localSocketPath
        }
    }

    func deactivate() {
        sshMaster?.stop()
        sshMaster = nil
        state = .down
    }

    /// The live remote's SSH routing (control socket + target) while a remote master is up, else `nil`
    /// for a local connection. The App maps this to `AgentTerminalView.TerminalHost` (which can't be
    /// named here — it's an App/SwiftTerm type) in `BoardModel.terminalHost`. Terminals ride the same
    /// multiplexed master — no extra auth/forward.
    public var remoteTerminalRoute: (controlPath: String, sshTarget: String)? {
        if let m = sshMaster, let t = m.target { return (m.controlPath, t) }
        return nil
    }
}
#endif
