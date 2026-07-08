import Foundation

extension OrchestraService {

    /// `set-parent` (BT1: adopt + clear). `parent == nil`/empty clears the link; otherwise adopts it
    /// with `base := merge-base(branch, parent)` — a metadata-only relink, history untouched.
    /// `mode` other than "adopt" (i.e. "move", which transplants commits) is deferred to a later PR.
    @discardableResult
    public func setParent(ref: String, parent: String?, mode: String = "adopt", watch: Bool = false,
                          source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a branch to re-parent")
        }
        guard mode == "adopt" || mode == "move" else {
            throw OrchestraError.invalidParams("mode must be 'adopt' or 'move'")
        }
        let trimmed = parent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = trimmed, !p.isEmpty {
            guard p != t.branch else {
                throw OrchestraError.invalidParams("a branch cannot be its own parent: \(p)")
            }
            // BT6: a remote parent (origin/<b>, pr#<N>) is fetched into a private ref, recorded with its
            // canonical form + prNumber, and watched per the flag (default off). `mode` doesn't apply —
            // there is no local history to rebase yet; the child restacks only once the remote parent moves.
            if let remote = RemoteParentRef.parse(p) {
                let oid = try await remoteParents.fetch(repo: t.repo, remote)
                let pr: Int? = { if case .pullRequest(let n) = remote { return n }; return nil }()
                try await lineage.set(repo: t.repo, branch: t.branch,
                    link: ParentLink(parent: remote.canonical, base: oid, prNumber: pr, watch: watch))
                let updated = try await store.update(t.id) {
                    $0.parentBranch = remote.canonical
                    $0.treeStat = TreeStat(state: .inSync, parentIsRemote: true)
                }
                emit(.taskUpserted(updated))
                if watch { startRemoteWatch(cardId: t.id) } else { stopRemoteWatch(t.id) }
                emitActivity(.command, updated, source, "set remote parent → \(remote.canonical)")
                return updated
            }
            if mode == "move" {
                // MOVE: repoint the lineage but KEEP the recorded base — it is the rebase anchor the agent
                // replays from (`rebase --onto <new-parent> <recorded-base>`). Fall back to the merge-base
                // only when there is no prior link to preserve. The daemon never rewrites the branch; it
                // marks restack-needed and nudges the owning card to do the rebase in its own worktree.
                // Validate the target exists — adopt gets this implicitly via merge-base, but move keeps the
                // prior base and would otherwise accept a typo'd parent (leaving a nudge to rebase onto a
                // ref that isn't there). Local refs only in BT5; remote parents are BT6.
                // S3-6: pin refs/heads/ so a same-named tag can't shadow the local parent branch.
                guard treeTip(repo: t.repo, "refs/heads/\(p)") != nil else {
                    throw OrchestraError.invalidParams("parent branch not found: \(p)")
                }
                let existing = await lineage.read(repo: t.repo, branch: t.branch)
                let anchor = try existing?.base
                    ?? mergeBaseOID(repo: t.repo, "refs/heads/\(t.branch)", "refs/heads/\(p)")
                try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: anchor))
                let updated = try await store.update(t.id) {
                    $0.parentBranch = p
                    $0.treeStat = TreeStat(state: .restackNeeded)
                }
                emit(.taskUpserted(updated))
                try? await inbox.enqueue(t.id,
                    "parent moved to \(p) — commit WIP, then `git rebase --onto \(p) \(anchor)`, "
                    + "then `orchestra synced \(updated.shortId)`")
                await wake(t.id)
                emitActivity(.command, updated, source, "moved parent → \(p)")
                return updated
            }
            let base = try mergeBaseOID(repo: t.repo, "refs/heads/\(t.branch)", "refs/heads/\(p)")
            try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: base))
            let updated = try await store.update(t.id) { $0.parentBranch = p }
            emit(.taskUpserted(updated))
            // S2-7: recompute against the NEW parent (else a badge from the previous parent lingers on an
            // idle card) and tear down any remote watch left from a prior remote parent (adopting a local
            // one takes the card off the remote tier).
            stopRemoteWatch(t.id)
            scheduleTreeStat(t.id)
            emitActivity(.command, updated, source, "set parent → \(p)")
            return updated
        } else {
            stopRemoteWatch(t.id)   // BT6: clearing a remote parent tears down its merge-watch
            try await lineage.clear(repo: t.repo, branch: t.branch)
            // S2-7: clear the badge too (compare `shipped`, which nils both) — else `tree` reports a nil
            // parent alongside a stale non-nil treeStat.
            let updated = try await store.update(t.id) { $0.parentBranch = nil; $0.treeStat = nil }
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
        // Resolve the LOCAL branch ref (not a bare `base`, which would disambiguate to a same-named
        // tag) so the recorded OID matches the start-point `WorktreeManager.ensure` cut the child at.
        let oid = try revParseOID(repo: repo, ref: "refs/heads/\(base)")
        try await lineage.set(repo: repo, branch: branch, link: ParentLink(parent: base, base: oid))
        return base
    }

    /// BT6 remote spawn-with-base: record lineage for a card whose branch was CREATED on a fetched remote
    /// private ref. Stores the canonical remote form (`origin/<b>` / `pr#<N>`) + prNumber, and opts the
    /// card into watching by default (owner: auto-on for a remote-base spawn). `oid` is the fetched tip —
    /// the redirect/restack anchor. Returns the canonical string for `Task.parentBranch`.
    func recordSpawnRemoteBase(repo: String, branch: String,
                               ref: RemoteParentRef, oid: String) async throws -> String {
        let pr: Int? = { if case .pullRequest(let n) = ref { return n }; return nil }()
        try await lineage.set(repo: repo, branch: branch,
                              link: ParentLink(parent: ref.canonical, base: oid, prNumber: pr, watch: true))
        return ref.canonical
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
        guard let tip = treeTip(repo: t.repo, link.resolvableRef) else {
            throw OrchestraError.invalidParams("parent ref not found: \(link.parent)")
        }
        // S2-1: record merge-base(child-branch, resolved-parent) — the true sync point — instead of
        // trusting the agent's implicit "I merged the tip down" claim. After an honest merge-down this
        // equals the merged tip; after a racy/bogus `synced` (parent advanced, or no merge happened) it
        // equals the real fork, so it can't silently over-record and mask un-merged parent work. Falls
        // back to the tip only if the child's own branch ref can't be resolved (never for a live card).
        let syncBase = (try? mergeBaseOID(repo: t.repo, "refs/heads/\(t.branch)", link.resolvableRef)) ?? tip
        try await lineage.updateBase(repo: t.repo, branch: t.branch, oid: syncBase)
        // S2-9: cancel any funnel-scheduled recompute for this card so it can't race this direct recompute
        // across the lineage.read suspension and fire a duplicate stale nudge from the pre-sync base.
        treeStatDebounce[t.id]?.cancel()
        treeStatDebounce[t.id] = nil
        await recomputeTreeStat(t.id)
        emitActivity(.command, t, source, "synced parent \(link.parent)")
        return (await store.get(t.id)) ?? t
    }

    /// `shipped` — post-merge bookkeeping, run once a child branch has been merged into its parent
    /// (by the parent's agent for a live parent, or by the child borrowing a bare parent). The daemon
    /// performs NO git surgery here — only lineage config writes + inbox nudges. Three steps, idempotent:
    ///   (a) NOTIFY the parent's card (active card owning `repo` + the child's recorded parent branch) that
    ///       the child landed; no such card ⇒ a warning-level activity item (bare parent, nothing to wake).
    ///   (b) RETARGET the child's OWN children onto the grandparent (the child's parent): repoint each
    ///       child's lineage parent, KEEP its recorded base (the rebase anchor), set `treeStat =
    ///       restackNeeded`, and nudge it to `rebase --onto <grandparent> <recorded-base>` + wake.
    ///   (c) CLEAR the shipped child's own lineage so a second `shipped` is a pure no-op: its parent lookup
    ///       finds nothing (no duplicate notify) and `children(of: child)` is empty because they now point
    ///       at the grandparent (no duplicate nudges).
    @discardableResult
    public func shipped(ref: String, by: String? = nil, source: ActivitySource = .daemon) async throws -> Task {
        let child = try await resolveRef(ref)
        guard child.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards can be shipped")
        }
        // S1-3: the caller's card id (from ORCHESTRA_TASK_ID at the CLI) lets us tell the live-parent flow
        // (the PARENT runs `shipped <child>`) from a self-ship (root/bare: the card runs `shipped <self>`).
        var byCardId: UUID? = nil
        if let by { byCardId = try? await resolveRef(by).id }
        let link = await lineage.read(repo: child.repo, branch: child.branch)
        // S1-2 (goal-4): the retarget target is the shipped child's parent, OR — for a ROOT card that
        // shipped straight to main — the repo's default branch, so its children never strand on a dead
        // parent (inSync-forever). A root ship is not an anomaly (no "no recorded parent link" warning).
        let hadParentLink = link?.parent != nil
        let grandparent = link?.parent ?? defaultBranch(repo: child.repo)

        // (a) notify the parent's card, if one owns the parent branch (only when there WAS a parent link
        // — a root ship merged to main via the standard flow, there is no parent card to wake).
        if hadParentLink, let parent = link?.parent {
            let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
            if let parentCard = active.first(where: { $0.repo == child.repo && $0.branch == parent }) {
                // S1-3: skip the self-echo when the caller IS the parent — it just performed the merge,
                // so a "child merged into you" wake would only make it read about its own action.
                if parentCard.id != byCardId {
                    try? await inbox.enqueue(parentCard.id,
                        "child \(child.branch) (\(child.shortId)) merged into you — it's in your branch now")
                    await wake(parentCard.id)
                }
            } else {
                emitActivity(.warning, child, source,
                    "shipped \(child.branch): no active card owns parent \(parent) to notify")
            }
        }

        // (b) retarget the child's own children onto the grandparent (keep each one's recorded base).
        do {
            let grandchildren = await lineage.children(repo: child.repo, of: child.branch)
            let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
            for gcBranch in grandchildren {
                guard let gcLink = await lineage.read(repo: child.repo, branch: gcBranch) else { continue }
                // Repoint parent; KEEP the recorded base — it is the rebase anchor the agent replays from.
                // Gate the card update on the config write SUCCEEDING: if `set` rejects (cycle guard on a
                // pathological tree), leave `Task.parentBranch`/`treeStat` alone so they never disagree with
                // git-config, and surface a warning instead of silently desyncing.
                do {
                    try await lineage.set(repo: child.repo, branch: gcBranch,
                                          link: ParentLink(parent: grandparent, base: gcLink.base))
                } catch {
                    emitActivity(.warning, child, source,
                        "shipped \(child.branch): could not retarget child \(gcBranch) → \(grandparent)")
                    continue
                }
                // The grandchild's recorded base (old shipped-branch tip) is not an ancestor of the
                // grandparent, so a later `recomputeTreeStat` independently agrees on `restackNeeded` — the
                // report funnel will not silently downgrade this signal before the agent runs `synced`.
                if let card = active.first(where: { $0.repo == child.repo && $0.branch == gcBranch }) {
                    if let saved = try? await store.update(card.id, {
                        $0.parentBranch = grandparent
                        $0.treeStat = TreeStat(state: .restackNeeded)
                    }) {
                        emit(.taskUpserted(saved))
                    }
                    try? await inbox.enqueue(card.id,
                        "parent \(child.branch) shipped — commit WIP, then `git rebase --onto "
                        + "\(grandparent) \(gcLink.base)`, then `orchestra synced \(card.shortId)`")
                    await wake(card.id)
                }
            }
        }

        // (d) S1-3: tell the shipped child its branch landed — it is a stopped card that cannot see the
        // `taskUpserted` event, so without this enqueue+wake it sits live-looking forever (a zombie card).
        // Skip when the caller IS the child (a self-ship: root/bare/borrow — the card ships itself, then
        // archives; it doesn't need to read that it landed).
        if hadParentLink, byCardId != child.id, let parent = link?.parent {
            try? await inbox.enqueue(child.id,
                "your branch landed in \(parent) — verify and archive yourself")
            await wake(child.id)
        }

        // (c) clear the shipped child's own lineage → re-run is a no-op; treeStat clears on next recompute.
        try? await lineage.clear(repo: child.repo, branch: child.branch)
        let updated = (try? await store.update(child.id, { $0.parentBranch = nil; $0.treeStat = nil })) ?? child
        emit(.taskUpserted(updated))
        emitActivity(.command, updated, source, "shipped \(child.branch)")
        return updated
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
                                  parent: link?.parent, parentCardId: parentCardId, base: link?.base,
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
        // S3-5: never recompute/emit/nudge an archived card (a card archived inside the 750 ms debounce
        // window would otherwise get its treeStat rewritten + a durable nudge into a dead inbox).
        guard let t = await store.get(id), t.origin == .worktree, !t.archived else { return }
        let link = await lineage.read(repo: t.repo, branch: t.branch)
        let new = link.map { computeTreeStat(repo: t.repo, link: $0) }
        // S2-9: read the CURRENT persisted stat AFTER the lineage.read suspension (not a value captured
        // at entry) for both the change gate and the nudge edge, so a synced / fan-out recompute that
        // updated it meanwhile can't drive a duplicate emit or a spurious inSync→stale nudge. (synced
        // also cancels this card's debounce slot before recomputing — the race's other half.)
        let current = await store.get(id)?.treeStat
        guard new != current else { return }                   // no delta → no persist, no emit
        guard let saved = try? await store.update(id, { $0.treeStat = new }) else { return }
        emit(.taskUpserted(saved))
        // Stale nudge: fire ONCE, only on the inSync → stale edge (never per-commit, never stale→stale,
        // never on a first compute that lands on stale). Enqueue + wake — the `concludeCard` idiom.
        if current?.state == .inSync, new?.state == .stale, let parent = link?.parent {
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

    /// Coalescing per-parent trigger for the child fan-out — a one-shot debounce off the report funnel,
    /// like `scheduleTreeStat`. Debounced (not inline on the funnel) so the `git config --get-regexp`
    /// child lookup runs once per activity burst instead of once per report on the hot path.
    func scheduleChildFanout(_ id: UUID) {
        childFanoutDebounce[id]?.cancel()
        childFanoutDebounce[id] = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(750))
            if _Concurrency.Task.isCancelled { return }
            await self?.fanOutChildTreeStats(id)
            await self?.clearChildFanoutDebounce(id)
        }
    }

    private func clearChildFanoutDebounce(_ id: UUID) { childFanoutDebounce[id] = nil }

    /// Schedule a TreeStat recompute for each LIVE child card of `id`'s branch — a card whose branch
    /// records that branch as its parent. Runs off the debounced fan-out (a parent card's activity may
    /// have advanced its tip, staling its children). Routes through `scheduleTreeStat` — NOT a direct
    /// `recomputeTreeStat` — so the child's own self-schedule and this fan-out collapse into the single
    /// `treeStatDebounce[child]` slot; a direct recompute here would race the child's slot across
    /// `recomputeTreeStat`'s `lineage.read` suspension and fire a duplicate stale nudge.
    func fanOutChildTreeStats(_ id: UUID) async {
        guard let t = await store.get(id), t.origin == .worktree else { return }
        let childBranches = await lineage.children(repo: t.repo, of: t.branch)
        guard !childBranches.isEmpty else { return }
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for child in childBranches {
            if let card = active.first(where: { $0.repo == t.repo && $0.branch == child }) {
                scheduleTreeStat(card.id)
            }
        }
    }

    /// Derive a child's `TreeStat` from its lineage link using only local git. Parent tip gone
    /// (branch deleted / bad ref) or an empty recorded base ⇒ `restackNeeded`. Otherwise `behind` =
    /// commits in `base..tip`; if the base is no longer the tip's ancestor (parent rewrote/rebased) ⇒
    /// `restackNeeded`, else `inSync` (behind 0) / `stale` (behind > 0).
    private func computeTreeStat(repo: String, link: ParentLink) -> TreeStat {
        // O1/S1-1: resolve the parent through `resolvableRef` (local → refs/heads/<b>, remote →
        // refs/orch/parents/…). Passing the raw canonical (`pr#N`) here was the S1-1 break: `rev-parse
        // pr#7` fails → false restackNeeded. `parentIsRemote` rides EVERY constructed stat so the badge
        // and the remote-tier UX never lose it.
        let isRemote = RemoteParentRef.parse(link.parent) != nil
        guard !link.base.isEmpty, let tip = treeTip(repo: repo, link.resolvableRef) else {
            return TreeStat(state: .restackNeeded, parentIsRemote: isRemote)
        }
        let behind = treeBehind(repo: repo, base: link.base, tip: tip)
        if !treeBaseIsAncestor(repo: repo, base: link.base, tip: tip) {
            return TreeStat(state: .restackNeeded, behind: behind, parentIsRemote: isRemote)
        }
        return TreeStat(state: behind == 0 ? .inSync : .stale, behind: behind, parentIsRemote: isRemote)
    }

    /// The repo's LOCAL default branch name (`main`/`master`) — the root-ship retarget target (S1-2).
    /// Prefers `origin/HEAD`'s short name when a local branch of that name exists, else falls back to
    /// `main`/`master`. Never returns a remote-tracking ref (`origin/…`), which would be mis-parsed as a
    /// remote parent by `RemoteParentRef.parse`.
    func defaultBranch(repo: String) -> String {
        if let ref = DiffBaseline.defaultBaseRef(worktree: repo),
           RemoteParentRef.parse(ref) == nil, treeTip(repo: repo, "refs/heads/\(ref)") != nil {
            return ref
        }
        for name in ["main", "master"] where treeTip(repo: repo, "refs/heads/\(name)") != nil {
            return name
        }
        return "main"
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
