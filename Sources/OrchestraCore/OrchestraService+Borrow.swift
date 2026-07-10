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
        let remotes = (try? await offActor { self.gitRemotes(repo: child.repo) }) ?? []
        guard RemoteParentRef.parse(link.parent, remotes: remotes) == nil else {
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
        // Exactly-one-borrower + persistence (survives a daemon-only crash) are now enforced INSIDE the
        // registry's `ensureBorrow` — it refuses a rival holder or a stray unregistered `orch-borrow-*`
        // dir with the same `parentAlreadyBorrowed` guidance the old ownership check gave here.
        let w = try await worktrees.ensureBorrow(repo: child.repo, parentBranch: link.parent, borrowerCardId: child.id)
        emitActivity(.command, child, source,
            "borrowed bare parent \(link.parent) at \(w.path) — squash-merge there, then `orchestra shipped \(child.shortId)`")
        return w.path
    }

    /// `release` — tear down the child's borrow worktree (force: it is a throwaway). Idempotent — the
    /// registration is persisted (survives a daemon-only crash/restart), and a non-holder's release is a
    /// no-op (never yanks a borrow another live child currently holds).
    public func release(ref: String, source: ActivitySource = .daemon) async throws {
        let child = try await resolveRef(ref)
        try await worktrees.releaseBorrow(borrowerCardId: child.id)
        emitActivity(.command, child, source, "released borrow")
    }

    /// Startup sweep: prune orphaned `orch-borrow-*` worktrees (a crashed borrow left the parent checked
    /// out in a stray worktree, blocking future spawns/borrows). Liveness-guarded — the registry keeps
    /// any dir whose registered borrower is still non-`archived`; a borrower merely ABSENT from the store
    /// is ambiguous and also kept.
    public func sweepOrphanBorrows() async {
        await worktrees.sweepOrphanBorrows(cards: await store.all())
    }
}
