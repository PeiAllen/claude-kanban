import Foundation

/// Sendable payload for `synced`'s batched resolve→tip→merge-base off-actor hop (PR5 actor-hygiene,
/// Task 5.1.6): all three git leaves are sequential (no intervening `await`) in the original.
private struct SyncProbe: Sendable { let tip: String?; let syncBase: String? }

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
        // O2: re-parenting (any arm) resolves any pending merge-request — stop its re-nudge loop; each
        // arm below sets/nils treeStat directly, so the sticky mergeRequested badge is replaced too.
        stopMergeRequestNudge(t.id)
        let trimmed = parent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = trimmed, !p.isEmpty {
            guard p != t.branch else {
                throw OrchestraError.invalidParams(
                    "a branch cannot be its own parent: \(p) — pick a different branch as the parent")
            }
            let repo = t.repo, branch = t.branch, ctl = Duration.seconds(config.controlTimeout)
            // BT6: a remote parent (origin/<b>, pr#<N>) is fetched into a private ref, recorded with its
            // canonical form + prNumber, and watched per the flag (default off). `mode` doesn't apply —
            // there is no local history to rebase yet; the child restacks only once the remote parent moves.
            let remotes = (try? await offActor { self.gitRemotes(repo: repo) }) ?? []
            if let remote = RemoteParentRef.parse(p, remotes: remotes) {
                let oid = try await remoteParents.fetch(repo: t.repo, remote,
                    context: "could not fetch remote parent \(p)")
                let pr: Int? = { if case .pullRequest(let n) = remote { return n }; return nil }()
                try await lineage.set(repo: t.repo, branch: t.branch,
                    link: ParentLink(parent: remote.canonical, base: oid, prNumber: pr, watch: watch))
                await onChildLineageAdded(repo: t.repo, parentBranch: remote.canonical)
                let (updated, rev) = try await store.update(t.id) {
                    $0.parentBranch = remote.canonical
                    $0.treeStat = carryChildProgress(TreeStat(state: .inSync, parentIsRemote: true), from: $0.treeStat)
                }
                emit(.taskUpserted(updated), rev: rev)
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
                let tip = await offActorValue { await self.treeTip(repo: repo, "refs/heads/\(p)", timeout: ctl) }
                guard tip != nil else {
                    throw OrchestraError.invalidParams(
                        "parent branch not found: \(p) — create or fetch it, or run `git branch` to see valid parents")
                }
                let existing = await lineage.read(repo: t.repo, branch: t.branch)
                let anchor: String
                if let base = existing?.base {
                    anchor = base
                } else {
                    anchor = try await offActor {
                        try await self.mergeBaseOID(repo: repo, "refs/heads/\(branch)", "refs/heads/\(p)", timeout: ctl)
                    }
                }
                try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: anchor))
                await onChildLineageAdded(repo: t.repo, parentBranch: p)
                let (updated, rev) = try await store.update(t.id) {
                    $0.parentBranch = p
                    $0.treeStat = carryChildProgress(TreeStat(state: .restackNeeded), from: $0.treeStat)
                }
                emit(.taskUpserted(updated), rev: rev)
                try? await inbox.enqueue(t.id,
                    "parent moved to \(p) — commit WIP, then `git rebase --onto \(p) \(anchor)`, "
                    + "then `orchestra synced \(updated.shortId)`")
                await wake(t.id)
                emitActivity(.command, updated, source, "moved parent → \(p)")
                return updated
            }
            let base = try await offActor {
                try await self.mergeBaseOID(repo: repo, "refs/heads/\(branch)", "refs/heads/\(p)", timeout: ctl)
            }
            try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: base))
            await onChildLineageAdded(repo: t.repo, parentBranch: p)   // new child under p ⇒ clear p's drained
            // Nil the parent-facing dimension so the scheduled recompute computes fresh against the NEW
            // parent (and doesn't preserve a sticky mergeRequested from the old parent, O2), but CARRY
            // child-progress — re-parenting THIS card doesn't change ITS OWN children.
            let (updated, rev) = try await store.update(t.id) {
                $0.parentBranch = p; $0.treeStat = carryChildProgress(nil, from: $0.treeStat)
            }
            emit(.taskUpserted(updated), rev: rev)
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
            let (updated, rev) = try await store.update(t.id) {
                $0.parentBranch = nil; $0.treeStat = carryChildProgress(nil, from: $0.treeStat)
            }
            emit(.taskUpserted(updated), rev: rev)
            emitActivity(.command, updated, source, "cleared parent link")
            return updated
        }
    }

    /// BT2 spawn-with-base (local parents): record lineage for a card whose branch was just CREATED on
    /// top of `base`. The recorded base OID is `base`'s tip at creation — the redirect anchor for later
    /// restack/sync. Returns the canonical parent ref stored on `Task.parentBranch` (the local base name
    /// in BT2; BT6 will canonicalize remote forms). Throws `.invalidParams` if `base` can't be resolved
    /// (defense-in-depth — `WorktreeRegistry.ensure` already validated it before cutting the worktree).
    func recordSpawnBase(repo: String, branch: String, base: String) async throws -> String {
        // S4 (TOCTOU): prefer the CHILD branch's OWN tip, not a re-resolved `base` tip. `ensure` cut the
        // child at `base`'s tip, so the child's tip IS the fork point — reading it is immune to the parent
        // advancing between the cut and this record (re-resolving `base` could anchor at a commit not in
        // the child's history). Fall back to `refs/heads/<base>` when the child ref can't be resolved
        // (only in stubbed tests; a live worktree card always has its branch). Both pin refs/heads/ (S3-6).
        let to = Duration.seconds(config.controlTimeout)
        let oid: String
        if let own = try? await revParseOID(repo: repo, ref: "refs/heads/\(branch)", timeout: to) {
            oid = own
        } else {
            oid = try await revParseOID(repo: repo, ref: "refs/heads/\(base)", timeout: to)
        }
        try await lineage.set(repo: repo, branch: branch, link: ParentLink(parent: base, base: oid))
        await onChildLineageAdded(repo: repo, parentBranch: base)   // a new child ⇒ the parent is no longer drained
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
        await onChildLineageAdded(repo: repo, parentBranch: ref.canonical)
        return ref.canonical
    }

    /// `git rev-parse --verify <ref>` in `repo`, or `.invalidParams` if it doesn't resolve.
    private nonisolated func revParseOID(repo: String, ref: String, timeout: Duration) async throws -> String {
        let r = try await proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref],
                                   cwd: nil, env: [:], timeout: timeout)
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
            throw OrchestraError.invalidParams(
                "card has no parent link to sync — set one with `orchestra set-parent \(t.shortId) <branch>`")
        }
        let syncTimeout = Duration.seconds(config.controlTimeout)
        let repo = t.repo, branch = t.branch
        // Batched hop: resolve the parent ref, look up its tip, then (S2-1) the merge-base against the
        // child's own branch — sequential, no intervening `await` in the original, so one hop covers all
        // three git leaves.
        let probe: SyncProbe = await offActorValue {
            let rref = self.resolvableRef(link, repo: repo)
            guard let tip = await self.treeTip(repo: repo, rref, timeout: syncTimeout) else {
                return SyncProbe(tip: nil, syncBase: nil)
            }
            // S2-1: record merge-base(child-branch, resolved-parent) — the true sync point — instead of
            // trusting the agent's implicit "I merged the tip down" claim. After an honest merge-down this
            // equals the merged tip; after a racy/bogus `synced` (parent advanced, or no merge happened)
            // it equals the real fork, so it can't silently over-record and mask un-merged parent work.
            // Falls back to the tip only if the child's own branch ref can't be resolved (never live).
            let syncBase = (try? await self.mergeBaseOID(repo: repo, "refs/heads/\(branch)", rref, timeout: syncTimeout)) ?? tip
            return SyncProbe(tip: tip, syncBase: syncBase)
        }
        guard let tip = probe.tip else {
            throw OrchestraError.invalidParams(
                "parent ref not found: \(link.parent) — the parent branch was deleted; re-point with "
                + "`orchestra set-parent \(t.shortId) <newBranch>`, or run `orchestra shipped \(t.shortId)` if it merged")
        }
        let syncBase = probe.syncBase ?? tip
        try await lineage.updateBase(repo: t.repo, branch: t.branch, oid: syncBase)
        // O2: syncing resolves the merge-request — stop the loop and drop the badge, whether still waiting or
        // given up on (else a card whose merge finally landed keeps the red "unanswered" badge).
        stopMergeRequestNudge(t.id)
        _ = try? await store.update(t.id) {
            if $0.treeStat?.state == .mergeRequested || $0.treeStat?.mergeStalled == true {
                $0.treeStat = carryChildProgress(nil, from: $0.treeStat)   // drop the merge-request badge, keep child-progress
            }
        }
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
    public func shipped(ref: String, by: String? = nil, force: Bool = false,
                        source: ActivitySource = .daemon) async throws -> Task {
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
        let repo = child.repo
        let shipTimeout = Duration.seconds(config.controlTimeout)
        let grandparent: String
        if let p = link?.parent {
            grandparent = p
        } else {
            let (hint, remotes) = await offActorValue { (DiffBaseline.defaultBaseRef(worktree: repo), self.gitRemotes(repo: repo)) }
            grandparent = await offActorValue { await self.defaultBranch(repo: repo, timeout: shipTimeout,
                                                                         baseRefHint: hint, remotes: remotes) }
        }

        // S2-2: sanity gate — refuse to retarget grandchildren / clear lineage when the parent tip has NOT
        // advanced past the child's recorded base (i.e. nothing was merged since the last sync). This
        // catches the "called shipped without actually merging" class (parent agent hit conflicts and
        // aborted, or a confused caller), which would otherwise rebase --onto the grandchildren toward data
        // loss. `shipped` verifies nothing else, so this is the integrity floor. A root ship (no parent
        // link) is exempt — its merge went to main via the standard flow. `--force` overrides (a genuine
        // empty/no-op squash).
        if !force, let link, !link.base.isEmpty {
            // Batched hop: resolve the parent ref, look up its tip, then the strict behind-count —
            // sequential, no intervening `await` in the original, so one hop covers all three git leaves.
            let notAdvanced = await offActorValue {
                let rref = self.resolvableRef(link, repo: repo)
                guard let parentTip = await self.treeTip(repo: repo, rref, timeout: shipTimeout) else { return false }
                return await self.treeBehindStrict(repo: repo, base: link.base, tip: parentTip, timeout: shipTimeout) == 0
            }
            if notAdvanced {
                throw OrchestraError.invalidParams(
                    "shipped \(child.branch): parent \(link.parent) has not advanced past the recorded base — "
                    + "nothing appears merged. Merge first, or re-run with force if the squash was genuinely empty.")
            }
        }

        // (a) notify the parent's card, if one owns the parent branch (only when there WAS a parent link
        // — a root ship merged to main via the standard flow, there is no parent card to wake).
        if hadParentLink, let parent = link?.parent {
            let active = await store.all()
            if let parentCard = derivedCard(repo: child.repo, branch: parent, among: active) {
                // S1-3: skip the self-echo when the caller IS the parent — it just performed the merge,
                // so a "child merged into you" wake would only make it read about its own action.
                if parentCard.id != byCardId {
                    try? await inbox.enqueue(parentCard.id,
                        "child \(child.branch) (\(child.shortId)) merged into you — it's in your branch now; "
                        + "archive the child card with `orchestra archive \(child.shortId)`")
                    await wake(parentCard.id)
                }
            } else {
                // S3-1: a bare parent is the documented success path (the child borrowed + merged it),
                // not an anomaly — log it at the neutral `.command` level, not `.warning`.
                emitActivity(.command, child, source,
                    "shipped \(child.branch): parent \(parent) has no active card (bare parent)")
            }
        }

        // (b) retarget the child's own children onto the grandparent (keep each one's recorded base).
        do {
            // S3-7: the grandparent may be remote (reached via `set-parent`, off the skill script). Resolve
            // its rebase target through the seam (a raw `pr#N`/`origin/x` is not a rev), make its private
            // ref resolvable, and preserve the PR/watch keys so the rewritten link keeps tracking the PR.
            let gpRemotes = (try? await offActor { self.gitRemotes(repo: repo) }) ?? []
            let gpRemote = RemoteParentRef.parse(grandparent, remotes: gpRemotes)
            if let gpRemote { _ = try? await remoteParents.fetch(repo: child.repo, gpRemote) }
            let gpResolvable = gpRemote?.privateRef ?? "refs/heads/\(grandparent)"
            let gpPr: Int? = { if case .pullRequest(let n) = gpRemote { return n }; return nil }()
            let grandchildren = await lineage.children(repo: child.repo, of: child.branch)
            let active = await store.all()
            for gcBranch in grandchildren {
                guard let gcLink = await lineage.read(repo: child.repo, branch: gcBranch) else { continue }
                // Repoint parent; KEEP the recorded base — it is the rebase anchor the agent replays from.
                // Gate the card update on the config write SUCCEEDING: if `set` rejects (cycle guard on a
                // pathological tree), leave `Task.parentBranch`/`treeStat` alone so they never disagree with
                // git-config, and surface a warning instead of silently desyncing.
                do {
                    try await lineage.set(repo: child.repo, branch: gcBranch,
                        link: ParentLink(parent: grandparent, base: gcLink.base,
                                         prNumber: gpPr, watch: gpRemote != nil))
                } catch {
                    // `set-parent`'s ref is a card shortId, not a branch name — name the grandchild's card
                    // when one owns the branch, else fall back to a placeholder rather than a command that
                    // would fail with `unknown task`.
                    let gcRef = derivedCard(repo: child.repo, branch: gcBranch, among: active)?.shortId ?? "<shortId>"
                    emitActivity(.warning, child, source,
                        "shipped \(child.branch): could not retarget child \(gcBranch) → \(grandparent) — "
                        + "re-point it manually with `orchestra set-parent \(gcRef) \(grandparent) --mode move`")
                    continue
                }
                // The grandchild's recorded base (old shipped-branch tip) is not an ancestor of the
                // grandparent, so a later `recomputeTreeStat` independently agrees on `restackNeeded` — the
                // report funnel will not silently downgrade this signal before the agent runs `synced`.
                if let card = derivedCard(repo: child.repo, branch: gcBranch, among: active) {
                    if let (saved, rev) = try? await store.update(card.id, {
                        $0.parentBranch = grandparent
                        $0.treeStat = carryChildProgress(
                            TreeStat(state: .restackNeeded, parentIsRemote: gpRemote != nil), from: $0.treeStat)
                    }) {
                        emit(.taskUpserted(saved), rev: rev)
                    }
                    if gpRemote != nil { startRemoteWatch(cardId: card.id) }
                    // S3-7: route the rebase target through the resolvable ref, and skip the command text
                    // entirely when the anchor is empty (an empty `--onto X ` is malformed).
                    if gcLink.base.isEmpty {
                        try? await inbox.enqueue(card.id,
                            "parent \(child.branch) shipped — your recorded base is missing; re-establish it "
                            + "with `orchestra set-parent \(card.shortId) \(grandparent) --mode move`, then "
                            + "`orchestra synced \(card.shortId)`")
                    } else {
                        try? await inbox.enqueue(card.id,
                            "parent \(child.branch) shipped — commit WIP, then `git rebase --onto "
                            + "\(gpResolvable) \(gcLink.base)`, then `orchestra synced \(card.shortId)`")
                    }
                    await wake(card.id)
                }
            }
            // The grandparent just GAINED these grandchildren — if a local card owns it and it had drained,
            // the wave is live again. No-op for a remote grandparent (no local card owns `origin/x`/`pr#N`).
            if !grandchildren.isEmpty { await onChildLineageAdded(repo: child.repo, parentBranch: grandparent) }
        }

        // (d) S1-3: tell the shipped child its branch landed — it is a stopped card that cannot see the
        // `taskUpserted` event, so without this enqueue+wake it sits live-looking forever (a zombie card).
        // Skip when the caller IS the child (a self-ship: root/bare/borrow — the card ships itself, then
        // archives; it doesn't need to read that it landed).
        if hadParentLink, byCardId != child.id, let parent = link?.parent {
            try? await inbox.enqueue(child.id,
                "your branch landed in \(parent) — verify, then `orchestra archive \(child.shortId)`")
            await wake(child.id)
        }

        // (c) remove the shipped child's lineage AND increment the parent's merged-count — the ONE merge-
        // classified removal funnel (slice 4). It re-reads the link under the actor's own lock (subsuming
        // the old stillSame re-read), so a concurrent `set-parent` that re-pointed this branch mid-flight is
        // detected (`.linkChanged`) and left alone; a second `shipped` / post-restart re-detection finds no
        // link (`.absent`) and no-ops the counter — the entry-existence idempotency guard.
        // O2: a pending merge-request is now resolved — stop its re-nudge loop.
        stopMergeRequestNudge(child.id)
        let removal: BranchLineage.MergeRemoval
        if hadParentLink, let parent = link?.parent {
            removal = await lineage.recordMergedChild(repo: child.repo, child: child.branch, expectedParent: parent)
        } else {
            // A root ship merged to main via the standard flow — no parent branch owns a counter, and the
            // child has no link to remove. Nothing to count; fall through to the card cleanup.
            try? await lineage.clear(repo: child.repo, branch: child.branch)
            removal = .absent
        }
        guard removal != .linkChanged else {
            // `.linkChanged` = the child link was NOT removed: either a concurrent `set-parent` re-pointed it
            // (the common case) or, rarely, the clear itself lost to an external git-config lock. Either way we
            // keep the card rather than nil it, so its state still matches git. Accepted rare edge on the
            // lock case: the (a)/(b) nudges + grandchild retarget above already ran, so if the operator then
            // archives the child its lineage link can leak → a phantom child that a later `.setIfEmpty` sees,
            // so the parent's `drained` nudge may not fire. `drained` is nudge-INPUT only (a missed suggestion,
            // never a wrong action), consistent with the owner-accepted crash-window imprecision.
            emitActivity(.command, child, source, "shipped \(child.branch) (link not removed — kept)")
            return (await store.get(child.id)) ?? child
        }
        // `.counted` → refresh the PARENT card's wave broadcast: the new merged count, and `drained` iff this
        // merge left it with zero lineage children (the provenance-bound set — a non-merge removal never does).
        if removal == .counted, let parent = link?.parent,
           let parentCard = derivedCard(repo: child.repo, branch: parent, among: await store.all()) {
            await recomputeChildProgress(parentCard.id, drained: .setIfEmpty)
        }
        // TRAP (fixed): the old `?? child` fallback always bound, so the emit + activity fired
        // unconditionally even when `store.update` threw (card vanished mid-flight) — but `child` has
        // no rev to emit with. Restructure to emit only on success; on failure (intentional behavior
        // change), skip the emit + activity rather than fabricate a rev for a stale snapshot.
        if let (updated, rev) = try? await store.update(child.id, { $0.parentBranch = nil; $0.treeStat = nil }) {
            emit(.taskUpserted(updated), rev: rev)
            emitActivity(.command, updated, source, "shipped \(child.branch)")
            return updated
        } else {
            return child
        }
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
                derivedCard(repo: t.repo, branch: l.parent, among: active)?.id
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
    /// card with no parent link resolves to `nil`.
    func recomputeTreeStat(_ id: UUID) async {
        // S3-5: never recompute/emit/nudge an archived card (a card archived inside the 750 ms debounce
        // window would otherwise get its treeStat rewritten + a durable nudge into a dead inbox).
        guard let t = await store.get(id), t.origin == .worktree, !t.archived else { return }
        let link = await lineage.read(repo: t.repo, branch: t.branch)
        // PR5 actor-hygiene (Task 5.1.4): the compute itself runs off-actor — `computeTreeStat` and every
        // git leaf it calls are `nonisolated` and touch no actor state, so the whole thing can run in one
        // `offActor` hop. `timeout`/`probe` are captured ON-ACTOR (from `config`/`treeProbeHolder`) and
        // passed in as call-scoped arguments — `computeTreeStat` itself reads no actor-stored hook.
        let to = Duration.seconds(config.controlTimeout)
        let probe = treeProbeHolder.get()                       // Sendable-locked; nil in prod
        // The one sync fork (gitRemotes) hoists to a GCD hop; the async twin below runs on the
        // cooperative pool and must not block it (impl-review M1 residual).
        let remotes = await offActorValue { self.gitRemotes(repo: t.repo) }
        let new: TreeStat? = await offActorValue {
            guard let link else { return nil as TreeStat? }
            return await self.computeTreeStat(repo: t.repo, link: link, remotes: remotes, timeout: to, probe: probe)
        }
        // Cheap no-op filter for the steady funnel (avoids a tasks.json write on every unchanged
        // recompute): skip when nothing changed / a sticky mergeRequested badge holds. This read may be
        // stale under a concurrent recompute, but the store.update closure below is the authority.
        let current0 = await store.get(id)?.treeStat
        if current0?.state == .mergeRequested, new?.state != .restackNeeded {
            // The funnel is the only thing that runs when the WORLD AROUND a frozen request changes —
            // `scheduleChildFanout` fires it off the report funnel whenever a card on the parent branch is
            // active — so it is where a request recorded while unowned finds out that an owner has since
            // appeared. Without this the sticky badge would freeze the routing decision too, and the
            // request would be held by nobody: invisible to the human's predicate, never sent to the agent.
            await reconcileMergeRequest(id, link: link, remotes: remotes)
            return
        }
        // Carry BOTH the merge-request fields AND the child-progress dimension so a parent-facing recompute
        // never wipes a card's own wave counters (and a root with only child-progress keeps its stat).
        guard carryChildProgress(carryMergeRequestFields(new, from: current0), from: current0) != current0 else { return }
        // S2-9: compute the change gate AND the nudge edges INSIDE the store.update closure, against the
        // value that closure observes. TaskStore is an actor, so its updates serialize — a concurrent
        // synced / fan-out recompute that already transitioned this card cannot make us fire a duplicate
        // emit or a duplicate inSync→stale nudge (a read-then-update outside the closure left a window).
        var staleEdge = false, restackEdge = false, changed = false
        let res = try? await store.update(id) { task in
            let cur = task.treeStat
            // O2: the `mergeRequested` waiting badge is sticky — only `restackNeeded` supersedes it. A
            // GIVEN-UP request is deliberately NOT sticky (it's a flag, not a state), so a stalled card keeps
            // tracking its parent instead of going blind to it.
            if cur?.state == .mergeRequested, new?.state != .restackNeeded { return }
            let merged = carryChildProgress(carryMergeRequestFields(new, from: cur), from: cur)
            guard merged != cur else { return }               // no delta → no state change, no emit/nudge
            staleEdge = (cur?.state == .inSync && new?.state == .stale)
            restackEdge = (cur?.state != .restackNeeded && new?.state == .restackNeeded)
            task.treeStat = merged
            changed = true
        }
        guard changed, let (saved, rev) = res else { return }
        emit(.taskUpserted(saved), rev: rev)
        // Stale nudge: fire ONCE, only on the inSync → stale edge (never per-commit, never stale→stale).
        if staleEdge, let link {
            try? await inbox.enqueue(id, "parent \(link.parent) moved ahead — run "
                + "`git merge \(resolvableRef(link, repo: t.repo))` in your worktree, then "
                + "`orchestra synced \(saved.shortId)`")
            await wake(id)
        }
        // S4: organic restack edge. A parent agent amending/rebasing its branch (no `shipped`, no
        // `set-parent`) flips children to `restackNeeded` with no other notifier — the one restack path
        // that was silent (shipped/move/remote-redirect all nudge explicitly, and set restackNeeded
        // DIRECTLY so a later recompute sees restackNeeded→restackNeeded, no double nudge). Fire once on
        // the transition INTO restackNeeded from a non-restack state.
        if restackEdge, let link {
            try? await inbox.enqueue(id,
                "parent \(link.parent) changed history (rebased/amended) — restack: commit WIP, then "
                + "`git rebase --onto \(resolvableRef(link, repo: t.repo)) \(link.base)`, then "
                + "`orchestra synced \(saved.shortId)`")
            await wake(id)
        }
    }

    /// Coalescing per-card trigger for `recomputeTreeStat` — a one-shot debounce off the report funnel,
    /// twin of `scheduleDiffStat`.
    func scheduleTreeStat(_ id: UUID) {
        treeStatDebounce[id]?.cancel()
        treeStatDebounce[id] = _Concurrency.Task { [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(750))
            if _Concurrency.Task.isCancelled { return }
            await self?.recomputeTreeStat(id)
            await self?.clearTreeStatDebounce(id)
        }
    }

    private func clearTreeStatDebounce(_ id: UUID) { treeStatDebounce[id] = nil }

    // MARK: - child-progress maintenance (slice 4)

    /// How `recomputeChildProgress` should treat the parent's `drained` flag. Provenance-bound: `drained`
    /// means "the wave finished BY MERGES", so it is set only when a merge-classified removal empties the
    /// lineage (`.setIfEmpty`), cleared when a new child link appears (`.clear`), and otherwise untouched
    /// (`.preserve`) — a non-merge removal of the last child must never set it.
    enum DrainedUpdate { case preserve, clear, setIfEmpty }

    /// Refresh a card's CHILD-progress broadcast — `mergedChildren`/`plannedChildren` (read fresh from
    /// git-config) and, per `op`, `drained`. Independent of the card's OWN parent link, so a ROOT
    /// orchestrator (no link ⇒ `recomputeTreeStat` returns nil) still broadcasts its wave counters; the
    /// parent-facing dimension is preserved untouched (a neutral `.inSync` base only when there was no
    /// stat at all). Persist + emit only on a real change (idempotent). This is the AUTHORITATIVE setter of
    /// the child fields — every other treeStat writer merely carries them via `carryChildProgress`.
    func recomputeChildProgress(_ id: UUID, drained op: DrainedUpdate = .preserve) async {
        guard let t = await store.get(id), t.origin == .worktree, !t.archived else { return }
        let merged = await lineage.mergedCount(repo: t.repo, branch: t.branch)
        let planned = await lineage.plannedCount(repo: t.repo, branch: t.branch) ?? 0
        // STRICT child lookup (nil on a genuine git read failure, [] for a real empty set): used both for the
        // drain decision and to decide whether a parentless root still has a stat to broadcast. Resolved
        // OUTSIDE the sync closure (it is async).
        let kids = await lineage.childrenStrict(repo: t.repo, of: t.branch)
        let hasLiveChildren = (kids?.isEmpty == false)
        // `.setIfEmpty` sets `drained` ONLY on a CONFIRMED-empty read (kids == []) — a read failure (nil) must
        // never drain a wave that may still have siblings. nil ⇒ preserve; a non-nil value is written.
        let drainedSet: Bool?
        switch op {
        case .preserve:  drainedSet = nil
        case .clear:     drainedSet = false
        case .setIfEmpty: drainedSet = (kids?.isEmpty == true) ? true : nil
        }
        var changed = false
        let res = try? await store.update(id) { task in
            let cur = task.treeStat
            let drained = drainedSet ?? (cur?.drained ?? false)
            // A parentless root with live children (but 0 merged / no plan) still broadcasts a neutral stat so
            // the wave bar exists as children spawn; nil only when NEITHER dimension has anything to say.
            let hasChild = merged > 0 || planned > 0 || drained || hasLiveChildren
            if cur == nil && !hasChild { return }               // neither dimension ⇒ leave nil
            var s = cur ?? TreeStat(state: .inSync)              // neutral base for a parentless root
            s.mergedChildren = merged; s.plannedChildren = planned; s.drained = drained
            guard s != cur else { return }
            task.treeStat = s; changed = true
        }
        if changed, let (saved, rev) = res { emit(.taskUpserted(saved), rev: rev) }
    }

    /// A new child lineage entry now points at `parentBranch` — the wave is no longer drained. Clear the
    /// parent card's flag + refresh its counters. No-op when no live card owns the parent branch.
    func onChildLineageAdded(repo: String, parentBranch: String) async {
        guard let parent = derivedCard(repo: repo, branch: parentBranch, among: await store.all()) else { return }
        await recomputeChildProgress(parent.id, drained: .clear)
    }

    /// Coalescing per-parent trigger for the child fan-out — a one-shot debounce off the report funnel,
    /// like `scheduleTreeStat`. Debounced (not inline on the funnel) so the `git config --get-regexp`
    /// child lookup runs once per activity burst instead of once per report on the hot path.
    func scheduleChildFanout(_ id: UUID) {
        childFanoutDebounce[id]?.cancel()
        childFanoutDebounce[id] = _Concurrency.Task { [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(750))
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
        let active = await store.all()
        for child in childBranches {
            if let card = derivedCard(repo: t.repo, branch: child, among: active) {
                scheduleTreeStat(card.id)
            }
        }
    }

    /// Derive a child's `TreeStat` from its lineage link using only local git. Parent tip gone
    /// (branch deleted / bad ref) or an empty recorded base ⇒ `restackNeeded`. Otherwise `behind` =
    /// commits in `base..tip`; if the base is no longer the tip's ancestor (parent rewrote/rebased) ⇒
    /// `restackNeeded`, else `inSync` (behind 0) / `stale` (behind > 0).
    /// `nonisolated` (PR5 actor-hygiene, Task 5.1.4) — touches no actor mutable state, so the whole
    /// compute runs off-actor in one `offActor` hop from `recomputeTreeStat`. `timeout` bounds every git
    /// leaf it calls (no unbounded `Proc.run`); `probe` is a call-scoped test hook (never actor-stored —
    /// a stored hook read from here would be an actor-state read + data race) fired first, so a test can
    /// prove the compute genuinely parked off-actor before the concurrent RPC assertion.
    /// `remotes` is CALL-SCOPED (like `probe`): the caller hoists `gitRemotes` into a sync GCD
    /// hop before entering the async twin, so this body — which runs on the cooperative pool via
    /// Task.detached — never reaches the sync `Proc.run` fork (impl-review M1 residual).
    nonisolated func computeTreeStat(repo: String, link: ParentLink, remotes: [String], timeout: Duration,
                                     probe: (@Sendable () -> Void)? = nil) async -> TreeStat {
        probe?()
        // O1/S1-1: resolve the parent through `resolvableRef` (local → refs/heads/<b>, remote →
        // refs/orch/parents/…). Passing the raw canonical (`pr#N`) here was the S1-1 break: `rev-parse
        // pr#7` fails → false restackNeeded. `parentIsRemote` rides EVERY constructed stat so the badge
        // and the remote-tier UX never lose it.
        let isRemote = RemoteParentRef.parse(link.parent, remotes: remotes) != nil
        guard !link.base.isEmpty,
              let tip = await treeTip(repo: repo, resolvableRef(link, remotes: remotes), timeout: timeout) else {
            return TreeStat(state: .restackNeeded, parentIsRemote: isRemote)
        }
        let behind = await treeBehind(repo: repo, base: link.base, tip: tip, timeout: timeout)
        if await !treeBaseIsAncestor(repo: repo, base: link.base, tip: tip, timeout: timeout) {
            return TreeStat(state: .restackNeeded, behind: behind, parentIsRemote: isRemote)
        }
        return TreeStat(state: behind == 0 ? .inSync : .stale, behind: behind, parentIsRemote: isRemote)
    }

    /// S2-6: the deterministic derived card for a branch — the OLDEST live worktree card on repo+branch.
    /// Co-located siblings are permitted (the cwd-keyed archive refcount depends on it), so every derived
    /// lookup must pick a STABLE one, not an arbitrary `.first`, or shipped-notify / tree.parentCardId /
    /// fan-out target an arbitrary sibling.
    func derivedCard(repo: String, branch: String, among cards: [Task]) -> Task? {
        cards.filter { !$0.archived && $0.origin == .worktree && $0.repo == repo && $0.branch == branch }
            .min { $0.createdAt < $1.createdAt }
    }

    /// The repo's LOCAL default branch name (`main`/`master`) — the root-ship retarget target (S1-2).
    /// Prefers `origin/HEAD`'s short name when a local branch of that name exists, else falls back to
    /// `main`/`master`. Never returns a remote-tracking ref (`origin/…`), which would be mis-parsed as a
    /// remote parent by `RemoteParentRef.parse`.
    /// `baseRefHint`/`remotes` are CALL-SCOPED: both come from sync blocking probes
    /// (DiffBaseline.defaultBaseRef's two Proc.runs + gitRemotes), which the caller hoists into
    /// a sync GCD hop so this async-twin body never blocks a cooperative thread (M1 residual).
    nonisolated func defaultBranch(repo: String, timeout: Duration,
                                   baseRefHint: String?, remotes: [String]) async -> String {
        if let ref = baseRefHint,
           RemoteParentRef.parse(ref, remotes: remotes) == nil,
           await treeTip(repo: repo, "refs/heads/\(ref)", timeout: timeout) != nil {
            return ref
        }
        for name in ["main", "master"] {
            if await treeTip(repo: repo, "refs/heads/\(name)", timeout: timeout) != nil { return name }
        }
        return "main"
    }

    /// `git rev-parse --verify --quiet <ref>` — nil when the ref can't be resolved (parent deleted).
    private nonisolated func treeTip(repo: String, _ ref: String, timeout: Duration) async -> String? {
        guard let r = try? await proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref],
                                          cwd: nil, env: [:], timeout: timeout),
              r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// Commit count in `base..tip` (how far the parent advanced past the recorded base). 0 on error.
    private nonisolated func treeBehind(repo: String, base: String, tip: String, timeout: Duration) async -> Int {
        await treeBehindStrict(repo: repo, base: base, tip: tip, timeout: timeout) ?? 0
    }

    /// Like `treeBehind` but returns `nil` on a `rev-list` failure (e.g. a GC'd/unresolvable base) rather
    /// than conflating it with a genuine 0 — the S2-2 gate needs to distinguish "nothing merged" (real 0)
    /// from "couldn't verify" (nil ⇒ don't refuse a legit ship).
    private nonisolated func treeBehindStrict(repo: String, base: String, tip: String, timeout: Duration) async -> Int? {
        guard let r = try? await proc.run(["git", "-C", repo, "rev-list", "--count", "\(base)..\(tip)"],
                                          cwd: nil, env: [:], timeout: timeout),
              r.ok, let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return n
    }

    /// True iff `base` is an ancestor of `tip` (exit 0). Exit 1 = not an ancestor; any other failure is
    /// treated as not-an-ancestor so a broken base surfaces as `restackNeeded` rather than silently inSync.
    private nonisolated func treeBaseIsAncestor(repo: String, base: String, tip: String, timeout: Duration) async -> Bool {
        guard let r = try? await proc.run(["git", "-C", repo, "merge-base", "--is-ancestor", base, tip],
                                          cwd: nil, env: [:], timeout: timeout) else {
            return false
        }
        return r.ok
    }

    /// `git merge-base <a> <b>` in `repo`, or `.invalidParams` if there is none (e.g. unknown parent).
    private nonisolated func mergeBaseOID(repo: String, _ a: String, _ b: String, timeout: Duration) async throws -> String {
        let r = try await proc.run(["git", "-C", repo, "merge-base", a, b],
                                   cwd: nil, env: [:], timeout: timeout)
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !oid.isEmpty else {
            throw OrchestraError.invalidParams(
                "no merge-base between \(a) and \(b)" + (r.stderr.isEmpty ? "" : ": \(r.stderr)")
                + " — they share no history; pick a parent on the same lineage")
        }
        return oid
    }
}

/// `nudges`/`mergeStalled` belong to the re-nudge loop, not the tree funnel — `computeTreeStat` derives its
/// `TreeStat` from git alone. Carry them across every recompute, or the next parent movement erases the flag
/// and the budget (resurrecting "nudge forever": the loop reads `nudges` back from the store each tick).
/// Free function because it runs inside a Sendable `store.update` closure, which can't capture `self`.
func carryMergeRequestFields(_ new: TreeStat?, from cur: TreeStat?) -> TreeStat? {
    guard var n = new else { return nil }   // no parent link ⇒ no treeStat ⇒ nothing pending to carry
    n.nudges = cur?.nudges ?? 0
    n.mergeStalled = cur?.mergeStalled ?? false
    return n
}

/// Preserve the CHILD-progress dimension (`mergedChildren`/`plannedChildren`/`drained`) across any
/// PARENT-facing treeStat write. The many direct `TreeStat(state:…)` constructions (set-parent,
/// merge-request, remote redirect, the recompute funnel) only know the parent-facing dimension and would
/// otherwise reset the child fields to their defaults — so, exactly like `carryMergeRequestFields` carries
/// `nudges`, this copies the child fields forward from the current stat. `recomputeChildProgress` is the
/// authoritative setter; every other writer just carries. Unlike the merge-request carry, a nil `new`
/// (the card lost its parent link / is a root) does NOT drop the stat when there is child-progress to keep:
/// a root orchestrator has no parent link but must still broadcast its wave counters, so it collapses to a
/// neutral `.inSync` base carrying only the child dimension. Free fn — runs inside `store.update` closures.
func carryChildProgress(_ new: TreeStat?, from cur: TreeStat?) -> TreeStat? {
    let merged = cur?.mergedChildren ?? 0
    let planned = cur?.plannedChildren ?? 0
    let drained = cur?.drained ?? false
    guard var n = new else {
        if merged == 0 && planned == 0 && !drained { return nil }   // neither dimension ⇒ genuinely no stat
        return TreeStat(state: .inSync, mergedChildren: merged, plannedChildren: planned, drained: drained)
    }
    n.mergedChildren = merged; n.plannedChildren = planned; n.drained = drained
    return n
}
