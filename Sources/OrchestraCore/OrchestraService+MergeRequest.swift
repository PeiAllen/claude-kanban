import Foundation

extension OrchestraService {

    /// `merge-request` (O2) — first-class request that the child's LIVE parent squash-merge it up the
    /// tree. The daemon composes the canonical prose ONCE (replacing the two skill paraphrases that had
    /// drifted), enqueues it to the derived parent card + wakes it, and records a sticky `mergeRequested`
    /// "waiting" badge on the child. Dedups on re-send (the badge is the pending marker), and is cleared
    /// by `shipped`/`synced`/`set-parent`. The daemon performs NO git surgery — the parent's agent does
    /// the merge in its own worktree (the owning-agent rule).
    ///
    /// A REMOTE parent has no local card to ask — the child publishes a stacked PR instead; a BARE local
    /// parent (no live card) is borrowed. Both are refused here with a guiding message.
    @discardableResult
    public func mergeRequest(ref: String, source: ActivitySource = .daemon) async throws -> Task {
        let child = try await resolveRef(ref)
        guard child.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards can request a merge")
        }
        guard let link = await lineage.read(repo: child.repo, branch: child.branch) else {
            throw OrchestraError.invalidParams(
                "card has no parent link — nothing to merge up into; set one with "
                + "`orchestra set-parent \(child.shortId) <branch>`")
        }
        let remotes = (try? await offActor { self.gitRemotes(repo: child.repo) }) ?? []
        if RemoteParentRef.parse(link.parent, remotes: remotes) != nil {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) is remote — publish a stacked PR instead "
                + "(`git push -u origin \(child.branch)` then `gh pr create --base <parentHeadRef>`)")
        }
        let active = await store.all()
        guard let parentCard = derivedCard(repo: child.repo, branch: link.parent, among: active) else {
            throw OrchestraError.invalidParams(
                "parent \(link.parent) has no live card — borrow it and merge in a throwaway worktree "
                + "(`orchestra borrow \(child.shortId)`), then `orchestra shipped \(child.shortId)`")
        }

        // Dedup: the badge is the pending marker — a re-send while pending refreshes it without re-enqueueing.
        // `resuming` is observed INSIDE the closure and gates BOTH the budget and the enqueue: the snapshot
        // read above is stale (three suspensions, one an off-actor `git` fork), and if the two disagreed a
        // re-send could reset the budget while never re-prodding the parent. Preserving the budget on an
        // already-pending re-send is what stops a periodic re-sender re-arming it forever, so the cap can fire.
        var resuming = false
        if let (saved, rev) = try? await store.update(child.id, {
            resuming = ($0.treeStat?.state == .mergeRequested)
            // A re-send always clears `mergeStalled` — that IS the escape hatch out of the give-up (it
            // re-arms the reminders). It resets the budget too, EXCEPT when merely re-sending an
            // already-pending request, where the running budget is preserved (see above).
            $0.treeStat = TreeStat(state: .mergeRequested,
                                   nudges: resuming ? ($0.treeStat?.nudges ?? 0) : 0,
                                   mergeStalled: false)
        }) {
            emit(.taskUpserted(saved), rev: rev)
        }
        if !resuming {
            try? await inbox.enqueue(parentCard.id,
                "merge-request: squash-merge \(child.branch) (\(child.shortId)) into \(link.parent) in your "
                + "worktree, then `orchestra shipped \(child.shortId)`")
            await wake(parentCard.id)
        }
        // Always (re-)arm: a re-send after the loop stopped must restart it, not leave the badge un-nudged.
        startMergeRequestNudge(childId: child.id)
        emitActivity(.command, child, source, "merge-request → \(link.parent)")
        return (await store.get(child.id)) ?? child
    }

    // MARK: - re-nudge timer (O2: re-ask if the parent agent ignores the request)

    /// (Re)start the per-child re-nudge loop: re-ask the parent on a geometric backoff (`nudgeDelay`), and
    /// after `mergeRequestNudgeCap` unanswered reminders give up (see `giveUp`). Stops when the child leaves
    /// the waiting state, the parent card is gone, or the cap is reached.
    ///
    /// The loop keeps NO counter of its own — `TreeStat.nudges` is read fresh each tick. `rebuildMergeRequestNudges()`
    /// re-arms every pending card at boot, so an in-memory counter would reset on each restart and the cap
    /// would never fire.
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        // Generation fence, as `startRemoteWatch` carries (`remoteWatchGen`). `cancel()` does not abort a
        // tick already suspended inside `reNudgeMergeRequest`, so a superseded loop still runs to completion:
        // without this its terminal cleanup would null the slot holding the NEWER task, orphaning a live,
        // uncancellable loop. cancel+bump+install has no `await`, so it is atomic on the actor.
        let gen = (mergeRequestNudgeGen[childId] ?? 0) + 1
        mergeRequestNudgeGen[childId] = gen
        // `self` is re-acquired PER HOP, never hoisted above the loop: a hoisted `guard let self` would hold
        // a strong ref across the sleep (~all of the loop's life) and the service could never deallocate.
        mergeRequestNudge[childId] = _Concurrency.Task { [weak self, clock] in
            while !_Concurrency.Task.isCancelled {
                guard let sent = await self?.nudgesSent(childId),
                      let base = await self?.mergeRequestNudgeInterval else { return }
                try? await clock.sleep(for: OrchestraService.nudgeDelay(base: base, attempt: sent))
                if _Concurrency.Task.isCancelled { return }
                guard let stop = await self?.reNudgeMergeRequest(childId, gen: gen) else { return }
                if stop { break }                     // no longer pending / parent gone / superseded / gave up
            }
            await self?.clearMergeRequestNudge(childId, gen: gen)
        }
    }

    /// Reminders sent so far — read from the store, so the backoff resumes across a restart.
    private func nudgesSent(_ id: UUID) async -> Int { (await store.get(id))?.treeStat?.nudges ?? 0 }

    /// One re-nudge tick. Returns `true` when the loop should STOP (superseded by a re-arm / child no longer
    /// waiting / parent gone / cap reached).
    func reNudgeMergeRequest(_ childId: UUID, gen: Int) async -> Bool {
        // A superseded (but still-running) loop is a ghost: it must not nudge or count.
        guard mergeRequestNudgeGen[childId] == gen else { return true }
        guard let child = await store.get(childId), !child.archived, child.origin == .worktree,
              child.treeStat?.state == .mergeRequested,
              let link = await lineage.read(repo: child.repo, branch: child.branch) else { return true }
        let active = await store.all()
        guard let parentCard = derivedCard(repo: child.repo, branch: link.parent, among: active) else {
            // Parent card vanished without shipping — clear the sticky badge so it doesn't linger.
            _ = try? await store.update(childId) { if $0.treeStat?.state == .mergeRequested { $0.treeStat = nil } }
            await recomputeTreeStat(childId)
            return true
        }
        // Re-check before any side effect: the entry guard is stale by now (we suspended in `store.get`,
        // `lineage.read`, `store.all`). A supersession inside the enqueue below still costs one duplicate
        // reminder — that send can't be un-made — but the post-wake re-check keeps it out of the state.
        guard mergeRequestNudgeGen[childId] == gen else { return true }

        let prior = child.treeStat?.nudges ?? 0
        let cap = mergeRequestNudgeCap
        // Budget already exhausted (cap lowered under us, or `cap <= 0`): give up without sending "1/0".
        guard prior < cap else {
            return await giveUp(childId, sent: prior, prior: prior, link: link, child: child)
        }

        let sent = prior + 1
        try? await inbox.enqueue(parentCard.id,
            "reminder \(sent)/\(cap) — merge-request still pending: squash-merge \(child.branch) "
            + "(\(child.shortId)) into \(link.parent), then `orchestra shipped \(child.shortId)`")
        await wake(parentCard.id)

        // Re-check AFTER the send: the fence, not the count, is the authority. `nudges == prior` is ABA-prone
        // at `prior == 0` (a freshly re-armed request also has 0), so a ghost tick could otherwise pass the CAS
        // and steal a reminder from a brand-new request. The generation is unique per arming and cannot ABA.
        guard mergeRequestNudgeGen[childId] == gen else { return true }

        if sent >= cap {
            return await giveUp(childId, sent: sent, prior: prior, link: link, child: child)
        }

        _ = await casNudgeCount(childId, prior: prior, sent: sent)
        return false
    }

    /// Persist a tick's count as a compare-and-swap against the count `sent` was based on. State alone is not
    /// enough: a card can be synced and a FRESH request armed across the enqueue/wake suspensions, and that
    /// request is ALSO `.mergeRequested` — a state-only guard would accept the stale write. Backstop behind
    /// the generation fence.
    @discardableResult
    func casNudgeCount(_ childId: UUID, prior: Int, sent: Int) async -> Bool {
        var changed = false
        if let (saved, rev) = try? await store.update(childId, { t in
            guard !t.archived, t.treeStat?.state == .mergeRequested,
                  (t.treeStat?.nudges ?? 0) == prior else { return }   // superseded under us — drop the write
            t.treeStat?.nudges = sent
            changed = true
        }), changed {                                                  // no-op closure ⇒ no rev bump ⇒ no emit
            emit(.taskUpserted(saved), rev: rev)
        }
        return changed
    }

    /// Give up: the loop never stops silently.
    ///
    /// The write is ATOMIC — count + flag + the card's TRUE tree state in one CAS. Persisting a placeholder
    /// state and recomputing afterwards would leave a crash in that window with a lie on disk (boot rebuilds
    /// the nudge timers but never recomputes tree stats, so it would outlive the crash).
    ///
    /// Releasing `.mergeRequested` is deliberate: that state freezes the recompute funnel and is what
    /// `rebuildMergeRequestNudges()` re-arms at boot — leaving it would blind the card to its parent AND
    /// resurrect the loop on the next restart.
    @discardableResult
    private func giveUp(_ childId: UUID, sent: Int, prior: Int, link: ParentLink, child: Task) async -> Bool {
        // The card's real tree state, computed BEFORE the write (the hop `recomputeTreeStat` uses).
        let to = Duration.seconds(config.controlTimeout)
        let probe = treeProbeHolder.get()
        let repo = child.repo
        let fresh: TreeStat? = (try? await offActor {
            self.computeTreeStat(repo: repo, link: link, timeout: to, probe: probe)
        }) ?? nil

        var flagged = false
        if let (saved, rev) = try? await store.update(childId, { t in
            guard !t.archived, t.treeStat?.state == .mergeRequested,
                  (t.treeStat?.nudges ?? 0) == prior else { return }   // superseded under us — drop the write
            t.treeStat = TreeStat(state: fresh?.state ?? .inSync,
                                  behind: fresh?.behind ?? 0,
                                  parentIsRemote: fresh?.parentIsRemote ?? false,
                                  nudges: sent,
                                  mergeStalled: true)
            flagged = true
        }), flagged {
            emit(.taskUpserted(saved), rev: rev)
        }
        // Superseded: announce nothing — a give-up notice for a request that was already resolved is a lie.
        guard flagged else { return true }

        emitActivity(.warning, child, .daemon,
            "merge-request stalled — \(sent) reminder\(sent == 1 ? "" : "s") unanswered; \(link.parent) "
            + "never merged \(child.branch). Merge it yourself, or re-send with "
            + "`orchestra merge-request \(child.shortId)` to re-arm the reminders.")
        try? await inbox.enqueue(childId,
            "merge-request stalled — \(link.parent) ignored \(sent) reminder\(sent == 1 ? "" : "s") and never "
            + "merged \(child.branch); the daemon has stopped re-asking. Either borrow the parent and merge "
            + "yourself (`orchestra borrow \(child.shortId)` → merge → `orchestra shipped \(child.shortId)`), "
            + "or re-send `orchestra merge-request \(child.shortId)` to re-arm the reminders.")

        // The merge-down nudge the funnel could not send: `.mergeRequested` froze it while the request was
        // pending, and writing the true `.stale` state directly crosses no inSync→stale edge, so the funnel
        // will never fire it later either. Without this the child ends up stalled AND behind, never told.
        if fresh?.state == .stale {
            try? await inbox.enqueue(childId, "parent \(link.parent) moved ahead — run "
                + "`git merge \(resolvableRef(link, repo: child.repo))` in your worktree, then "
                + "`orchestra synced \(child.shortId)`")
        }
        await wake(childId)   // one wake covers both messages
        return true
    }

    func stopMergeRequestNudge(_ id: UUID) {
        mergeRequestNudge[id]?.cancel()
        mergeRequestNudge[id] = nil
        // Bump: invalidates any in-flight tick/cleanup from the loop we just cancelled, so it can't nudge
        // after a `shipped`/`synced`/archive, nor null a task a later re-arm installs.
        mergeRequestNudgeGen[id] = (mergeRequestNudgeGen[id] ?? 0) + 1
    }

    /// Terminal cleanup — only clears the slot if it still holds THIS loop's generation (see the race note
    /// in `startMergeRequestNudge`).
    func clearMergeRequestNudge(_ id: UUID, gen: Int) {
        if mergeRequestNudgeGen[id] == gen { mergeRequestNudge[id] = nil }
    }

    // MARK: - startup rebuild (mirrors rebuildRemoteWatches — the in-memory timer dies on restart)

    /// Daemon-startup reconstruction: for every LIVE (non-archived) worktree card left in the
    /// `mergeRequested` waiting state, re-arm its re-nudge timer. The durable state (child `treeStat` +
    /// the parent's inbox request) survives a restart; the in-memory timer does not. We do NOT re-enqueue
    /// the original request here — the timer's own tick does the re-prodding, and every existing stop
    /// condition (shipped / re-parent / archive / state change) keeps working identically.
    public func rebuildMergeRequestNudges() async {
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        // Checked twice over (the give-up already released `.mergeRequested`): "a restart cannot resurrect
        // the spam" should not rest on two fields agreeing.
        for t in active where t.treeStat?.state == .mergeRequested && t.treeStat?.mergeStalled != true {
            startMergeRequestNudge(childId: t.id)
        }
    }

    // MARK: - backoff schedule

    /// Delay before reminder `attempt` (0-based): doubles from the base, ceilinged at 12× it. The ceiling is
    /// base-relative so an injected fast base stays fast in tests. The shift operand is clamped BEFORE
    /// shifting: an unclamped `1 << attempt` traps on a corrupt persisted count.
    static func nudgeDelay(base: Duration, attempt: Int) -> Duration {
        base * min(1 << min(max(attempt, 0), 8), 12)
    }

    // MARK: - test-support
    func setMergeRequestNudgeInterval(_ d: Duration) { mergeRequestNudgeInterval = d }
    func setMergeRequestNudgeCap(_ n: Int) { mergeRequestNudgeCap = n }
    func mergeRequestNudgeGeneration(_ id: UUID) -> Int { mergeRequestNudgeGen[id] ?? 0 }
    func mergeRequestNudgeActive(_ id: UUID) -> Bool { mergeRequestNudge[id] != nil }
}
