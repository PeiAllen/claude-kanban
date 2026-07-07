import Foundation

extension OrchestraService {

    /// `set-parent` (BT1: adopt + clear). `parent == nil`/empty clears the link; otherwise adopts it
    /// with `base := merge-base(branch, parent)` — a metadata-only relink, history untouched.
    /// `mode` other than "adopt" (i.e. "move", which transplants commits) is deferred to a later PR.
    @discardableResult
    public func setParent(ref: String, parent: String?, mode: String = "adopt",
                          source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a branch to re-parent")
        }
        guard mode == "adopt" else {
            throw OrchestraError.invalidParams("mode must be 'adopt' (move is not yet available)")
        }
        let trimmed = parent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = trimmed, !p.isEmpty {
            guard p != t.branch else {
                throw OrchestraError.invalidParams("a branch cannot be its own parent: \(p)")
            }
            let base = try mergeBaseOID(repo: t.repo, t.branch, p)
            try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: base))
            let updated = try await store.update(t.id) { $0.parentBranch = p }
            emit(.taskUpserted(updated))
            emitActivity(.command, updated, source, "set parent → \(p)")
            return updated
        } else {
            try await lineage.clear(repo: t.repo, branch: t.branch)
            let updated = try await store.update(t.id) { $0.parentBranch = nil }
            emit(.taskUpserted(updated))
            emitActivity(.command, updated, source, "cleared parent link")
            return updated
        }
    }

    /// BT2 spawn-with-base (local parents): record lineage for a card whose branch was just CREATED on
    /// top of `base`. The recorded base OID is `base`'s tip at creation — the redirect anchor for later
    /// restack/sync. Returns the canonical parent ref stored on `Task.parentBranch` (the local base name
    /// in BT2; BT6 will canonicalize remote forms). Throws `.invalidParams` if `base` can't be resolved
    /// (defense-in-depth — `WorktreeManager.ensure` already validated it before cutting the worktree).
    func recordSpawnBase(repo: String, branch: String, base: String) async throws -> String {
        let oid = try revParseOID(repo: repo, ref: base)
        try await lineage.set(repo: repo, branch: branch, link: ParentLink(parent: base, base: oid))
        return base
    }

    /// `git rev-parse --verify <ref>` in `repo`, or `.invalidParams` if it doesn't resolve.
    private func revParseOID(repo: String, ref: String) throws -> String {
        let r = try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref])
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !oid.isEmpty else {
            throw OrchestraError.invalidParams("base branch not found: \(ref)")
        }
        return oid
    }

    /// `tree` — a lineage snapshot for a scope: one card (`ref`), a `repo`, or all active cards.
    /// Feeds MCP/CLI (and BT7's board grouping). `treeStat` rides through as-is (nil in BT1).
    public func tree(ref: String?, repo: String?) async throws -> TreeSnapshot {
        let active = await store.all().filter { !$0.archived }
        var scoped = active
        if let ref {
            scoped = [try await resolveRef(ref)]
        } else if let repo {
            let real = (try? resolver.resolveRepo(repo)) ?? repo
            scoped = active.filter { $0.repo == real }
        }
        var nodes: [TreeNode] = []
        for t in scoped where t.origin == .worktree {
            let link = await lineage.read(repo: t.repo, branch: t.branch)
            let children = await lineage.children(repo: t.repo, of: t.branch)
            let parentCardId = link.flatMap { l in
                active.first { $0.repo == t.repo && $0.branch == l.parent }?.id
            }
            nodes.append(TreeNode(ref: t.ref(), cardId: t.id, repo: t.repo, branch: t.branch,
                                  parent: link?.parent, parentCardId: parentCardId,
                                  children: children, treeStat: t.treeStat))
        }
        return TreeSnapshot(nodes: nodes)
    }

    /// `git merge-base <a> <b>` in `repo`, or `.invalidParams` if there is none (e.g. unknown parent).
    private func mergeBaseOID(repo: String, _ a: String, _ b: String) throws -> String {
        let r = try Proc.run(["git", "-C", repo, "merge-base", a, b])
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !oid.isEmpty else {
            throw OrchestraError.invalidParams(
                "no merge-base between \(a) and \(b)" + (r.stderr.isEmpty ? "" : ": \(r.stderr)"))
        }
        return oid
    }
}
