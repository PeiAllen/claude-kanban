import Foundation

public enum StatusLineMode: String, Codable, Sendable {
    /// Render the user's ~/.claude/settings.json statusLine verbatim. Falls back to .orchestraDefault
    /// when no statusLine is set / it exits non-zero / it times out. (Project-level statusLine is v-next.)
    case passthroughGlobal
    /// Render Config.customStatusLine. Empty/fails -> .orchestraDefault.
    case custom
    /// A minimal built-in line (model · ctx%). Also the universal fallback.
    case orchestraDefault
}

/// Daemon-owned, user-managed settings persisted to `dataDir/config.json`. Worktree path =
/// "\(worktreesRoot)/\(repo)/\(branch)". Read/written via the control plane's getConfig/setConfig.
public struct Config: Codable, Sendable, Equatable {
    public var reposRoot: String
    public var worktreesRoot: String
    public var defaultModel: String?
    public var defaultAgentId: String
    public var allowlist: [String]
    public var maxConcurrentRevivals: Int
    public var revivalGraceSeconds: Int
    public var statusLineMode: StatusLineMode
    public var customStatusLine: String?

    /// Wall-clock bound (seconds) for a `git worktree add` checkout — generous because a cold
    /// large-repo checkout can take several seconds (worst known ≈9s). Enforced via `Proc.run(timeout:)`.
    public var worktreeAddTimeout: Int
    /// Wall-clock bound (seconds) for launching an agent session. Consumed by the Stage-4 session layer.
    public var sessionLaunchTimeout: Int
    /// Wall-clock bound (seconds) for fast control ops — tmux control verbs + fast git queries
    /// (`worktree list/remove/prune`, `rev-parse`, `status --porcelain`).
    public var controlTimeout: Int

    public init(
        reposRoot: String = Config.defaultReposRoot,
        worktreesRoot: String = Config.defaultWorktreesRoot,
        defaultModel: String? = nil,
        defaultAgentId: String = "claude-code",
        allowlist: [String] = [],
        maxConcurrentRevivals: Int = 4,
        revivalGraceSeconds: Int = 15,
        statusLineMode: StatusLineMode = .passthroughGlobal,
        customStatusLine: String? = nil,
        worktreeAddTimeout: Int = 600,
        sessionLaunchTimeout: Int = 30,
        controlTimeout: Int = 15
    ) {
        self.reposRoot = reposRoot
        self.worktreesRoot = worktreesRoot
        self.defaultModel = defaultModel
        self.defaultAgentId = defaultAgentId
        self.allowlist = allowlist
        self.maxConcurrentRevivals = maxConcurrentRevivals
        self.revivalGraceSeconds = revivalGraceSeconds
        self.statusLineMode = statusLineMode
        self.customStatusLine = customStatusLine
        self.worktreeAddTimeout = worktreeAddTimeout
        self.sessionLaunchTimeout = sessionLaunchTimeout
        self.controlTimeout = controlTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case reposRoot, worktreesRoot, defaultModel, defaultAgentId, allowlist,
             maxConcurrentRevivals, revivalGraceSeconds, statusLineMode, customStatusLine,
             worktreeAddTimeout, sessionLaunchTimeout, controlTimeout
    }

    /// Custom decode so a pre-upgrade `config.json` lacking the new timeout keys still decodes,
    /// falling back to the defaults (the three knobs are additive-optional). `encode(to:)` stays
    /// synthesized. Existing keys keep their current required-decode semantics.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reposRoot = try c.decode(String.self, forKey: .reposRoot)
        worktreesRoot = try c.decode(String.self, forKey: .worktreesRoot)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultAgentId = try c.decode(String.self, forKey: .defaultAgentId)
        allowlist = try c.decode([String].self, forKey: .allowlist)
        maxConcurrentRevivals = try c.decode(Int.self, forKey: .maxConcurrentRevivals)
        revivalGraceSeconds = try c.decode(Int.self, forKey: .revivalGraceSeconds)
        statusLineMode = try c.decode(StatusLineMode.self, forKey: .statusLineMode)
        customStatusLine = try c.decodeIfPresent(String.self, forKey: .customStatusLine)
        worktreeAddTimeout = try c.decodeIfPresent(Int.self, forKey: .worktreeAddTimeout) ?? 600
        sessionLaunchTimeout = try c.decodeIfPresent(Int.self, forKey: .sessionLaunchTimeout) ?? 30
        controlTimeout = try c.decodeIfPresent(Int.self, forKey: .controlTimeout) ?? 15
    }

    // MARK: Defaults

    public static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    /// The home directory itself — setup-agnostic (works for any user's layout, not just a
    /// `~/Documents/Projects` convention). Repo discovery scans recursively under this root
    /// (see `RepoScanner`), pruning heavy/irrelevant trees so a broad root stays fast.
    public static var defaultReposRoot: String { home }
    public static var defaultWorktreesRoot: String { "\(home)/.orchestra/worktrees" }

    /// Root for ephemeral scratch-card dirs (`~/.orchestra/scratch/<id>`), parallel to worktrees.
    /// Not user-configurable: scratch dirs are throwaway and per-card-id, never shared.
    public static var scratchRoot: String { "\(home)/.orchestra/scratch" }
    /// The scratch dir for a given card id — `scratchRoot/<lowercased-uuid>`.
    public static func scratchDir(_ id: UUID) -> String { "\(scratchRoot)/\(id.uuidString.lowercased())" }

    // MARK: Derived (not user-facing)

    public static var dataDir: String {
        #if os(Linux)
        return dataDir(isLinux: true, home: home, env: ProcessInfo.processInfo.environment)
        #else
        return dataDir(isLinux: false, home: home, env: ProcessInfo.processInfo.environment)
        #endif
    }

    /// Pure resolver for the data dir so both platform branches are unit-testable on either host.
    /// macOS: `~/Library/Application Support/Orchestra` (unchanged). Linux: `$XDG_DATA_HOME/orchestra`
    /// → `~/.local/share/orchestra`. `reposRoot`/`worktreesRoot`/`scratchRoot` stay $HOME-relative.
    static func dataDir(isLinux: Bool, home: String, env: [String: String]) -> String {
        if isLinux {
            let xdg = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/share"
            return "\(xdg)/orchestra"
        }
        return "\(home)/Library/Application Support/Orchestra"
    }
    public static var socketPath: String { "\(dataDir)/orchestrad.sock" }
    public static var configPath: String { "\(dataDir)/config.json" }
    public static var tasksPath: String { "\(dataDir)/tasks.json" }
    /// Per-install control-client identity (D3), a sibling of `tasksPath`. The app persists a stable
    /// clientId here so the daemon can attribute ownership + detect this client's disconnect (D4).
    public static var clientIdPath: String { "\(dataDir)/client-id" }
    public static var trustLedgerPath: String { "\(dataDir)/trust-ledger.json" }
    /// Durable per-card message inbox (F3), sibling to `tasksPath`.
    public static var inboxPath: String { "\(dataDir)/inbox.json" }
    /// Persisted borrow registrations (`[borrowerCardId: path]`), sibling to `inboxPath`.
    public static var borrowsPath: String { "\(dataDir)/borrows.json" }
    /// Registry-owned worktree "materialized" markers (one sentinel file per worktree path), sibling to `inboxPath`.
    public static var worktreeMarkersDir: String { "\(dataDir)/worktree-markers" }
    /// Registered APNs device tokens (N1), sibling to `tasksPath`. The daemon persists each client's
    /// push token + notification-pref snapshot so it can deliver attention pushes while the phone is
    /// backgrounded.
    public static var deviceTokensPath: String { "\(dataDir)/device-tokens.json" }
    public static var logPath: String { "\(dataDir)/orchestrad.log" }
    public static var hooksPath: String { "\(dataDir)/claude-hooks.json" }
    /// Rendered Codex hooks file (SessionStart→orient). CodexAdapter installs it into `$CODEX_HOME/hooks.json`.
    public static var codexHooksPath: String { "\(dataDir)/codex-hooks.json" }
    /// tmux server socket name (`tmux -L <name>`). Overridable via env so an isolated test instance
    /// gets its OWN tmux server (no session collisions / claude launches on the user's live server).
    public static var tmuxSocket: String {
        ProcessInfo.processInfo.environment["ORCHESTRA_TMUX_SOCKET"] ?? "orchestra"
    }

    /// The full set of allowed roots = reposRoot + worktreesRoot + explicit allowlist entries.
    public var allowedRoots: [String] {
        [reposRoot, worktreesRoot] + allowlist
    }

    /// Worktree path for a repo + branch.
    public func worktreePath(repo: String, branch: String) -> String {
        let repoName = (repo as NSString).lastPathComponent
        return "\(worktreesRoot)/\(repoName)/\(branch)"
    }
}
