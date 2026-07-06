import Foundation

/// A git repository the daemon can spawn a worktree into, enumerated from `Config.reposRoot`. The
/// phone is a remote client and can't browse the daemon's disk, so the daemon lists these over the
/// control plane (the `spawnRepos` RPC) to populate the Spawn sheet's repo/dir pickers.
public struct RepoCandidate: Codable, Sendable, Hashable, Identifiable {
    /// Absolute path on the daemon's filesystem (what `spawn` needs — the allowlist rejects bare names).
    public var path: String
    /// `path.lastPathComponent`, for display + fuzzy matching.
    public var name: String
    public var id: String { path }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Result of the `spawnRepos` RPC: the repos the daemon can cut a worktree into, plus directory
/// candidates for freeform (borrowed) cards. Both are absolute daemon-side paths. Branches are a
/// separate lazy call (`spawnBranches`) since they're per-repo and only needed once a repo is chosen.
public struct SpawnRepos: Codable, Sendable {
    /// Git repos under `Config.reposRoot`.
    public var repos: [RepoCandidate]
    /// Directory candidates for a freeform card (the repo paths — running a read-only/freeform agent
    /// inside a repo is the common case). The client unions these with dirs derived from existing cards.
    public var dirs: [String]

    public init(repos: [RepoCandidate], dirs: [String]) {
        self.repos = repos
        self.dirs = dirs
    }
}
