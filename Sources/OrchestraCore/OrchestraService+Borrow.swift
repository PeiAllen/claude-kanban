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
            throw OrchestraError.invalidParams(
                "card has no parent link to borrow — set one with `orchestra set-parent \(child.shortId) <branch>`")
        }
        guard RemoteParentRef.parse(link.parent, remotes: gitRemotes(repo: child.repo)) == nil else {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) is remote — publish a stacked PR instead of borrowing "
                + "(`git push -u origin \(child.branch)` then `gh pr create --base <parentHeadRef>`)")
        }
        let active = await store.all()
        if let owner = derivedCard(repo: child.repo, branch: link.parent, among: active) {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) has a live card (\(owner.shortId)) — `orchestra merge-request "
                + "\(child.shortId)` instead of borrowing")
        }
        // Exactly-one-borrower. `WorktreeManager.borrow` is idempotent by file-existence, so without this
        // a SECOND child borrowing the SAME bare parent would silently be handed the sibling's live
        // worktree — both would squash-merge into one tree and either `release` would yank it out from
        // under the other. Enforce ownership here: the calling child may re-borrow its own registered
        // path (idempotent), but any other holder — or a stray `orch-borrow-*` dir with no registration
        // (a crashed borrow / a not-yet-swept restart) — is refused with actionable guidance.
        // Ownership is keyed by exact path string; this is sound because EVERY borrow path — both the
        // values stored in `borrowedWorktrees` and every lookup here / in `release` — originates from the
        // single canonical `worktrees.borrowPath` (normalized via resolveRepo). Never register or compare
        // a hand-built path, or the holder lookup could miss and re-open the sharing/deletion hole.
        let path = worktrees.borrowPath(repo: child.repo, branch: link.parent)
        let holder = borrowedWorktrees.first(where: { $0.value == path })?.key
        if let holder, holder != child.id {
            throw OrchestraError.parentAlreadyBorrowed(link.parent)
        }
        if holder == nil && FileManager.default.fileExists(atPath: path) {
            // No live registration but the borrow dir exists ⇒ a sibling is landing (or crashed). The
            // startup sweep is the recovery for a truly orphaned dir; at runtime, refuse and let it ship.
            throw OrchestraError.parentAlreadyBorrowed(link.parent)
        }
        let created = try worktrees.borrow(repo: child.repo, branch: link.parent)
        borrowedWorktrees[child.id] = created
        emitActivity(.command, child, source,
            "borrowed bare parent \(link.parent) at \(created) — squash-merge there, then `orchestra shipped \(child.shortId)`")
        return created
    }

    /// `release` — tear down the child's borrow worktree (force: it is a throwaway). Idempotent; also
    /// best-effort removes the canonical path if the in-memory registration was lost (daemon restart).
    public func release(ref: String, source: ActivitySource = .daemon) async throws {
        let child = try await resolveRef(ref)
        if let path = borrowedWorktrees[child.id] {
            try? worktrees.remove(worktree: path, force: true)   // only this child's own registered borrow
            borrowedWorktrees[child.id] = nil
        } else if let link = await lineage.read(repo: child.repo, branch: child.branch) {
            // Registry has no entry for this child (post-restart recovery): remove the canonical borrow
            // path — but NEVER yank a borrow another live child currently holds (a non-holder's stray
            // `release` must be a no-op, or it would delete the holder's tree mid-merge).
            let path = worktrees.borrowPath(repo: child.repo, branch: link.parent)
            if !borrowedWorktrees.values.contains(path) {
                try? worktrees.remove(worktree: path, force: true)
            }
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
