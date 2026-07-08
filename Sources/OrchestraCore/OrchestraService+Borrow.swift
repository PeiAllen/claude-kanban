import Foundation

extension OrchestraService {

    /// `borrow` (O3) — own the bare-parent borrow lifecycle. When a child ships up the tree but its
    /// parent branch has NO live card (bare), the daemon creates/registers a throwaway worktree checking
    /// out the parent at a canonical `orch-borrow-*` path and returns it. The AGENT then squash-merges
    /// the child into it and commits (the daemon never commits — a bare branch has no owner, so this
    /// doesn't breach the owning-agent rule). `release` (or the child's archive / a startup sweep) tears
    /// the worktree down. Refuses a remote parent (publish a PR) or a parent that DOES have a live card
    /// (send it a merge-request instead).
    @discardableResult
    public func borrow(ref: String, source: ActivitySource = .daemon) async throws -> String {
        let child = try await resolveRef(ref)
        guard child.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards can borrow a parent")
        }
        guard let link = await lineage.read(repo: child.repo, branch: child.branch) else {
            throw OrchestraError.invalidParams("card has no parent link to borrow")
        }
        guard RemoteParentRef.parse(link.parent, remotes: gitRemotes(repo: child.repo)) == nil else {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) is remote — publish a stacked PR instead of borrowing")
        }
        let active = await store.all()
        if let owner = derivedCard(repo: child.repo, branch: link.parent, among: active) {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) has a live card (\(owner.shortId)) — `orchestra merge-request "
                + "\(child.shortId)` instead of borrowing")
        }
        let path = try worktrees.borrow(repo: child.repo, branch: link.parent)
        borrowedWorktrees[child.id] = path
        emitActivity(.command, child, source,
            "borrowed bare parent \(link.parent) at \(path) — squash-merge there, then `orchestra shipped \(child.shortId)`")
        return path
    }

    /// `release` — tear down the child's borrow worktree (force: it is a throwaway). Idempotent; also
    /// best-effort removes the canonical path if the in-memory registration was lost (daemon restart).
    public func release(ref: String, source: ActivitySource = .daemon) async throws {
        let child = try await resolveRef(ref)
        if let path = borrowedWorktrees[child.id] {
            try? worktrees.remove(worktree: path, force: true)
            borrowedWorktrees[child.id] = nil
        } else if let link = await lineage.read(repo: child.repo, branch: child.branch) {
            try? worktrees.remove(worktree: worktrees.borrowPath(repo: child.repo, branch: link.parent), force: true)
        }
        emitActivity(.command, child, source, "released borrow")
    }

    /// Startup sweep: prune orphaned `orch-borrow-*` worktrees (a crashed borrow left the parent checked
    /// out in a stray worktree, blocking future spawns/borrows). At startup nothing is legitimately
    /// borrowing, so sweep across every live worktree card's repo. Also clears stale registrations.
    public func sweepOrphanBorrows() async {
        let repos = Set(await store.all().filter { !$0.archived && $0.origin == .worktree }.map(\.repo))
        for repo in repos { worktrees.pruneOrphanBorrows(repo: repo) }
        borrowedWorktrees.removeAll()
    }
}
