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

    // The SSH endpoint is now derived from the **active `Connection`** (unified config), not a standalone
    // `orch_ssh_target` setting. See `SSHEndpoint.resolve(connection:env:)` in `Connection+SSHEndpoint.swift`.
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

    /// Validate a user-entered `user@host[:port]` target for the **Settings → Terminal** surface (M5),
    /// returning nil when it is usable and a user-facing reason otherwise. This MIRRORS the connect-time
    /// gate in `SSHPTYChannel.start` — same `tailnetRejectionReason` unless `isTestLoopbackAllowed` — so
    /// Settings never accepts a target the terminal would then silently refuse. An empty field is "unset"
    /// (nil), not an error: the terminal shows its setup banner and `resolve` falls back to the env.
    static func settingsRejectionReason(for target: String,
                                        env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let endpoint = SSHEndpoint(target: trimmed) else {
            return "Enter the target as user@host — e.g. me@my-mac.tailnet.ts.net or me@100.101.102.103."
        }
        if let reason = tailnetRejectionReason(for: endpoint.host),
           !isTestLoopbackAllowed(endpoint.host, env: env) {
            return reason
        }
        return nil
    }

    /// DEBUG-only, opt-in escape from the tailnet guard for the **isolated verify harness** (the T1/T4
    /// scripts point the terminal at a THROWAWAY loopback sshd on `127.0.0.1` whose host key the script
    /// generates). It is gated behind BOTH a `#if DEBUG` build AND an explicit `ORCH_SSH_ALLOW_LOOPBACK=1`
    /// env opt-in that only those scripts set — so a shipped Release app can never reach a non-tailnet
    /// host, and an ordinary DEBUG run (incl. the `TransportTests` that assert loopback is rejected) is
    /// unaffected. Kept OUT of `isTailnetHost`/`tailnetRejectionReason` so those stay pure and honest:
    /// loopback genuinely is *not* a tailnet host; this is a test-transport allowance, not a redefinition.
    /// Safe because the harness's sshd host key is still TOFU-pinned by `PinningHostKeyDelegate`, so the
    /// tailnet invariant isn't what's protecting that channel.
    static func isTestLoopbackAllowed(_ host: String,
                                      env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        guard env["ORCH_SSH_ALLOW_LOOPBACK"] == "1" else { return false }
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
        #else
        return false
        #endif
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
