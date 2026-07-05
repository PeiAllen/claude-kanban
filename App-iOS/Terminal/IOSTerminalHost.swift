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
    /// Plain (additive) attach — the read-only view path used by DebugTerminalTab and the Agent tab's
    /// captured terminal. Non-exclusive (`takeover: false`), no Select.
    func attach(target: TmuxTarget) -> AnyView {
        terminalView(target: target, takeover: false, control: nil, selectMode: false)
    }

    /// T2 Terminal-tab live shell: additive `selectMode` overload (non-exclusive, no takeover chrome).
    func attach(target: TmuxTarget, selectMode: Bool) -> AnyView {
        terminalView(target: target, takeover: false, control: nil, selectMode: selectMode)
    }

    /// **Exclusive takeover attach** (PR T4). Runs the `takeover` recipe (`detach-client` first) so the
    /// phone becomes the sole client of the `agent` view session — no resize-fight with a leftover client.
    /// Takes a `TerminalControl` so the takeover chrome (accessory bar, arming, font, Select) can drive it.
    /// Call this only *after* acquiring the lease (`takeOverAgentTerminalAsPhone`) so the desktop has
    /// already unmounted per D5.
    func takeoverAttach(target: TmuxTarget, control: TerminalControl) -> AnyView {
        terminalView(target: target, takeover: true, control: control, selectMode: false)
    }

    private func terminalView(target: TmuxTarget, takeover: Bool, control: TerminalControl?, selectMode: Bool) -> AnyView {
        // No SSH target configured → render a live terminal that explains setup instead of hanging on a
        // black rectangle. (A real settings surface for the endpoint is M5's; T1 reads ORCH_SSH_TARGET.)
        guard let endpoint = SSHEndpoint.resolve() else {
            let banner = Self.setupBanner()
            return AnyView(
                IOSTerminalView(makeChannel: { LoopbackChannel(banner: banner) }, control: control, selectMode: selectMode)
                    .id("unconfigured:\(target.session):\(target.window)"))
        }

        // The exact grouped view-session recipe the desktop uses, wrapped for a non-interactive SSH
        // exec (PATH/locale prelude). Idempotent server-side, so a reconnect reuses the view session.
        let script = TmuxAttach.attachScript(socket: target.socket, session: target.session,
                                             window: target.window, takeover: takeover)
        let command = TmuxAttach.sshExecCommand(script: script)
        let group = TerminalRuntime.group

        return AnyView(
            IOSTerminalView(makeChannel: {
                SSHPTYChannel(endpoint: endpoint, command: command, group: group)
            }, control: control, selectMode: selectMode)
            // Stable identity per attach target so SwiftUI keeps ONE Coordinator (and one SSH session)
            // across re-renders — the client half of reconnect idempotency. `takeover` is part of the id so
            // switching modes rebuilds the session with the right recipe.
            .id("\(endpoint.user)@\(endpoint.host):\(target.session):\(target.window):\(takeover)"))
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
