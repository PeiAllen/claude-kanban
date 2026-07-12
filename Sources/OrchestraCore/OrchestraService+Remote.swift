import Foundation

/// The outcome of one ladder evaluation — a typed result so the loop stays thin and tests assert on it.
public enum RemoteMergeOutcome: Equatable, Sendable {
    case none               // tip unchanged / unavailable, no conclusion
    case fetched            // tip moved, private ref refreshed, no merge conclusion
    case redirected(grandparent: String)
    case warnedGone         // branch vanished, gh couldn't confirm — warning surfaced
    case warnedAncestry     // merge-commit ancestry positive but base unknown (no gh) — warning surfaced
}

/// Sendable pair for `remoteMergeStep`'s batched parse+lookup off-actor hop (PR5 actor-hygiene, Task
/// 5.1.6): `RemoteParentRef.parse` (needs `gitRemotes`) and `privateRefOID` are sequential with no
/// intervening `await` in the original, so they ride ONE `offActor` hop.
private struct RemoteRefProbe: Sendable { let ref: RemoteParentRef; let oid: String? }

extension OrchestraService {
    /// Test seam: swap the gh boundary (real `GhProbe` in production, `FakeGh` in tests).
    func setGh(_ client: any GhClient) { self.gh = client }

    /// One full detection-ladder tick for a watched remote-parent card. Steps (stop at first conclusion):
    ///   1. `ls-remote` the parent tip. `.unavailable` ⇒ no conclusion (backoff — never a false "gone").
    ///   2. If the tip MOVED, `fetch` it into the private ref and `scheduleTreeStat` (stale badge tracks it).
    ///   3. LADDER:
    ///      (a) gh MERGED (authoritative, squash-proof) ⇒ redirect onto the PR's `baseRefName`.
    ///      (b) tip `.gone` + gh can't confirm ⇒ warning activity (gh-aware wording; latched, S2-8/S3-1).
    ///      (c) ancestry: the child's tip is contained in a FRESH parent tip (merge-commit landing) ⇒
    ///          WARN only (proof-POSITIVE, but never authoritative about the base — never auto-redirects).
    /// Idempotent: after a redirect the link is no longer a PR, so a re-run takes no merge path.
    @discardableResult
    func remoteMergeStep(cardId: UUID) async -> RemoteMergeOutcome {
        guard let t = await store.get(cardId), t.origin == .worktree, !t.archived,
              let link = await lineage.read(repo: t.repo, branch: t.branch) else { return .none }
        let repo = t.repo, ctl = Duration.seconds(config.controlTimeout)
        // Batched hop: parse the parent ref (needs `gitRemotes`) then look up its current private-ref OID —
        // sequential, no intervening `await` in the original, so one hop covers both.
        let probed: RemoteRefProbe? = (try? await offActor {
            guard let ref = RemoteParentRef.parse(link.parent, remotes: self.gitRemotes(repo: repo)) else { return nil }
            return RemoteRefProbe(ref: ref, oid: self.privateRefOID(repo: repo, ref: ref, timeout: ctl))
        }) ?? nil
        guard let probed else { return .none }
        let ref = probed.ref

        let tip = await remoteParents.lsRemoteTip(repo: t.repo, ref)
        var fetchedTip: String? = probed.oid
        var moved = false
        if case .oid(let observed) = tip, observed != fetchedTip {
            moved = true
            remoteWarnLatch.remove(cardId)   // S3-1: tip changed — a prior gone/closed warning may no longer hold
            fetchedTip = (try? await remoteParents.fetch(repo: t.repo, ref)) ?? fetchedTip
            scheduleTreeStat(cardId)
        }

        // gh state fetched ONCE per tick (PR parents only), reused by tier (a), the closed-PR signal, and
        // the gone-tier wording. Only a PR parent reaches gh — a plain `origin/<b>` parent carries no PR
        // number, so gh is spared on every branch tick (S1-5's traffic point). A PR parent MUST probe every
        // tick: its merge is invisible in `refs/pull/N/head` (which doesn't move on merge, S2-8). The
        // `await` hops the ≤20 s round-trip off the actor (detached), so it suspends — never blocks — the
        // service (list/spawn/send stay responsive).
        var prState: PrState? = nil
        if let pr = link.prNumber, gh.available { prState = await gh.prState(repo: t.repo, number: pr) }

        // (a) authoritative gh MERGED (squash-proof).
        if let st = prState, st.merged {
            await applyRemoteRedirect(cardId: cardId, link: link, grandparent: st.baseRefName, childHead: t.branch)
            return .redirected(grandparent: st.baseRefName)
        }

        // S2-8: a PR closed WITHOUT merging is safe but otherwise silent — GitHub keeps `refs/pull/N/head`
        // so the tip never goes `.gone` and the card sits inSync/watched forever with no hint. Surface it
        // once (latched) so the human picks a new base.
        if let st = prState, st.state == "CLOSED", !st.merged, !remoteWarnLatch.contains(cardId) {
            remoteWarnLatch.insert(cardId)
            emitActivity(.warning, t, .daemon,
                "parent \(link.parent) PR closed without merging — pick a new base with "
                + "`orchestra set-parent \(t.shortId) <newBranch>`")
        }

        // (b) branch gone, unconfirmable by gh. Checked BEFORE ancestry: with the remote tip deleted the
        // only parent OID we have is a STALE private ref, against which an ancestry check is meaningless.
        // S3-1: latch the warning (this condition is persistent — it would re-fire every idle tick).
        // S2-8: consult gh — don't claim "likely merged" when gh just said the PR was CLOSED-not-merged.
        if tip == .gone {
            if !remoteWarnLatch.contains(cardId) {
                remoteWarnLatch.insert(cardId)
                let closedNotMerged = (prState?.state == "CLOSED" && prState?.merged == false)
                emitActivity(.warning, t, .daemon, closedNotMerged
                    ? "parent \(link.parent) branch is gone and its PR was closed without merging — "
                      + "pick a new base with `orchestra set-parent \(t.shortId) <newBranch>`"
                    : "parent \(link.parent) branch is gone — likely merged; confirm and pick a new base with "
                      + "`orchestra set-parent \(t.shortId) <newBranch>`")
            }
            return .warnedGone
        }

        // (c) merge-commit ancestry — proof-POSITIVE only, and WARN-only. Against a FRESH parent tip
        // (`moved`), observe that the parent now CONTAINS the child's OWN committed work (`childTip` is its
        // ancestor, and the child diverged past its recorded base so this isn't a trivial fast-forward).
        // That is a positive signal that a merge happened around this branch, but it is NOT authoritative
        // about which way or onto which base — the correct redirect target is the PR's `baseRefName`, which
        // only `gh` (tier a, already checked above) can supply. So we NEVER auto-redirect here; we surface a
        // warning for the human to confirm with `set-parent`. (This tier rarely fires for a PR parent on
        // real GitHub — `refs/pull/N/head` doesn't advance on merge — so gh/gone carry PR detection; it is
        // the degraded, gh-absent signal for a plain remote-branch parent that fast-forwarded.)
        if moved, let parentTip = fetchedTip {
            let branchName = t.branch, linkBase = link.base
            // Batched hop: `localBranchOID` then (only if it differs from the recorded base — same
            // short-circuit as the original `,`-chained guard) `isAncestor`.
            let ancestryHit = (try? await offActor {
                guard let childTip = self.localBranchOID(repo: repo, branch: branchName, timeout: ctl),
                      childTip != linkBase else { return false }
                return self.isAncestor(repo: repo, ancestor: childTip, of: parentTip, timeout: ctl)
            }) ?? false
            if ancestryHit {
                emitActivity(.warning, t, .daemon,
                    "parent \(link.parent) appears merged (ancestry) — confirm and pick a new base with "
                    + "`orchestra set-parent \(t.shortId) <newBranch>`")
                return .warnedAncestry
            }
        }

        return moved ? .fetched : .none
    }

    /// Apply the remote redirect: retarget THIS card onto the (remote) grandparent branch, keep the
    /// recorded base as the rebase anchor, refresh the new parent's private ref, mark restackNeeded, nudge
    /// + wake, and best-effort repair a published child PR's base. Idempotent (safe to re-enter).
    private func applyRemoteRedirect(cardId: UUID, link: ParentLink, grandparent: String, childHead: String) async {
        // Re-read across the ladder's awaits: the card may have been archived / re-pointed since the tick
        // began. Bail rather than write lineage onto a gone card.
        guard let t = await store.get(cardId), !t.archived, t.origin == .worktree else { return }
        // S1-5 hardening: gh is now a real ≤20 s suspension, so a `set-parent` can land mid-tick — it
        // cancels the watch but cannot stop THIS running tick. Re-read the lineage link and bail if it is
        // no longer the PR we started redirecting (parent/base/pr changed), so we never revert the user's
        // fresh re-parent or re-anchor on a stale base (lost-update guard).
        guard let current = await lineage.read(repo: t.repo, branch: t.branch), current == link else { return }
        let newRef = RemoteParentRef.branch(remote: "origin", name: grandparent)   // origin/<baseRefName> (PR base)
        _ = try? await remoteParents.fetch(repo: t.repo, newRef)         // make refs/orch/parents/<gp> resolvable
        let anchor = link.base
        // S4: don't keep watching once redirected onto the DEFAULT branch — it can never "merge", so the
        // 5-min ls-remote loop would run forever. Watch a non-default base (it may itself land later).
        let repo = t.repo, ctl = Duration.seconds(config.controlTimeout)
        let db = (try? await offActor { self.defaultBranch(repo: repo, timeout: ctl) }) ?? "main"
        let keepWatching = (grandparent != db)
        do {
            try await lineage.set(repo: t.repo, branch: t.branch,
                link: ParentLink(parent: newRef.canonical, base: anchor, prNumber: nil, watch: keepWatching))
        } catch {
            emitActivity(.warning, t, .daemon,
                "remote redirect: could not retarget \(t.branch) → \(grandparent) — re-point it manually with "
                + "`orchestra set-parent \(t.shortId) \(grandparent)`")
            return
        }
        if let (saved, rev) = try? await store.update(cardId, {
            $0.parentBranch = newRef.canonical
            $0.treeStat = TreeStat(state: .restackNeeded, parentIsRemote: true)
        }) { emit(.taskUpserted(saved), rev: rev) }

        // S3-7: the rebase target must be the fetched private ref — the canonical `origin/<gp>` is not a
        // rev, and only resolved before by the opportunistic tracking-ref update accident (S1-1).
        try? await inbox.enqueue(cardId,
            "remote parent merged into \(grandparent) — commit WIP, then "
            + "`git rebase --onto \(newRef.privateRef) \(anchor)`, then `git push --force-with-lease`, "
            + "then `orchestra synced \(t.shortId)`")
        await wake(cardId)

        // Repair the child's own published PR base (GitHub auto-retarget is unreliable). Best-effort.
        if gh.available, let childPr = await gh.prNumber(repo: t.repo, head: childHead) {
            // S2-8: warn on failure — a swallowed editBase leaves the child's published PR pointing at a
            // deleted branch with no signal.
            if !(await gh.editBase(repo: t.repo, number: childPr, base: grandparent)) {
                emitActivity(.warning, t, .daemon,
                    "could not repair child PR #\(childPr) base → \(grandparent); "
                    + "run `gh pr edit \(childPr) --base \(grandparent)`")
            }
        }
        if !keepWatching { stopRemoteWatch(cardId) }   // S4: stop the now-pointless default-branch watch
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
        // Generation token: `startRemoteWatch` runs to completion on the actor with no `await`, so this
        // cancel+bump+install is atomic. A cancelled prior loop's terminal `clearRemoteWatch(gen:)` then
        // hops back onto the actor with its OLD gen and no-ops instead of nulling out THIS newer Task — the
        // restart race that would otherwise orphan the live loop (uncancellable, wrong `remoteWatchActive`).
        let gen = (remoteWatchGen[cardId] ?? 0) + 1
        remoteWatchGen[cardId] = gen
        // `self` is re-acquired PER HOP, never hoisted above the loop — see the note on
        // `startMergeRequestNudge`. A hoisted `guard let self` pinned the service for the loop's whole
        // life, so `[weak self]` bought nothing. The generation token above is unchanged.
        remoteWatch[cardId] = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let stop = await self?.shouldStopRemoteWatch(cardId) else { return }
                if stop { break }
                guard let outcome = await self?.remoteMergeStep(cardId: cardId) else { return }
                guard let delay = await self?.remoteWatchDelay(after: outcome) else { return }
                try? await _Concurrency.Task.sleep(for: delay)
            }
            await self?.clearRemoteWatch(cardId, gen: gen)
        }
    }

    /// The next poll delay: `active` right after the tip moved (poll faster while the parent churns),
    /// `idle` otherwise. This is also the loop's "about to sleep" point — the one moment it holds no
    /// strong reference to the service — so the leak test latches on it (see `remoteWatchSleepProbe`).
    func remoteWatchDelay(after outcome: RemoteMergeOutcome) -> Duration {
        let (active, idle) = remoteWatchIntervals
        #if DEBUG
        remoteWatchSleepProbe?()
        #endif
        return (outcome == .fetched) ? active : idle   // movement ⇒ poll faster; steady ⇒ idle
    }

    private func shouldStopRemoteWatch(_ id: UUID) async -> Bool {
        guard let t = await store.get(id), !t.archived, t.origin == .worktree,
              let link = await lineage.read(repo: t.repo, branch: t.branch) else { return true }
        let remotes = (try? await offActor { self.gitRemotes(repo: t.repo) }) ?? []
        guard RemoteParentRef.parse(link.parent, remotes: remotes) != nil, link.watch else { return true }
        return false
    }

    /// Cancel + drop a card's watch loop (archive / clear / retarget-to-local). Bumping the generation
    /// invalidates any in-flight terminal cleanup from a loop we just cancelled, so it can't null a Task a
    /// later `startRemoteWatch` may install.
    func stopRemoteWatch(_ id: UUID) {
        remoteWatch[id]?.cancel()
        remoteWatch[id] = nil
        remoteWatchGen[id] = (remoteWatchGen[id] ?? 0) + 1
        remoteWarnLatch.remove(id)   // S3-1: leaving the remote tier clears any latched gone/closed warning
    }
    /// Terminal cleanup — only clears the slot if it still holds THIS loop's generation (see the race note
    /// in `startRemoteWatch`).
    private func clearRemoteWatch(_ id: UUID, gen: Int) {
        if remoteWatchGen[id] == gen { remoteWatch[id] = nil }
    }

    /// Daemon-startup reconstruction: for every LIVE worktree card whose lineage records a watched remote
    /// parent, (re)start its watch. No global repo scan — only live cards' config.
    public func rebuildRemoteWatches() async {
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for t in active {
            guard let link = await lineage.read(repo: t.repo, branch: t.branch), link.watch else { continue }
            let remotes = (try? await offActor { self.gitRemotes(repo: t.repo) }) ?? []
            guard RemoteParentRef.parse(link.parent, remotes: remotes) != nil else { continue }
            startRemoteWatch(cardId: t.id)
        }
    }

    // MARK: - small git helpers (local, non-hanging)

    /// `nonisolated` (PR5 actor-hygiene, Task 5.1.6) — touches no actor mutable state, so `remoteMergeStep`
    /// can call it from an `offActor` hop. Now `timeout`-bounded like every other git leaf (was unbounded).
    private nonisolated func privateRefOID(repo: String, ref: RemoteParentRef, timeout: Duration) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref.privateRef],
                                    timeout: timeout), r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }
    private nonisolated func localBranchOID(repo: String, branch: String, timeout: Duration) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
                                    timeout: timeout), r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }
    private nonisolated func isAncestor(repo: String, ancestor: String, of tip: String, timeout: Duration) -> Bool {
        (try? Proc.run(["git", "-C", repo, "merge-base", "--is-ancestor", ancestor, tip], timeout: timeout))?.ok ?? false
    }
}
