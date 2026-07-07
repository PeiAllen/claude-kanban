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

    /// `synced` — the agent's "I merged/restacked the parent down" report: record the parent's current
    /// tip as the new recorded base and recompute (→ `inSync`). Idempotent.
    @discardableResult
    public func synced(ref: String, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a parent to sync")
        }
        guard let link = await lineage.read(repo: t.repo, branch: t.branch) else {
            throw OrchestraError.invalidParams("card has no parent link to sync")
        }
        guard let tip = treeTip(repo: t.repo, link.parent) else {
            throw OrchestraError.invalidParams("parent ref not found: \(link.parent)")
        }
        try await lineage.updateBase(repo: t.repo, branch: t.branch, oid: tip)
        await recomputeTreeStat(t.id)
        emitActivity(.command, t, source, "synced parent \(link.parent)")
        return (await store.get(t.id)) ?? t
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

    // MARK: - TreeStat maintenance (BT4)

    /// Recompute the card's `TreeStat` from its lineage link; persist + emit **only when it changed**
    /// (idempotent — safe to call freely from the report funnel), exactly like `recomputeDiffStat`. A
    /// card with no parent link resolves to `nil`. Local parents only (BT4 scope); `parentMerged`
    /// (BT5 `shipped`) and remote tips (BT6) are layered on later.
    func recomputeTreeStat(_ id: UUID) async {
        guard let t = await store.get(id), t.origin == .worktree else { return }
        let link = await lineage.read(repo: t.repo, branch: t.branch)
        let old = t.treeStat
        let new = link.map { computeTreeStat(repo: t.repo, link: $0) }
        guard new != old else { return }                       // no delta → no persist, no emit
        guard let saved = try? await store.update(id, { $0.treeStat = new }) else { return }
        emit(.taskUpserted(saved))
        // Stale nudge: fire ONCE, only on the inSync → stale edge (never per-commit, never stale→stale,
        // never on a first compute that lands on stale). Enqueue + wake — the `concludeCard` idiom.
        if old?.state == .inSync, new?.state == .stale, let parent = link?.parent {
            try? await inbox.enqueue(id, "parent \(parent) moved ahead — merge it down, then run "
                + "`orchestra synced \(saved.shortId)`")
            await wake(id)
        }
    }

    /// Coalescing per-card trigger for `recomputeTreeStat` — a one-shot debounce off the report funnel,
    /// twin of `scheduleDiffStat`.
    func scheduleTreeStat(_ id: UUID) {
        treeStatDebounce[id]?.cancel()
        treeStatDebounce[id] = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(750))
            if _Concurrency.Task.isCancelled { return }
            await self?.recomputeTreeStat(id)
            await self?.clearTreeStatDebounce(id)
        }
    }

    private func clearTreeStatDebounce(_ id: UUID) { treeStatDebounce[id] = nil }

    /// Schedule a TreeStat recompute for each LIVE child card of `branch` — a card whose branch records
    /// `branch` as its parent. Called from the report funnel: a parent card's activity may have advanced
    /// its tip, staling its children.
    func scheduleChildTreeStats(repo: String, of branch: String) async {
        let childBranches = await lineage.children(repo: repo, of: branch)
        guard !childBranches.isEmpty else { return }
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for child in childBranches {
            if let card = active.first(where: { $0.repo == repo && $0.branch == child }) {
                scheduleTreeStat(card.id)
            }
        }
    }

    /// Derive a child's `TreeStat` from its lineage link using only local git. Parent tip gone
    /// (branch deleted / bad ref) or an empty recorded base ⇒ `restackNeeded`. Otherwise `behind` =
    /// commits in `base..tip`; if the base is no longer the tip's ancestor (parent rewrote/rebased) ⇒
    /// `restackNeeded`, else `inSync` (behind 0) / `stale` (behind > 0).
    private func computeTreeStat(repo: String, link: ParentLink) -> TreeStat {
        guard !link.base.isEmpty, let tip = treeTip(repo: repo, link.parent) else {
            return TreeStat(state: .restackNeeded)
        }
        let behind = treeBehind(repo: repo, base: link.base, tip: tip)
        if !treeBaseIsAncestor(repo: repo, base: link.base, tip: tip) {
            return TreeStat(state: .restackNeeded, behind: behind)
        }
        return TreeStat(state: behind == 0 ? .inSync : .stale, behind: behind)
    }

    /// `git rev-parse --verify --quiet <ref>` — nil when the ref can't be resolved (parent deleted).
    private func treeTip(repo: String, _ ref: String) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref]),
              r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// Commit count in `base..tip` (how far the parent advanced past the recorded base). 0 on error.
    private func treeBehind(repo: String, base: String, tip: String) -> Int {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-list", "--count", "\(base)..\(tip)"]),
              r.ok, let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return n
    }

    /// True iff `base` is an ancestor of `tip` (exit 0). Exit 1 = not an ancestor; any other failure is
    /// treated as not-an-ancestor so a broken base surfaces as `restackNeeded` rather than silently inSync.
    private func treeBaseIsAncestor(repo: String, base: String, tip: String) -> Bool {
        guard let r = try? Proc.run(["git", "-C", repo, "merge-base", "--is-ancestor", base, tip]) else {
            return false
        }
        return r.ok
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
