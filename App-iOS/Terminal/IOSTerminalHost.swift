import SwiftUI
import OrchestraKit
import OrchestraUI
import NIOTransportServices
import NIOCore

/// App-wide NIO runtime for terminal SSH sessions. One shared event-loop group so each terminal
/// doesn't spin up its own threads; terminals are few and short-lived, so a single loop is plenty.
///
/// This is a **NIOTransportServices** group (Network.framework-backed), not a POSIX
/// `MultiThreadedEventLoopGroup`: on iOS only `NWConnection` brings up / selects the cellular data path
/// (and is VPN/Tailscale-aware), so the whole SSH transport must ride NIOTS or it goes dead-silent on
/// cellular. The dial itself is `NIOTSConnectionBootstrap` in `IOSSSHSession.connect()`.
enum TerminalRuntime {
    static let group: EventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
}

/// The iOS `TerminalHost`: mounts a live SwiftTerm terminal driven over an SSH PTY that runs the tmux
/// attach recipe on the Mac (no daemon byte-proxy). Replaces F3's "coming soon" placeholder. The
/// Agent/Terminal/Takeover surfaces (T2/T3/T4) inject this through F2's `TerminalHost` Environment key.
struct IOSTerminalHost: TerminalHost {
    /// The client's connection list — terminals SSH to the **active connection's** target (unified config;
    /// no separate `orch_ssh_target`). Defaults to a fresh store so DEBUG/test construction stays cheap.
    var connections: ConnectionStore = ConnectionStore()

    /// The board's shared `IOSSSHSession` provider (P2 multiplex fold). When it targets the same Mac, a
    /// terminal opens its PTY channel on this ONE authenticated connection instead of a second SSH auth.
    /// Defaults to none — the DEBUG/T1 harness path, where `SSHPTYChannel` makes a private session.
    var sessionProvider: @Sendable () -> IOSSSHSession? = { nil }

    /// Plain (additive) attach — the read-only view path used by DebugTerminalTab and the Agent tab's
    /// captured terminal. Non-exclusive (`takeover: false`), no Select.
    func attach(target: TmuxTarget) -> AnyView {
        terminalView(target: target, takeover: false, control: nil, selectMode: false)
    }

    /// T2 Terminal-tab live shell: additive `selectMode` overload (non-exclusive, no takeover chrome).
    /// `forwardScroll` turns on swipe-to-scroll: the live shell is a `tmux attach` (alternate screen, no
    /// SwiftTerm scrollback), so a one-finger swipe is forwarded to tmux as wheel events and tmux scrolls
    /// its own history — the same mechanism the desktop live shell uses (`IOSTerminalView.forwardScroll`).
    func attach(target: TmuxTarget, selectMode: Bool) -> AnyView {
        terminalView(target: target, takeover: false, control: nil, selectMode: selectMode,
                     forwardScroll: true)
    }

    /// T2 live shell WITH an imperative `control` handle — same non-exclusive, swipe-to-scroll attach as
    /// `attach(target:selectMode:)`, but threaded so the Terminal tab's **Hide keyboard** button can
    /// `resignFirstResponder` (drop the soft keyboard while the terminal stays visible and swipe-scrollable),
    /// mirroring the takeover's disarm without the takeover's arming chrome. `control` also observes the
    /// tap-to-type focus (via `onUserArmed`) so the tab knows when to show the button. Scroll stays
    /// one-finger regardless of arm state — `forwardScroll` keeps mouse reporting off (see `IOSTerminalView`).
    func attach(target: TmuxTarget, selectMode: Bool, control: TerminalControl) -> AnyView {
        terminalView(target: target, takeover: false, control: control, selectMode: selectMode,
                     forwardScroll: true)
    }

    /// **Exclusive takeover attach** (PR T4). Runs the `takeover` recipe (`detach-client` first) so the
    /// phone becomes the sole client of the `agent` view session — no resize-fight with a leftover client.
    /// Takes a `TerminalControl` so the takeover chrome (accessory bar, arming, font, Select) can drive it.
    /// Call this only *after* acquiring the lease (`takeOverAgentTerminalAsPhone`) so the desktop has
    /// already unmounted per D5.
    ///
    /// `shouldReconnect` gates automatic reconnects on the phone still holding the lease (#7): once a desktop
    /// retake flips ownership away, re-running the exclusive `detach-client` recipe would kick the desktop
    /// that just took control — so a lease-blind reconnect must not happen.
    func takeoverAttach(target: TmuxTarget, control: TerminalControl,
                        shouldReconnect: @escaping () -> Bool = { true }) -> AnyView {
        terminalView(target: target, takeover: true, control: control, selectMode: false,
                     shouldReconnect: shouldReconnect)
    }

    private func terminalView(target: TmuxTarget, takeover: Bool, control: TerminalControl?, selectMode: Bool,
                              forwardScroll: Bool = false,
                              shouldReconnect: @escaping () -> Bool = { true }) -> AnyView {
        // No Mac connection configured → render a live terminal that explains setup instead of hanging on
        // a black rectangle. Set it in Settings → Connection; `resolve` also honors ORCH_SSH_TARGET for the
        // dev/Simulator path.
        guard let endpoint = SSHEndpoint.resolve(connection: connections.active) else {
            let banner = Self.setupBanner()
            return AnyView(
                IOSTerminalView(makeChannel: { LoopbackChannel(banner: banner) }, control: control,
                                selectMode: selectMode, forwardScroll: forwardScroll,
                                shouldReconnect: shouldReconnect)
                    .id("unconfigured:\(target.session):\(target.window)"))
        }

        // The exact grouped view-session recipe the desktop uses, wrapped for a non-interactive SSH
        // exec (PATH/locale prelude). Idempotent server-side, so a reconnect reuses the view session.
        let script = TmuxAttach.attachScript(socket: target.socket, session: target.session,
                                             window: target.window, takeover: takeover)
        let command = TmuxAttach.sshExecCommand(script: script)
        let group = TerminalRuntime.group

        let sessionProvider = self.sessionProvider
        return AnyView(
            IOSTerminalView(makeChannel: {
                SSHPTYChannel(endpoint: endpoint, command: command, group: group,
                              sharedSession: sessionProvider)
            }, control: control, selectMode: selectMode, forwardScroll: forwardScroll,
            shouldReconnect: shouldReconnect)
            // Stable identity per attach target so SwiftUI keeps ONE Coordinator (and one SSH session)
            // across re-renders — the client half of reconnect idempotency. `takeover` is part of the id so
            // switching modes rebuilds the session with the right recipe.
            .id("\(endpoint.user)@\(endpoint.host):\(target.session):\(target.window):\(takeover)"))
    }

    /// Instructions shown when no SSH target is configured — including this device's public key line to
    /// paste into the Mac's `~/.ssh/authorized_keys` (per-device SSH key, phone-client 01-design).
    private static func setupBanner() -> String {
        var lines = [
            "Mac connection not configured.",
            "",
            "Add your Mac in Settings → Connection:",
            "its Tailscale name (you@my-mac.tailnet.ts.net) or a 100.64.0.0/10 tailnet IP.",
            "",
        ]
        if let key = try? SSHKeyStore.authorizedKeyLine() {
            lines += ["Trust this device — add to the Mac's ~/.ssh/authorized_keys:", "", key]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
