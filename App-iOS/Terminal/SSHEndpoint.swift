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
    /// pass to `ssh`. Returns nil for anything without a user and host, or with a present-but-invalid
    /// port (a bad port is a parse failure, not something to silently fold into the host string).
    init?(target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let user = String(trimmed[..<at])
        var rest = String(trimmed[trimmed.index(after: at)...])
        var port = 22
        // An optional `:port` suffix. If a colon is present the trailing segment MUST be a usable port
        // (1…65535); MagicDNS names and IPv4 literals never contain a colon, so this is unambiguous.
        if let colon = rest.lastIndex(of: ":") {
            guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else { return nil }
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
    /// The host must be a **tailnet** address — see `isTailnetHost` (review #5). Both surfaces below use
    /// the Mac's Tailscale name/IP; even on the Simulator (which shares the Mac's network *and* its
    /// MagicDNS resolver) the target is the Mac's `*.ts.net` name or `100.x` address, not `localhost`.
    /// - **Simulator**: `<you>@my-mac.tailnet.ts.net` (or the `100.x` tailnet IP) — a live attach stays
    ///   verifiable without a device, while still satisfying the Tailscale-trust guard.
    /// - **Device**: the same Mac's Tailscale name/IP (phone-client 01-design: SSH-over-Tailscale). A real
    ///   settings surface for this is M5's; T1 reads the env.
    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment) -> SSHEndpoint? {
        guard let t = env["ORCH_SSH_TARGET"], !t.isEmpty else { return nil }
        return SSHEndpoint(target: t)
    }
}

// MARK: - Tailscale-target guard (review #5)

extension SSHEndpoint {
    /// Is `host` an address that can only live inside this user's tailnet?
    ///
    /// **Why this exists.** The iOS SSH client (`SSHPTYChannel`) uses `AcceptHostKeyDelegate`, which
    /// accepts *any* host key. That is deliberate — the owner TRUSTS TAILSCALE and does not want TOFU
    /// host-key pinning (phone-client 01-design: SSH-over-Tailscale to a personal Mac). But blind
    /// host-key acceptance is only safe if the connection genuinely rides the tailnet: Tailscale's
    /// WireGuard layer already authenticates and encrypts the peer, so the SSH host key adds nothing.
    /// If the target were instead a LAN box, `localhost`, or a public host, that same blind acceptance
    /// would be a real MITM hole. So rather than add pinning, we ENFORCE the invariant that makes the
    /// trust valid: the target must be a Tailscale address. Everything else is refused before connect.
    ///
    /// Accepts exactly two shapes:
    /// - **CGNAT `100.64.0.0/10`** — the range Tailscale hands out for tailnet node IPs
    ///   (`100.64.0.0`–`100.127.255.255`). Note this is a strict subset of `100.0.0.0/8`, so ordinary
    ///   public `100.x` addresses outside the /10 are still rejected.
    /// - **MagicDNS `*.ts.net`** — the DNS zone Tailscale MagicDNS serves for tailnet names.
    ///
    /// This is an address-*shape* guard, not proof the packets tunnel through Tailscale; it stops the
    /// misconfigurations (LAN IP, loopback, public host) that make blind host-key acceptance unsafe.
    /// It is intentionally NOT host-key pinning.
    static func isTailnetHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty else { return false }
        // MagicDNS: the tailnet's `.ts.net` zone (a `*.ts.net` name, or the bare zone apex).
        if h == "ts.net" || h.hasSuffix(".ts.net") { return true }
        // Tailscale CGNAT 100.64.0.0/10: first octet 100 and second octet in 64…127.
        if let octets = ipv4Octets(h) {
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        return false
    }

    /// A clear, user-facing reason a target is refused, or nil when it is a valid tailnet host. Fed to
    /// the terminal's `.failed` banner so a misconfigured `ORCH_SSH_TARGET` explains itself.
    static func tailnetRejectionReason(for host: String) -> String? {
        guard !isTailnetHost(host) else { return nil }
        return "Refusing to connect to “\(host)”: not a Tailscale address. iOS terminals accept the "
             + "server's host key only because the target is reached over Tailscale, so the target must "
             + "be a tailnet address — a 100.64.0.0/10 IP or a *.ts.net MagicDNS name. Point "
             + "ORCH_SSH_TARGET at the Mac's tailnet name/IP (not a LAN IP, localhost, or public host)."
    }

    /// Parse a strict dotted-quad IPv4 literal into its four octets, or nil if `s` isn't one (so a
    /// hostname like `example.com` or a partial `100.64` is not mistaken for an address).
    private static func ipv4Octets(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let v = Int(part), (0...255).contains(v) else { return nil }
            octets.append(v)
        }
        return octets
    }
}
