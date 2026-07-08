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
    /// `base` (BT2) is the start-point for a NEWLY-created branch only — an existing branch ignores it.
    /// An unknown `base` throws `.invalidParams` *before* any worktree is cut (no half-created dir).
    @discardableResult
    public func ensure(repo: String, branch: String, base: String? = nil)
        throws -> (worktree: String, created: Bool, branchExisted: Bool) {
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
            argv = ["git", "-C", realRepo, "worktree", "add", wt, branch]   // existing branch ignores `base`
        } else {
            var a = ["git", "-C", realRepo, "worktree", "add", "-b", branch, wt]
            if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                // Validate the start-point BEFORE `worktree add`, so an unknown base leaves no dir.
                if base.hasPrefix("refs/") {
                    // A fully-qualified ref (a fetched remote private ref, refs/orch/parents/…, BT6).
                    // Use it verbatim as the start-point — no refs/heads/ pinning.
                    guard refExists(repo: realRepo, ref: base) else {
                        throw OrchestraError.invalidParams("base ref not found: \(base)")
                    }
                    a.append(base)
                } else {
                    // Local branch base (BT2). Pin to the LOCAL branch ref: a bare `base` would
                    // disambiguate to a same-named tag (git's rev precedence), starting the child off the
                    // wrong commit — or failing outright on an ambiguous ref.
                    guard branchExists(repo: realRepo, branch: base) else {
                        throw OrchestraError.invalidParams("base branch not found: \(base)")
                    }
                    a.append("refs/heads/\(base)")
                }
            }
            argv = a
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

    // MARK: - bare-parent borrow (O3)

    /// The canonical throwaway-worktree path for borrowing `branch` (a bare parent to squash-merge a
    /// child into). Distinct from a normal card worktree (`orch-borrow-` prefix under the repo's
    /// worktree dir) so it never collides with a future spawn onto the parent, and so the orphan sweep
    /// can recognise it by name.
    public func borrowPath(repo: String, branch: String) -> String {
        let realRepo = (try? resolver.resolveRepo(repo)) ?? repo
        let repoName = (realRepo as NSString).lastPathComponent
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return "\(config.worktreesRoot)/\(repoName)/orch-borrow-\(safe)"
    }

    /// Create (or reuse) a throwaway worktree checking out the EXISTING `branch` at its canonical borrow
    /// path — the agent then squash-merges into it and commits (the daemon never commits). Idempotent.
    @discardableResult
    public func borrow(repo: String, branch: String) throws -> String {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = borrowPath(repo: realRepo, branch: branch)
        try resolver.assertAllowed(wt)
        if FileManager.default.fileExists(atPath: wt) { return wt }
        guard branchExists(repo: realRepo, branch: branch) else {
            throw OrchestraError.invalidParams("cannot borrow: branch not found: \(branch)")
        }
        try FileManager.default.createDirectory(
            atPath: (wt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let r = try Proc.run(["git", "-C", realRepo, "worktree", "add", wt, branch])
        if !r.ok {
            let msg = r.stderr.lowercased()
            if msg.contains("already checked out") || msg.contains("is already used by worktree") {
                throw OrchestraError.branchInUse(branch)
            }
            throw OrchestraError.io(r.stderr.isEmpty ? "git worktree add (borrow) failed" : r.stderr)
        }
        return wt
    }

    /// Sweep orphaned `orch-borrow-*` worktrees in `repo` (a crashed borrow leaves the parent branch
    /// checked out in a stray worktree, which then blocks future spawns + borrows onto that branch). A
    /// borrow is a throwaway, so force-remove regardless of dirtiness. Best-effort.
    public func pruneOrphanBorrows(repo: String) {
        guard let realRepo = try? resolver.resolveRepo(repo),
              let r = try? Proc.run(["git", "-C", realRepo, "worktree", "list", "--porcelain"]), r.ok else { return }
        for line in r.stdout.split(separator: "\n") where line.hasPrefix("worktree ") {
            let path = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespaces)
            if (path as NSString).lastPathComponent.hasPrefix("orch-borrow-") {
                try? remove(worktree: path, force: true)
            }
        }
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

    /// Does a fully-qualified ref resolve? (Used for a remote private-ref start-point, refs/orch/parents/…)
    func refExists(repo: String, ref: String) -> Bool {
        let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref])
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
