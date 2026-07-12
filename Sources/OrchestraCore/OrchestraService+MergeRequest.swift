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

        // Dedup: the mergeRequested badge is the pending marker. A re-send while already pending does not
        // re-enqueue (the re-nudge timer handles reminders); it only refreshes the badge.
        //
        // The reminder budget is PRESERVED across such a re-send (review: MAJOR). Overwriting the TreeStat
        // wholesale would zero `nudges`, so a child that re-sends while already pending — the dedup path,
        // which doesn't even enqueue a message — would silently re-arm the full eight-reminder budget, and a
        // card re-sending periodically could never reach `mergeStalled`. The cap would be unreachable in
        // exactly the case it exists for. It resets ONLY when this is a genuinely new request: a fresh one,
        // or the escape hatch out of `mergeStalled`.
        //
        // ONE truth gates BOTH the budget and the enqueue: `resuming`, observed inside the closure (review:
        // minor). The snapshot we read before the awaits above is stale — `lineage.read`, `gitRemotes` (an
        // off-actor `git` fork, so a genuinely wide window) and `store.all()` all suspend, and the loop can
        // give up inside it. Gating the enqueue on the stale read while the budget used the fresh one let the
        // two disagree: the escape-hatch re-send would clear the flag and re-arm the badge (looking like it
        // worked) while never re-prodding the parent at t=0 — the parent would first hear about it 5 minutes
        // later, as "reminder 1/8". Self-healing, but it silently degrades the one path the flag exists for.
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
        // Always (re-)arm the re-nudge timer — a re-send after the loop already stopped (e.g. the parent
        // card had briefly vanished) must restart it, not silently leave the badge un-nudged (review B#4).
        startMergeRequestNudge(childId: child.id)
        emitActivity(.command, child, source, "merge-request → \(link.parent)")
        return (await store.get(child.id)) ?? child
    }

    // MARK: - re-nudge timer (O2: re-ask if the parent agent ignores the request)

    /// (Re)start the per-child re-nudge loop: while the child stays `mergeRequested`, re-enqueue the
    /// request to the parent card on a **geometric backoff** (`nudgeDelay`) — and after
    /// `mergeRequestNudgeCap` unanswered reminders **give up**: flip the child to the terminal
    /// `mergeStalled` badge so a human can see the stuck merge-request, and stop. Prodding a parent that
    /// ignored 8 reminders a 9th time does not merge the branch; it just buries the signal.
    ///
    /// The loop is **stateless**: the count lives on the card (`TreeStat.nudges`), read fresh each tick.
    /// That is what makes the cap real — `rebuildMergeRequestNudges()` re-arms every pending card at daemon
    /// start, so an in-memory counter would reset on each restart and the loop would still nudge forever.
    /// Stops when the child leaves the waiting state (shipped/synced/set-parent cleared it), the parent card
    /// is gone, or the cap is reached.
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        // Generation token — the same fence `startRemoteWatch` carries (`remoteWatchGen`), for the same
        // race. `cancel()` does NOT abort a tick already suspended inside `reNudgeMergeRequest`: that tick
        // runs to completion, the loop then exits, and its terminal cleanup hops back onto the actor — where,
        // unfenced, it would null out the slot now holding the NEWER task this re-arm just installed. That
        // orphans the live loop (uncancellable, invisible to `mergeRequestNudgeActive`), so a later re-arm
        // starts a third loop alongside it and they double-nudge the parent with stale counts. This
        // cancel+bump+install runs to completion on the actor with no `await`, so it is atomic.
        let gen = (mergeRequestNudgeGen[childId] ?? 0) + 1
        mergeRequestNudgeGen[childId] = gen
        // `self` is re-acquired PER HOP, never hoisted above the loop. A hoisted `guard let self` holds
        // a STRONG reference for the loop's entire life — including the sleep, which is ~all of it — so
        // `[weak self]` buys nothing and the service can never deallocate. Optional-chaining each hop
        // takes a temporary strong ref only for that call's duration; once the service is gone the next
        // hop yields nil and the loop unwinds. (The pinned service kept forking `git` forever; under
        // `swift test --parallel` the zombies piled up until the cooperative pool was starved.)
        mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let sent = await self?.nudgesSent(childId),
                      let base = await self?.mergeRequestNudgeInterval else { return }
                try? await _Concurrency.Task.sleep(for: OrchestraService.nudgeDelay(base: base, attempt: sent))
                if _Concurrency.Task.isCancelled { return }
                guard let stop = await self?.reNudgeMergeRequest(childId, gen: gen) else { return }
                if stop { break }                     // no longer pending / parent gone / superseded / gave up
            }
            await self?.clearMergeRequestNudge(childId, gen: gen)
        }
    }

    /// Reminders already sent for this child, read from the store (see `startMergeRequestNudge`: the loop
    /// keeps no counter of its own, so the backoff survives a daemon restart instead of starting over).
    private func nudgesSent(_ id: UUID) async -> Int { (await store.get(id))?.treeStat?.nudges ?? 0 }

    /// One re-nudge tick. Returns `true` when the loop should STOP (superseded by a re-arm / child no longer
    /// waiting / parent gone / cap reached).
    func reNudgeMergeRequest(_ childId: UUID, gen: Int) async -> Bool {
        // A cancelled-but-still-running loop must not act. This runs on the actor at entry, before any
        // suspension, so it observes the current generation: if a re-arm superseded us, we are a ghost —
        // stop WITHOUT enqueueing a reminder or bumping the count (else two loops nudge the same parent and
        // race each other's count).
        guard mergeRequestNudgeGen[childId] == gen else { return true }
        guard let child = await store.get(childId), !child.archived, child.origin == .worktree,
              child.treeStat?.state == .mergeRequested,
              let link = await lineage.read(repo: child.repo, branch: child.branch) else { return true }
        let active = await store.all()
        guard let parentCard = derivedCard(repo: child.repo, branch: link.parent, among: active) else {
            // Review B#3: the parent card vanished without shipping — clear the sticky waiting badge so it
            // doesn't linger; the child recomputes its true state (the archive path also nudged it).
            _ = try? await store.update(childId) { if $0.treeStat?.state == .mergeRequested { $0.treeStat = nil } }
            await recomputeTreeStat(childId)
            return true
        }
        // Re-check the fence BEFORE any side effect. The entry check is not enough: we have since suspended
        // across `store.get`, `lineage.read` and `store.all`, and a re-arm inside that window makes us a
        // ghost — which would otherwise still enqueue a reminder and wake the parent (review: MAJOR).
        //
        // A supersession landing inside the enqueue/wake below still costs ONE duplicate reminder — that
        // send cannot be un-made. What it cannot do is corrupt state: the post-wake re-check (below) rejects
        // the ghost's write, so the count and the give-up decision stay the superseding request's alone.
        guard mergeRequestNudgeGen[childId] == gen else { return true }

        let prior = child.treeStat?.nudges ?? 0
        let cap = mergeRequestNudgeCap
        // Budget already exhausted before we sent anything (a cap lowered under us, or `cap <= 0`): give up
        // WITHOUT a reminder. Sending "reminder 1/0" would be absurd.
        guard prior < cap else {
            return await giveUp(childId, sent: prior, prior: prior, link: link, child: child)
        }

        let sent = prior + 1
        try? await inbox.enqueue(parentCard.id,
            "reminder \(sent)/\(cap) — merge-request still pending: squash-merge \(child.branch) "
            + "(\(child.shortId)) into \(link.parent), then `orchestra shipped \(child.shortId)`")
        await wake(parentCard.id)

        // Re-check the fence AFTER the send. `nudges == prior` alone is an ABA-prone discriminator (review:
        // minor): a fresh request also has `nudges == 0`, so a ghost tick sending reminder 1 (`prior == 0`)
        // against a request that was synced + re-requested inside its own enqueue/wake window would pass the
        // CAS and write `nudges = 1` onto the BRAND-NEW request — stealing a reminder from its budget (and,
        // with a cap of 1, flipping it straight to stalled). The generation, not the count, is the authority:
        // it is unique per arming, so it cannot ABA. This runs on the actor with no `await` before the write
        // below, so from here the CAS is a pure backstop rather than the sole defense.
        guard mergeRequestNudgeGen[childId] == gen else { return true }

        // That was the last one — give up (which persists the count, the flag and the true tree state in a
        // single CAS; see `giveUp`).
        if sent >= cap {
            return await giveUp(childId, sent: sent, prior: prior, link: link, child: child)
        }

        _ = await casNudgeCount(childId, prior: prior, sent: sent)
        return false
    }

    /// Persist an ordinary tick's count as a COMPARE-AND-SWAP against the exact count `sent` was based on.
    /// Returns whether the write landed.
    ///
    /// State alone is not enough: the tick suspends across `inbox.enqueue` AND `wake` (real session I/O), and
    /// in that window the card can be shipped/synced/archived and a FRESH merge-request armed. The new request
    /// is ALSO `.mergeRequested`, so a state-only guard would accept the stale write. (The generation fence is
    /// the primary defense — see the re-check above; this is the backstop behind it.)
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

    /// The give-up: the loop never stops SILENTLY. A sibling of the parent-vanished path above.
    ///
    /// **The write is atomic: count + flag + the card's TRUE tree state, in one CAS.** An earlier shape wrote
    /// `.inSync` as a placeholder and recomputed *after* the notification awaits — so a crash in that window
    /// left the card falsely in-sync on disk, and boot rebuilds only the nudge timers (it does not eagerly
    /// recompute tree stats), so the lie could outlive the crash indefinitely (review: MAJOR). We therefore
    /// compute the real state FIRST and never persist a state we know to be wrong.
    ///
    /// The CAS (`nudges == prior`, plus state and `archived`) is what makes this safe to call from the
    /// already-exhausted path too: a stale tick that read an exhausted budget must not stamp a request that
    /// has since been resolved and FRESHLY re-armed — it would be terminal on arrival, carrying a warning
    /// about reminders it never received (review: MAJOR).
    ///
    /// Releasing `.mergeRequested` is deliberate: it is what freezes the recompute funnel and what
    /// `rebuildMergeRequestNudges()` re-arms on daemon start. Leaving it would keep the card blind to its
    /// parent AND resurrect the loop on the next restart.
    ///
    /// The flag is the durable signal. On top of it we tell the two parties who can act: the human, via a
    /// `.warning` in the activity feed; and the CHILD — the card that is blocked — via its own durable inbox,
    /// so its agent learns the request died even if nobody was watching the feed. It can then borrow the
    /// parent and merge itself.
    @discardableResult
    private func giveUp(_ childId: UUID, sent: Int, prior: Int, link: ParentLink, child: Task) async -> Bool {
        // The card's REAL tree state, computed BEFORE the write (same off-actor hop `recomputeTreeStat` uses).
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
        // Superseded: this request is no longer the one on the card. Stop the loop, but announce NOTHING —
        // a give-up notice for a request that was resolved (or replaced) would be a lie.
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

        // The merge-down nudge the funnel could not send (review: minor). While the request was pending, the
        // sticky `.mergeRequested` guard FROZE the recompute funnel — so if the parent moved during those
        // hours (over a 5h15m nudge run, the likely ordering) the child was never told. And because we write
        // the true `.stale` state directly here, no `inSync → stale` edge is crossed, so the funnel will not
        // tell it later either: the nudge would be lost entirely. Fire it here, on the funnel's own seam.
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
        // `mergeStalled` is checked as well as the state: giving up releases `.mergeRequested`, so the state
        // test alone already excludes a stalled card — but this is the "a restart cannot resurrect the spam"
        // guarantee, and it should not depend on two fields agreeing.
        for t in active where t.treeStat?.state == .mergeRequested && t.treeStat?.mergeStalled != true {
            startMergeRequestNudge(childId: t.id)
        }
    }

    // MARK: - backoff schedule

    /// Delay before reminder `attempt` (0-based): doubles from the base, ceilinged at **12× the base**.
    /// The ceiling is base-relative rather than absolute so tests injecting a 20ms base get a 240ms ceiling
    /// and stay fast. The shift operand is clamped BEFORE shifting — an unclamped `1 << attempt` overflows
    /// and traps on a large persisted count (a hand-edited or corrupted card), which is a crash, not a long
    /// sleep.
    static func nudgeDelay(base: Duration, attempt: Int) -> Duration {
        base * min(1 << min(max(attempt, 0), 8), 12)
    }

    // MARK: - test-support
    func setMergeRequestNudgeInterval(_ d: Duration) { mergeRequestNudgeInterval = d }
    func setMergeRequestNudgeCap(_ n: Int) { mergeRequestNudgeCap = n }
    func mergeRequestNudgeGeneration(_ id: UUID) -> Int { mergeRequestNudgeGen[id] ?? 0 }
    func mergeRequestNudgeActive(_ id: UUID) -> Bool { mergeRequestNudge[id] != nil }
}
