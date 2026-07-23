import Foundation

extension OrchestraService {

    /// `merge-request` (O2) — first-class request that the child's LIVE parent squash-merge it up the
    /// tree. The daemon composes the canonical prose ONCE (replacing the two skill paraphrases that had
    /// drifted), enqueues it to the derived parent card + wakes it, and records a sticky `mergeRequested`
    /// "waiting" badge on the child. Dedups on re-send (the badge is the pending marker), and is cleared
    /// by `shipped`/`synced`/`set-parent`. The daemon performs NO git surgery — the parent's agent does
    /// the merge in its own worktree (the owning-agent rule).
    ///
    /// The verb NEVER refuses on the shape of the target — it is the single declaration an agent makes when
    /// its work is ready, and routing is the daemon's business, not the agent's. Two routes:
    ///
    /// - **OWNED** parent (a live card holds the parent branch): the request is enqueued to that card and
    ///   re-nudged until it merges. Approval is delegated by construction inside a launched tree.
    /// - **UNOWNED** target — a remote parent (no local card to ask), a bare local branch, or no parent
    ///   link at all (an ordinary root, whose implicit target is the repo's default branch): the request is
    ///   RECORDED and nothing else. There is no agent to nudge, so no loop is armed and `mergeStalled` can
    ///   never fire; the human is the consumer, reads the badge, and grants approval however they choose.
    ///   How that approval is EXECUTED is deliberately outside Orchestra — the daemon states the fact and
    ///   stops.
    @discardableResult
    public func mergeRequest(ref: String, source: ActivitySource = .daemon) async throws -> Task {
        let child = try await resolveRef(ref)
        guard child.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards can request a merge")
        }
        let link = await lineage.read(repo: child.repo, branch: child.branch)
        let repo = child.repo, ctl = Duration.seconds(config.controlTimeout)
        // Sync probes hoist to a GCD hop, per the M1 residual convention (see `recomputeTreeStat`).
        // `defaultBaseRef` costs two more forks and is only the default-branch hint, so it rides ONLY on the
        // link-less arm that actually needs it.
        let needsDefault = (link == nil)
        let (hint, remotes) = await offActorValue {
            (needsDefault ? DiffBaseline.defaultBaseRef(worktree: repo) : nil, self.gitRemotes(repo: repo))
        }
        // A link-less root declares against the repo's default branch — the same target `shipped` retargets
        // its children onto. No lineage is written: the badge carries the declaration, and a verb that
        // silently mutated git config would be the bigger surprise.
        let target: String
        if let parent = link?.parent {
            target = parent
        } else {
            target = await offActorValue {
                await self.defaultBranch(repo: repo, timeout: ctl, baseRefHint: hint, remotes: remotes)
            }
        }
        let active = await store.all()
        let parentCard = mergeParentOwner(repo: child.repo, link: link, remotes: remotes, among: active)

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
        if let parentCard {
            // Arm BEFORE the enqueue, not after. Arming is synchronous on the actor, so it publishes
            // "this request has an owner and a loop" with no suspension in between — which is what a
            // concurrent funnel `reconcileMergeRequest` tests to decide whether the request still needs
            // handing over. Arming after the enqueue left a window across two awaits in which that
            // reconcile saw an un-armed `.mergeRequested` card and enqueued a second copy of the same
            // request. (Always re-arm: a re-send after the loop stopped must restart it.)
            startMergeRequestNudge(childId: child.id)
            if !resuming {
                try? await inbox.enqueue(parentCard.id, Self.handoverText(child: child, parent: target),
                                         dedupKey: Self.handoverDedupKey(child.id))
                await wake(parentCard.id)
            }
            emitActivity(.command, child, source, "merge-request → \(target)")
        } else {
            // Nothing to nudge, so nothing to arm — and a stray loop from a parent that has since gone
            // away must not outlive it (the reconcile below is the same rule, applied continuously).
            stopMergeRequestNudge(child.id)
            emitActivity(.command, child, source, "merge-request → \(target) (recorded — awaiting a human)")
        }
        return (await store.get(child.id)) ?? child
    }

    /// The ONE wording of the request, so the verb and the funnel handover can't drift — and the ONE dedup
    /// key, which is what makes the handover idempotent across every route that can send it (the verb, a
    /// funnel reconcile, the boot rebuild). `Inbox.enqueue` drops a same-key message while one is still
    /// PENDING for that card, so a re-route can never stack a second copy on an owner that hasn't read the
    /// first; once the owner has drained it, a later route legitimately re-asks.
    static func handoverText(child: Task, parent: String) -> String {
        "merge-request: squash-merge \(child.branch) (\(child.shortId)) into \(parent) in your "
        + "worktree, then `orchestra shipped \(child.shortId)`"
    }
    static func handoverDedupKey(_ childId: UUID) -> String {
        "merge-request:\(childId.uuidString.lowercased())"
    }

    /// The merge-target owner, or nil when the target is UNOWNED. Three ways to be unowned, and the verb,
    /// the boot rebuild, the re-nudge tick and the treeStat funnel must all agree on them: no parent link
    /// (an ordinary root — its implicit target is the default branch), a remote parent (there is no local
    /// card to ask), or a local branch no live card holds. `derivedCard` already excludes archived cards,
    /// which is what makes "the owner archived" resolve to unowned rather than to a dead nudge target.
    func mergeParentOwner(repo: String, link: ParentLink?, remotes: [String], among cards: [Task]) -> Task? {
        guard let link, RemoteParentRef.parse(link.parent, remotes: remotes) == nil else { return nil }
        return derivedCard(repo: repo, branch: link.parent, among: cards)
    }

    /// Re-route a pending merge-request against the CURRENT ownership of its target — the one place that
    /// decides whether a request is an agent's problem or a human's, so the answer can never differ between
    /// the verb, the boot rebuild, a re-nudge tick, and the treeStat funnel.
    ///
    /// Ownership is derived, never stored, precisely because it CHANGES under a pending request: the parent
    /// card can be archived (owned → unowned) or a card can appear on the parent branch later (unowned →
    /// owned). The second direction is why this hangs off `recomputeTreeStat`: without it a request recorded
    /// while unowned goes silent the moment an owner appears — the human's badge predicate stops matching
    /// and the new owner was never told, so the request exists but nobody holds it.
    ///
    /// Never enqueues for an already-armed request: the boot rebuild re-arms every pending card WITHOUT
    /// re-sending (the original request is durable in the parent's inbox), so an enqueue here would
    /// duplicate it on the first funnel tick after every daemon restart.
    /// `link`/`remotes` are CALL-SCOPED, matching `computeTreeStat`/`defaultBranch`: the only caller is
    /// `recomputeTreeStat`, which already holds both, and re-deriving them here cost a `lineage.read`
    /// (four git-config forks) plus a `gitRemotes` fork on every debounced tick of every card wearing a
    /// pending badge.
    func reconcileMergeRequest(_ childId: UUID, link: ParentLink?, remotes: [String]) async {
        guard let child = await store.get(childId), !child.archived, child.origin == .worktree,
              child.treeStat?.state == .mergeRequested else { return }
        let owner = mergeParentOwner(repo: child.repo, link: link, remotes: remotes, among: await store.all())
        guard let owner, let link else {
            stopMergeRequestNudge(childId)   // unowned: the badge stays, the loop does not
            return
        }
        guard !mergeRequestNudgeActive(childId) else { return }   // already an agent's problem
        // Arm FIRST — see the note in `mergeRequest`. The guard above and this arm are both synchronous on
        // the actor, so two concurrent recomputes of the same card cannot both pass the guard and both
        // enqueue; arming after the awaits below left exactly that window.
        startMergeRequestNudge(childId: childId)
        try? await inbox.enqueue(owner.id, Self.handoverText(child: child, parent: link.parent),
                                 dedupKey: Self.handoverDedupKey(childId))
        await wake(owner.id)
        emitActivity(.command, child, .daemon,
                     "merge-request → \(link.parent) (an owner appeared — request handed over)")
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
        let repo = child.repo
        let remotes = await offActorValue { self.gitRemotes(repo: repo) }
        guard let parentCard = mergeParentOwner(repo: child.repo, link: link, remotes: remotes,
                                                among: await store.all()) else {
            // The owner went away (archived / closed) without shipping. The REQUEST does not go with it:
            // it is now exactly an unowned request, which is the human's to resolve, so the sticky badge
            // STAYS and only the loop stops. (Clearing the badge here — the old behavior — silently
            // retracted a declaration the child never withdrew, and left nobody holding the work.)
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
        let remotes = await offActorValue { self.gitRemotes(repo: repo) }   // sync fork → GCD hop (M1 residual)
        let fresh: TreeStat? = await offActorValue {
            await self.computeTreeStat(repo: repo, link: link, remotes: remotes, timeout: to, probe: probe)
        }

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
        // Deliberately offers no second ship path. `giveUp` is only reachable past the owner check above, so
        // a live card DOES own the parent here — which is precisely when `borrow` refuses ("parent … has a
        // live card — merge-request instead", +Borrow). The old text sent the child to run a command that
        // could not succeed, and re-taught at runtime the four-way fork the guidance deleted.
        try? await inbox.enqueue(childId,
            "merge-request stalled — \(link.parent) ignored \(sent) reminder\(sent == 1 ? "" : "s") and never "
            + "merged \(child.branch); the daemon has stopped re-asking. Re-send "
            + "`orchestra merge-request \(child.shortId)` to re-arm the reminders, or stop and report it — "
            + "a human decides how this lands.")

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
        let pending = active.filter { $0.treeStat?.state == .mergeRequested && $0.treeStat?.mergeStalled != true }
        guard !pending.isEmpty else { return }
        // `gitRemotes` is a SYNC fork, and this runs on the daemon's boot path — hoist ONE hop per distinct
        // repo rather than blocking the actor once per pending card.
        var remotesByRepo: [String: [String]] = [:]
        for repo in Set(pending.map(\.repo)) {
            remotesByRepo[repo] = await offActorValue { self.gitRemotes(repo: repo) }
        }
        for t in pending {
            // Route through the SAME reconcile every other path uses, rather than blind-arming. Blind
            // arming assumed the parent's original request is already in its inbox — true for a request
            // that was owned when it was made, and false for one RECORDED while unowned whose owner
            // appeared just before the daemon restarted: boot would arm a loop for a parent that had never
            // been told, so its first contact would be a "reminder N/M" for a request it never received.
            // The reconcile hands over when there is an owner and stops the loop when there isn't (an owner
            // archived while the request was pending comes back unowned here, self-correcting), and the
            // handover's dedup key keeps a still-pending original from being duplicated.
            let link = await lineage.read(repo: t.repo, branch: t.branch)
            await reconcileMergeRequest(t.id, link: link, remotes: remotesByRepo[t.repo] ?? [])
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
