import SwiftUI
import OrchestraKit
import OrchestraUI
import NIOPosix
import NIOCore

/// App-wide NIO runtime for terminal SSH sessions. One shared event-loop group so each terminal
/// doesn't spin up its own threads; terminals are few and short-lived, so a single loop is plenty.
enum TerminalRuntime {
    static let group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// The iOS `TerminalHost`: mounts a live SwiftTerm terminal driven over an SSH PTY that runs the tmux
/// attach recipe on the Mac (no daemon byte-proxy). Replaces F3's "coming soon" placeholder. The
/// Agent/Terminal/Takeover surfaces (T2/T3/T4) inject this through F2's `TerminalHost` Environment key.
struct IOSTerminalHost: TerminalHost {
    func attach(target: TmuxTarget) -> AnyView { attach(target: target, selectMode: false) }

    func attach(target: TmuxTarget, selectMode: Bool) -> AnyView {
        // No SSH target configured → render a live terminal that explains setup instead of hanging on a
        // black rectangle. (A real settings surface for the endpoint is M5's; T1 reads ORCH_SSH_TARGET.)
        guard let endpoint = SSHEndpoint.resolve() else {
            let banner = Self.setupBanner()
            return AnyView(
                IOSTerminalView(makeChannel: { LoopbackChannel(banner: banner) }, selectMode: selectMode)
                    .id("unconfigured:\(target.session):\(target.window)"))
        }

        // The exact grouped view-session recipe the desktop uses, wrapped for a non-interactive SSH
        // exec (PATH/locale prelude). Idempotent server-side, so a reconnect reuses the view session.
        let script = TmuxAttach.attachScript(socket: target.socket, session: target.session,
                                             window: target.window)
        let command = TmuxAttach.sshExecCommand(script: script)
        let group = TerminalRuntime.group

        return AnyView(
            IOSTerminalView(makeChannel: {
                SSHPTYChannel(endpoint: endpoint, command: command, group: group)
            }, selectMode: selectMode)
            // Stable identity per attach target so SwiftUI keeps ONE Coordinator (and one SSH session)
            // across re-renders — the client half of reconnect idempotency.
            .id("\(endpoint.user)@\(endpoint.host):\(target.session):\(target.window)"))
    }

    /// Instructions shown when `ORCH_SSH_TARGET` is unset — including this device's public key line to
    /// paste into the Mac's `~/.ssh/authorized_keys` (per-device SSH key, phone-client 01-design).
    private static func setupBanner() -> String {
        var lines = [
            "Terminal not configured.",
            "",
            "Set ORCH_SSH_TARGET=<user>@<host> (Simulator: <you>@localhost with Remote Login on;",
            "device: the Mac's Tailscale name).",
            "",
        ]
        if let key = try? SSHKeyStore.authorizedKeyLine() {
            lines += ["Trust this device — add to the Mac's ~/.ssh/authorized_keys:", "", key]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
