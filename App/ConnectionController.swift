import Foundation
import OrchestraCore

/// App-side activation of a `Connection`: resolves the LOCAL socket path the `ControlClient` transport
/// should target, and (for remotes) owns the SSH master tunnel. `.local` returns `Config.socketPath`
/// with no SSH; `.remote` spins up an `SSHMaster` and returns its forwarded local socket.
@MainActor
final class ConnectionController: ObservableObject {
    @Published private(set) var state: ConnectionState = .down
    /// Set by `BoardModel` so a dropped tunnel triggers a reconnect (respawn master → reconnect client).
    var onTunnelExit: (() -> Void)?

    private var sshMaster: SSHMaster?

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

    /// Terminal host for the active connection: `.remote` (control socket + target) while a remote master
    /// is live, else `.local`. Terminals ride the same multiplexed master — no extra auth/forward.
    var terminalHost: AgentTerminalView.TerminalHost {
        if let m = sshMaster, let t = m.target { return .remote(controlPath: m.controlPath, sshTarget: t) }
        return .local
    }
}
