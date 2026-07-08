#if os(macOS)
import OrchestraUI
import OrchestraKit

/// macOS-only terminal accessors on the shared `BoardModel`. They return `AgentTerminalView.TerminalHost`
/// — an App/SwiftTerm type that can't be named inside OrchestraUI — so they live App-side while
/// `BoardModel` itself stays platform-neutral. `ConnectionController` exposes the raw SSH route
/// (`remoteTerminalRoute`) and this maps it onto the terminal-view enum, preserving the exact desktop
/// behaviour that used to live on `BoardModel.terminalHost`.
extension BoardModel {
    /// Terminal host for the active connection: local tmux, or the remote box over the SSH control socket.
    var terminalHost: AgentTerminalView.TerminalHost {
        if let route = connectionController.remoteTerminalRoute {
            return .remote(controlPath: route.controlPath, sshTarget: route.sshTarget)
        }
        return .local
    }
    /// tmux `-L` socket name for the active connection (remote boxes may differ from the local default).
    var terminalTmuxSocket: String { connections.active.remoteTmuxSocket }
}
#endif
