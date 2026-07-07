import Foundation

/// The outcome of one ladder evaluation — a typed result so the loop stays thin and tests assert on it.
public enum RemoteMergeOutcome: Equatable, Sendable {
    case none               // tip unchanged / unavailable, no conclusion
    case fetched            // tip moved, private ref refreshed, no merge conclusion
    case redirected(grandparent: String)
    case warnedGone         // branch vanished, gh couldn't confirm — warning surfaced
    case warnedAncestry     // merge-commit ancestry positive but base unknown (no gh) — warning surfaced
}

extension OrchestraService {
    /// Test seam: swap the gh boundary (real `GhProbe` in production, `FakeGh` in tests).
    func setGh(_ client: any GhClient) { self.gh = client }

    /// One full detection-ladder tick for a watched remote-parent card. Steps (stop at first conclusion):
    ///   1. `ls-remote` the parent tip. `.unavailable` ⇒ no conclusion (backoff — never a false "gone").
    ///   2. If the tip MOVED, `fetch` it into the private ref and `scheduleTreeStat` (stale badge tracks it).
    ///   3. LADDER:
    ///      (a) gh MERGED (authoritative, squash-proof) ⇒ redirect onto the PR's `baseRefName`.
    ///      (c) ancestry: the child's tip is contained in the fetched parent tip (merge-commit landing) ⇒
    ///          redirect using gh's baseRefName if available, else warn (proof-POSITIVE only).
    ///      (b) tip `.gone` + gh can't confirm ⇒ warning activity ("parent branch gone — likely merged").
    /// Idempotent: after a redirect the link is no longer a PR, so a re-run takes no merge path.
    @discardableResult
    func remoteMergeStep(cardId: UUID) async -> RemoteMergeOutcome {
        guard let t = await store.get(cardId), t.origin == .worktree, !t.archived,
              let link = await lineage.read(repo: t.repo, branch: t.branch),
              let ref = RemoteParentRef.parse(link.parent) else { return .none }

        let tip = await remoteParents.lsRemoteTip(repo: t.repo, ref)
        var fetchedTip: String? = privateRefOID(repo: t.repo, ref: ref)
        var moved = false
        if case .oid(let observed) = tip, observed != fetchedTip {
            moved = true
            fetchedTip = (try? await remoteParents.fetch(repo: t.repo, ref)) ?? fetchedTip
            scheduleTreeStat(cardId)
        }

        // (a) authoritative gh MERGED (squash-proof).
        if let pr = link.prNumber, gh.available, let st = gh.prState(repo: t.repo, number: pr), st.merged {
            await applyRemoteRedirect(cardId: cardId, link: link, grandparent: st.baseRefName, childHead: t.branch)
            return .redirected(grandparent: st.baseRefName)
        }

        // (b) branch gone, unconfirmable by gh. Checked BEFORE ancestry: with the remote tip deleted the
        // only parent OID we have is a STALE private ref, against which an ancestry check is meaningless.
        if tip == .gone {
            emitActivity(.warning, t, .daemon,
                "parent \(link.parent) branch is gone — likely merged; confirm and `set-parent` a new base")
            return .warnedGone
        }

        // (c) merge-commit ancestry — proof-POSITIVE only, and only against a FRESH parent tip. It fires
        // solely when the parent just advanced (`moved`) to CONTAIN the child's OWN commits: the child must
        // have diverged past its recorded base (else `childTip == base` sits trivially under any forward
        // parent — a fast-forward, not a merge). That guard is what keeps a still-open parent from reading
        // as merged.
        if moved, let parentTip = fetchedTip, let childTip = localBranchOID(repo: t.repo, branch: t.branch),
           childTip != link.base, isAncestor(repo: t.repo, ancestor: childTip, of: parentTip) {
            if let pr = link.prNumber, gh.available, let st = gh.prState(repo: t.repo, number: pr) {
                await applyRemoteRedirect(cardId: cardId, link: link, grandparent: st.baseRefName, childHead: t.branch)
                return .redirected(grandparent: st.baseRefName)
            }
            emitActivity(.warning, t, .daemon,
                "parent \(link.parent) appears merged (ancestry) — confirm and `set-parent` a new base")
            return .warnedAncestry
        }

        return moved ? .fetched : .none
    }

    /// Apply the remote redirect: retarget THIS card onto the (remote) grandparent branch, keep the
    /// recorded base as the rebase anchor, refresh the new parent's private ref, mark restackNeeded, nudge
    /// + wake, and best-effort repair a published child PR's base. Idempotent (safe to re-enter).
    private func applyRemoteRedirect(cardId: UUID, link: ParentLink, grandparent: String, childHead: String) async {
        guard let t = await store.get(cardId) else { return }
        let newRef = RemoteParentRef.branch(grandparent)                 // origin/<baseRefName>
        _ = try? await remoteParents.fetch(repo: t.repo, newRef)         // make refs/orch/parents/<gp> resolvable
        let anchor = link.base
        do {
            try await lineage.set(repo: t.repo, branch: t.branch,
                link: ParentLink(parent: newRef.canonical, base: anchor, prNumber: nil, watch: true))
        } catch {
            emitActivity(.warning, t, .daemon, "remote redirect: could not retarget \(t.branch) → \(grandparent)")
            return
        }
        if let saved = try? await store.update(cardId, {
            $0.parentBranch = newRef.canonical
            $0.treeStat = TreeStat(state: .restackNeeded, parentIsRemote: true)
        }) { emit(.taskUpserted(saved)) }

        try? await inbox.enqueue(cardId,
            "remote parent merged into \(grandparent) — commit WIP, then "
            + "`git rebase --onto \(newRef.canonical) \(anchor)`, then `git push --force-with-lease`, "
            + "then `orchestra synced \(t.shortId)`")
        await wake(cardId)

        // Repair the child's own published PR base (GitHub auto-retarget is unreliable). Best-effort.
        if gh.available, let childPr = gh.prNumber(repo: t.repo, head: childHead) {
            _ = gh.editBase(repo: t.repo, number: childPr, base: grandparent)
        }
        emitActivity(.command, t, .daemon, "remote parent PR merged — redirected onto \(grandparent)")
    }

    // MARK: - watch loop lifecycle

    func setRemoteWatchIntervals(active: Duration, idle: Duration) { remoteWatchIntervals = (active, idle) }
    func remoteWatchActive(_ id: UUID) -> Bool { remoteWatch[id] != nil }

    /// Start (or restart) the per-card watch loop. Each tick runs `remoteMergeStep`; the backoff is the
    /// `active` interval right after the tip moved (poll faster while the parent is churning) and `idle`
    /// otherwise. Cancellation-safe: a re-start cancels the prior Task first. The loop exits once the card
    /// leaves the remote tier (archived/cleared/local parent) — a redirect onto `origin/<base>` keeps it
    /// running (harmless; a base branch never "merges") so the child keeps a fresh stale badge.
    func startRemoteWatch(cardId: UUID) {
        remoteWatch[cardId]?.cancel()
        remoteWatch[cardId] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            while !_Concurrency.Task.isCancelled {
                if await self.shouldStopRemoteWatch(cardId) { break }
                let outcome = await self.remoteMergeStep(cardId: cardId)
                let (active, idle) = await self.remoteWatchIntervals
                let delay = (outcome == .fetched) ? active : idle    // movement ⇒ poll faster; steady ⇒ idle
                try? await _Concurrency.Task.sleep(for: delay)
            }
            await self.clearRemoteWatch(cardId)
        }
    }

    private func shouldStopRemoteWatch(_ id: UUID) async -> Bool {
        guard let t = await store.get(id), !t.archived, t.origin == .worktree,
              let link = await lineage.read(repo: t.repo, branch: t.branch),
              RemoteParentRef.parse(link.parent) != nil, link.watch else { return true }
        return false
    }

    /// Cancel + drop a card's watch loop (archive / clear / retarget-to-local).
    func stopRemoteWatch(_ id: UUID) { remoteWatch[id]?.cancel(); remoteWatch[id] = nil }
    private func clearRemoteWatch(_ id: UUID) { remoteWatch[id] = nil }

    /// Daemon-startup reconstruction: for every LIVE worktree card whose lineage records a watched remote
    /// parent, (re)start its watch. No global repo scan — only live cards' config.
    public func rebuildRemoteWatches() async {
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for t in active {
            guard let link = await lineage.read(repo: t.repo, branch: t.branch),
                  link.watch, RemoteParentRef.parse(link.parent) != nil else { continue }
            startRemoteWatch(cardId: t.id)
        }
    }

    // MARK: - small git helpers (local, non-hanging)

    private func privateRefOID(repo: String, ref: RemoteParentRef) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref.privateRef]),
              r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }
    private func localBranchOID(repo: String, branch: String) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]),
              r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }
    private func isAncestor(repo: String, ancestor: String, of tip: String) -> Bool {
        (try? Proc.run(["git", "-C", repo, "merge-base", "--is-ancestor", ancestor, tip]))?.ok ?? false
    }
}
