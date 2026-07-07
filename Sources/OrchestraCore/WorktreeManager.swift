import Foundation

/// repo + branch -> git worktree (ensure / path / remove) via `git`. Every path passes
/// `PathResolver.assertAllowed`. Archive removes the worktree dir but keeps the branch.
public struct WorktreeManager: Sendable {
    let config: Config
    let resolver: PathResolver

    public init(config: Config, resolver: PathResolver? = nil) {
        self.config = config
        self.resolver = resolver ?? PathResolver(config: config)
    }

    /// Pure: the computed worktree path for a repo + branch (powers the Spawn sheet field).
    public func path(repo: String, branch: String) -> String {
        config.worktreePath(repo: repo, branch: branch)
    }

    /// Ensure a worktree exists for repo + branch. Idempotent. Returns (worktree, created, branchExisted).
    @discardableResult
    public func ensure(repo: String, branch: String) throws -> (worktree: String, created: Bool, branchExisted: Bool) {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = path(repo: realRepo, branch: branch)
        try resolver.assertAllowed(wt)

        if FileManager.default.fileExists(atPath: wt) {
            return (wt, false, true)   // a live worktree implies the branch already exists
        }
        try FileManager.default.createDirectory(
            atPath: (wt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Does the branch already exist?
        let exists = branchExists(repo: realRepo, branch: branch)
        let argv: [String]
        if exists {
            argv = ["git", "-C", realRepo, "worktree", "add", wt, branch]
        } else {
            argv = ["git", "-C", realRepo, "worktree", "add", "-b", branch, wt]
        }
        let r = try Proc.run(argv)
        if !r.ok {
            let msg = r.stderr.lowercased()
            if msg.contains("already checked out") || msg.contains("is already used by worktree") {
                throw OrchestraError.branchInUse(branch)
            }
            throw OrchestraError.io(r.stderr.isEmpty ? "git worktree add failed" : r.stderr)
        }
        return (wt, true, exists)
    }

    /// Remove a worktree directory (keeps the branch). Guards a dirty tree unless `force`.
    public func remove(worktree: String, force: Bool = false) throws {
        try resolver.assertAllowed(worktree)
        guard FileManager.default.fileExists(atPath: worktree) else { return }
        if !force && isDirty(worktree: worktree) {
            throw OrchestraError.worktreeDirty(worktree)
        }
        var argv = ["git", "-C", worktree, "worktree", "remove"]
        if force { argv.append("--force") }
        argv.append(worktree)
        let r = try Proc.run(argv)
        if !r.ok {
            // Fall back to pruning from the parent repo when the dir is already gone/detached.
            _ = try? Proc.run(["git", "-C", worktree, "worktree", "prune"])
            if FileManager.default.fileExists(atPath: worktree) {
                throw OrchestraError.io(r.stderr.isEmpty ? "git worktree remove failed" : r.stderr)
            }
        }
    }

    func branchExists(repo: String, branch: String) -> Bool {
        let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
        return r?.ok ?? false
    }

    /// True if the worktree has uncommitted changes. **Fails safe:** if git can't be queried we treat
    /// the tree as dirty so `remove` (without `force`) never deletes work it couldn't verify is clean.
    func isDirty(worktree: String) -> Bool {
        guard let r = try? Proc.run(["git", "-C", worktree, "status", "--porcelain"]), r.ok else {
            return true
        }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
