import Foundation

/// The outcome of asking a human to approve trusting a path. There is no third "timeout" case: a
/// timeout / no-human / declined all collapse to `.denied` (fail closed → the card runs sandboxed).
public enum TrustGrantOutcome: Sendable, Equatable { case approved, denied }

/// The human-grant seam. Core NEVER decides trust on its own — it asks a resolver, and the resolver
/// stands in for a human answering at a surface (MCP elicitation dialog / CLI tty prompt). The agent
/// may only *trigger* a grant; the resolver is what a human *answers* through.
public protocol TrustGrantResolver: Sendable {
    func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome
}

/// Production resolver. The human gate lives at the *surface* (the MCP bridge elicits; the CLI checks
/// `isatty` + prompts) BEFORE the daemon `trust` command is ever relayed — so by the time core is
/// asked, an interactive surface means a human already approved. Agent/daemon sources can never reach
/// a human of their own, so they are denied: that single rule is both the **autonomy-exemption**
/// ("autonomy cards exempt trust") and the "an agent can't self-grant" guarantee.
public struct SurfaceGrantResolver: TrustGrantResolver {
    public init() {}
    public func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome {
        switch source {
        case .cli, .mcp, .app: return .approved   // surface already gated a human through
        case .agent, .daemon:  return .denied      // no human channel → never self-grant
        }
    }
}

/// Result of a `trust` command, returned to the CLI/MCP caller.
public struct TrustGrantResult: Codable, Sendable, Equatable {
    public let path: String
    public let granted: Bool
    public let alreadyTrusted: Bool
    public init(path: String, granted: Bool, alreadyTrusted: Bool) {
        self.path = path; self.granted = granted; self.alreadyTrusted = alreadyTrusted
    }
}

/// Pure helpers for the interactive CLI grant (kept in core so they are unit-testable; `CLIRunner`
/// supplies the real `isatty` + `readLine`).
public enum TrustPrompt {
    /// A yes-answer to the grant prompt: `y`/`yes` (any case, surrounding space ok). Everything else —
    /// including nil (EOF) and empty (bare Enter) — is a NO. Fail closed.
    public static func isAffirmative(_ line: String?) -> Bool {
        guard let t = line?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return t == "y" || t == "yes"
    }

    /// The actionable message printed when `orchestra trust` is run without a tty (no human to ask).
    /// Deliberately never mentions a `--trust` flag — there isn't one.
    public static func nonInteractiveHelp(_ path: String) -> String {
        """
        orchestra trust: refusing to grant trust for \(path) without an interactive terminal.
        Trust is a human decision — re-run `orchestra trust \(path)` in a real terminal to approve it,
        or spawn the card read-only (agents run sandboxed, no write) if you don't want to grant trust.
        """
    }
}
