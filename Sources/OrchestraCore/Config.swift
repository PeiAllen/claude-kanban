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

    public init(
        reposRoot: String = Config.defaultReposRoot,
        worktreesRoot: String = Config.defaultWorktreesRoot,
        defaultModel: String? = nil,
        defaultAgentId: String = "claude-code",
        allowlist: [String] = [],
        maxConcurrentRevivals: Int = 4,
        revivalGraceSeconds: Int = 15,
        statusLineMode: StatusLineMode = .passthroughGlobal,
        customStatusLine: String? = nil
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
    }

    // MARK: Defaults

    public static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    public static var defaultReposRoot: String { "\(home)/Documents/Projects" }
    public static var defaultWorktreesRoot: String { "\(home)/.orchestra/worktrees" }

    // MARK: Derived (not user-facing)

    public static var dataDir: String { "\(home)/Library/Application Support/Orchestra" }
    public static var socketPath: String { "\(dataDir)/orchestrad.sock" }
    public static var configPath: String { "\(dataDir)/config.json" }
    public static var tasksPath: String { "\(dataDir)/tasks.json" }
    public static var logPath: String { "\(dataDir)/orchestrad.log" }
    public static var hooksPath: String { "\(dataDir)/claude-hooks.json" }
    public static let tmuxSocket = "orchestra"

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
