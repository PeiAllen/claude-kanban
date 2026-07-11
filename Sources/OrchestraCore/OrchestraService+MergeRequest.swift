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
        let alreadyPending = (child.treeStat?.state == .mergeRequested)
        if let (saved, rev) = try? await store.update(child.id, {
            $0.treeStat = TreeStat(state: .mergeRequested)
        }) {
            emit(.taskUpserted(saved), rev: rev)
        }
        if !alreadyPending {
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
    /// request to the parent card every `mergeRequestNudgeInterval`. Stops as soon as the child leaves
    /// the waiting state (shipped/synced/set-parent cleared it) or the parent card is gone.
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        // `self` is re-acquired PER HOP, never hoisted above the loop. A hoisted `guard let self` holds
        // a STRONG reference for the loop's entire life — including the sleep, which is ~all of it — so
        // `[weak self]` buys nothing and the service can never deallocate. Optional-chaining each hop
        // takes a temporary strong ref only for that call's duration; once the service is gone the next
        // hop yields nil and the loop unwinds. (The pinned service kept forking `git` forever; under
        // `swift test --parallel` the zombies piled up until the cooperative pool was starved.)
        mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let interval = await self?.mergeRequestNudgeInterval else { return }
                try? await _Concurrency.Task.sleep(for: interval)
                if _Concurrency.Task.isCancelled { return }
                guard let stop = await self?.reNudgeMergeRequest(childId) else { return }
                if stop { break }                                      // no longer pending, stop
            }
            await self?.clearMergeRequestNudge(childId)
        }
    }

    /// One re-nudge tick. Returns `true` when the loop should STOP (child no longer waiting / parent gone).
    private func reNudgeMergeRequest(_ childId: UUID) async -> Bool {
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
        try? await inbox.enqueue(parentCard.id,
            "reminder — merge-request still pending: squash-merge \(child.branch) (\(child.shortId)) into "
            + "\(link.parent), then `orchestra shipped \(child.shortId)`")
        await wake(parentCard.id)
        return false
    }

    func stopMergeRequestNudge(_ id: UUID) {
        mergeRequestNudge[id]?.cancel()
        mergeRequestNudge[id] = nil
    }
    private func clearMergeRequestNudge(_ id: UUID) { mergeRequestNudge[id] = nil }

    // MARK: - startup rebuild (mirrors rebuildRemoteWatches — the in-memory timer dies on restart)

    /// Daemon-startup reconstruction: for every LIVE (non-archived) worktree card left in the
    /// `mergeRequested` waiting state, re-arm its re-nudge timer. The durable state (child `treeStat` +
    /// the parent's inbox request) survives a restart; the in-memory timer does not. We do NOT re-enqueue
    /// the original request here — the timer's own tick does the re-prodding, and every existing stop
    /// condition (shipped / re-parent / archive / state change) keeps working identically.
    public func rebuildMergeRequestNudges() async {
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for t in active where t.treeStat?.state == .mergeRequested {
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
    func mergeRequestNudgeActive(_ id: UUID) -> Bool { mergeRequestNudge[id] != nil }
}
