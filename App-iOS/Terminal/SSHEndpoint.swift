import Foundation

/// Where the tmux server (the Mac running orchestrad) lives, and how the phone reaches it over SSH.
/// The phone attaches terminals over the Mac's *own* SSH PTY — "no daemon byte-proxy" (phone-client
/// 01-design). Deliberately tiny and provider-neutral (a terminal is not Claude- or Codex-specific).
struct SSHEndpoint: Equatable {
    var host: String
    var port: Int
    var user: String

    init(host: String, port: Int = 22, user: String) {
        self.host = host; self.port = port; self.user = user
    }

    /// Parse a `user@host[:port]` target — the same shape the desktop's `SSHMaster`/`RemoteCommands`
    /// pass to `ssh`. Returns nil for anything without a user and host.
    init?(target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let user = String(trimmed[..<at])
        var rest = String(trimmed[trimmed.index(after: at)...])
        var port = 22
        if let colon = rest.lastIndex(of: ":"),
           let p = Int(rest[rest.index(after: colon)...]) {
            port = p
            rest = String(rest[..<colon])
        }
        guard !user.isEmpty, !rest.isEmpty else { return nil }
        self.init(host: rest, port: port, user: user)
    }

    /// Resolve the endpoint the terminal should SSH to, from `ORCH_SSH_TARGET` (env / Simulator launch
    /// arg — mirrors how F3 wires `ORCH_DEV_SOCKET`). Returns nil when unconfigured, so the terminal
    /// shows a "configure SSH" banner rather than failing silently.
    ///
    /// - **Simulator**: the app shares the Mac's network, so the target is typically `<you>@localhost`
    ///   (requires Remote Login on the Mac). This is what makes a live attach verifiable without a device.
    /// - **Device**: the Mac's Tailscale name/IP, e.g. `<you>@my-mac.tailnet.ts.net` (phone-client
    ///   01-design: SSH-over-Tailscale). A real settings surface for this is M5's; T1 reads the env.
    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment) -> SSHEndpoint? {
        guard let t = env["ORCH_SSH_TARGET"], !t.isEmpty else { return nil }
        return SSHEndpoint(target: t)
    }
}
