import Foundation

extension OrchestraService {

    // MARK: - F2 wake + merge-watch (C2)

    /// Register a watcher's interest in `children` so each child's conclusion routes into the watcher's
    /// durable inbox (F3, coalesces) and wakes it (F2). Idempotent (unions). Writes through to the durable
    /// `watchStore` so the registration survives a daemon restart.
    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        guard !children.isEmpty else { return }
        ensureWatchRegistryLoaded()
        watchRegistry[watcher, default: []].formUnion(children)
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    /// Lazy-load the durable watch registry into memory on first access (mirrors
    /// `WorktreeRegistry.loadBorrows`). `server.start()` accepts RPCs BEFORE boot's `reloadWatchRegistry`
    /// runs (after the slow phase reconciliation), so a boot-window `wait`/`watch` RPC that mutated the
    /// STILL-EMPTY in-memory map and saved would CLOBBER the on-disk registry, losing every prior watch.
    /// Loading here means the boot-window mutation loads-then-unions-then-saves — the disk map is the merge
    /// and the later `reloadWatchRegistry` sees everything. ALWAYS marks loaded so a torn read never
    /// retry-loads-and-clobbers; on a torn file `watchRegistryLoadFailed` makes mutations skip the save.
    func ensureWatchRegistryLoaded() {
        guard !watchRegistryLoaded else { return }
        watchRegistryLoaded = true
        let (map, loadFailed) = watchStore.load()
        if loadFailed { watchRegistryLoadFailed = true; return }   // torn ⇒ keep in-memory, refuse to persist over
        watchRegistry = map
    }

    /// Reload the persisted watch registry at boot (after phase reconciliation) and deliver conclusions
    /// for any watched child that is ALREADY terminal at reload — a child that concluded while the daemon
    /// was down (or one just marked `dead(.rebootUnrevived)` by `reconcilePhasesAtBoot`) still notifies its
    /// watcher. An unreadable file is ignored (keep zero watchers rather than trust a torn write).
    public func reloadWatchRegistry() async {
        ensureWatchRegistryLoaded()   // a boot-window register may already have loaded+merged; don't reload-clobber
        // Snapshot the (watcher,child) pairs before mutating; `concludeCard` removes the child from the
        // registry (write-through) as it delivers, so a terminal child notifies exactly once.
        for (_, children) in watchRegistry {
            for child in children {
                if let t = await store.get(child), let kind = isConcluded(t) {
                    await concludeCard(child, kind, deadReason: Self.concludedReason(t))
                }
            }
        }
    }

    /// Register a durable watch without a CLI wait process. Returns an already-settled child if one exists;
    /// otherwise the watcher will be notified through its inbox and woken when a child later concludes.
    public func watch(watcher: UUID, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        registerWatch(watcher, children)
        if let concluded = await firstConcluded(in: children) {
            unregisterWatch(watcher, concluded.cardId)   // settled inline → drop it so a re-death can't re-notify
            return concluded
        }
        return nil
    }

    /// CLI wait path: suspend until ONE of `refs` concludes; returns that `Conclusion` (or nil if
    /// cancelled). If `watcher` is set, its inbox coalesces every conclusion (F3) and it is woken per
    /// `wakeTransport` (F2). Reads conclusion from REAL card state — never `git merge-base`.
    public func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        if let watcher {
            registerWatch(watcher, children)
            // The wait count must persist even if this is the daemon's first touch of the watcher
            // (post-restart): ensure, then count — an uncounted wait would double-notify on conclude.
            if let w = await store.get(watcher) { ensureRuntime(for: w) }
            runtime[watcher]?.activeWaitProcesses += 1
        }
        // SUBSCRIBE BEFORE READING CARD STATE. `transition` writes the terminal phase to the store BEFORE it
        // calls `concludeCard` → `mergeWatch.conclude`, so with the subscription already armed every
        // conclusion is caught by exactly one of the two below: one that lands from here on resolves the
        // subscription; one that landed earlier is already visible in the store to `firstConcluded`.
        //
        // The old order (read, then subscribe) left a gap between them — both are actor hops, so `wait`
        // suspends across them — and a conclusion arriving in that gap reached ZERO subscribers and was
        // dropped. `wait` then parked forever on a continuation nobody would ever resume, with no timeout to
        // save it: an unrecoverable lost wakeup. (`watch`, below, already had this order right.)
        let token = await mergeWatch.subscribe(children)
        let result: Conclusion?
        // Short-circuit on a child that is ALREADY settled-terminal (handles the re-issue race where a
        // child concluded between two `wait` calls). This IS the real-card-state read.
        if let concluded = await firstConcluded(in: children) {
            await mergeWatch.unsubscribe(token)
            // Unregister the settled child (mirror `concludeCard`'s remove) so a later revival→re-death
            // of the same child cannot re-notify this watcher through a stale registry entry.
            if let watcher { unregisterWatch(watcher, concluded.cardId) }
            result = concluded
        } else {
            result = await mergeWatch.awaitConclusion(token: token)
        }
        if let watcher { releaseActiveWaitProcess(watcher) }
        return result
    }

    private func firstConcluded(in children: Set<UUID>) async -> Conclusion? {
        for id in children {
            if let t = await store.get(id), let kind = isConcluded(t) {
                return Conclusion(cardId: id, ref: t.ref(), kind: kind, deadReason: Self.concludedReason(t))
            }
        }
        return nil
    }

    /// The terminal `DeadReason` a settled card carries on its conclusion — the raw reason for an
    /// `.exited`, nil for `.archived` (a `.done`). Kept in step with `isConcluded`.
    static func concludedReason(_ t: Task) -> DeadReason? {
        if case .dead(let r) = t.phase { return r }
        return nil
    }

    /// Remove one settled child from a watcher's registry (mirror of `concludeCard`'s `remove(id)` +
    /// empty-set cleanup) — used by the `wait`/`watch` short-circuit so a re-death can't re-notify.
    func unregisterWatch(_ watcher: UUID, _ child: UUID) {
        ensureWatchRegistryLoaded()
        guard watchRegistry[watcher]?.contains(child) == true else { return }   // no-op ⇒ no needless persist
        watchRegistry[watcher]?.remove(child)
        if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    private func releaseActiveWaitProcess(_ watcher: UUID) {
        guard let count = runtime[watcher]?.activeWaitProcesses, count > 0 else { return }
        runtime[watcher]?.activeWaitProcesses = count - 1
    }

    /// The single authority declares a card SETTLED terminal (a conclusion). Called from `archive`
    /// (Done) and a clean agent exit — NOT from a revivable crash. Routes the conclusion into every
    /// watching parent's inbox (F3) + wakes it (F2), then resolves any active `awaitConclusion` (the
    /// native-reinvoke wake: `orchestra wait` returns → its process exits → the harness re-invokes).
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind, deadReason: DeadReason? = nil) async {
        guard let t = await store.get(id) else { return }
        // A concluded card can never confirm a `--model` re-seat, so drop its tripwire here — the single
        // terminal chokepoint. Doing it in `markDead` alone would miss the most likely post-re-seat death of
        // all: a re-seat whose launch fails concludes via the steppers' `concludeFailedLaunch`, which goes
        // through the funnel, not through `markDead`.
        runtime[id]?.modelOverrideWatch = nil
        ensureWatchRegistryLoaded()   // a card concluding in the boot window must see the persisted watchers
        let conc = Conclusion(cardId: id, ref: t.ref(), kind: kind, deadReason: deadReason)
        // F3 inbox routing + F2 wake for every registered watcher of this child. If the watcher has a
        // live CLI `orchestra wait`, that process's output is already the conclusion notice, so do not
        // enqueue a duplicate automatic inbox notice. MCP/tool watches have no later process output, so
        // they need the durable inbox notice as their wake context.
        for (watcher, children) in watchRegistry where children.contains(id) {
            if (runtime[watcher]?.activeWaitProcesses ?? 0) == 0 {
                let detail = deadReason.map { " — \($0.rawValue)" } ?? ""
                try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)\(detail)).")
                await wake(watcher)
            }
            // Route through `unregisterWatch` so the removal PERSISTS (write-through). A missed inline
            // remove would leave a concluded child registered on disk → duplicate conclusion on the next
            // boot reload.
            unregisterWatch(watcher, id)
        }
        // Resolve any active CLI `orchestra wait` subscribed to this child (per-child, first-wins).
        await mergeWatch.conclude(conc)
    }

    /// The SINGLE delivery chokepoint (B4). Every starter funnels through here — `send`'s fast path,
    /// the reconciler's delivery arm, `wakeIfPending`'s live edge, `concludeCard`'s watcher nudges —
    /// so `deliveriesInFlight` is the one wake-vs-wake guard and every route decision is made once.
    ///
    /// The ladder, in order, and what each rung is FOR:
    ///  1. **Deliverable + in-flight claim.** `.live(.waiting(.humanTurn))` or a revivable `.dead`;
    ///     the claim is inserted with no suspension after the guard, so concurrent wakes serialize.
    ///  2. **CLI-wait defer** (`.nativeReinvoke` only) — the card's own `orchestra wait` process will
    ///     re-invoke the harness when it exits; relaunching would replace that live wait.
    ///  3. **Outstanding-lease defer** — an unexpired same-epoch lease means a delivery is
    ///     mid-confirm (a held relaunchSeed awaiting its first-signal confirm). NEVER cold-restart a
    ///     session that just took a delivery.
    ///  4. **Cold resume intent** — `.relaunching`; the RelaunchStepper claims the seed and delivers
    ///     it in the opening turn. No route at all ⇒ charge an attempt and leave it to the arm.
    ///
    /// The Claude no-restart channel-push route lives in the D increment, not here — B's earlier
    /// parked-poll skeleton was removed once the empirics (03 §wake) picked a simple server push.
    ///
    /// Post-await re-guards: after every suspension the card is re-read and abandoned if it was
    /// archived, left the deliverable set, or had its epoch bumped by a concurrent relaunch —
    /// claiming at a stale epoch would lease a batch into a provably-dead session.
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), !t.archived, deliverable(t),
              runtime[id]?.deliveryClaim == nil else { return }
        ensureRuntime(for: t)
        let claim = nextRuntimeToken()
        runtime[id]?.deliveryClaim = claim     // SYNCHRONOUS claim — no await since the guard
        await deliver(t)
        // Compare-and-swap release: if the entry was detached and recreated while `deliver` was
        // suspended (archive→reopen), a successor wake may hold its OWN claim — releasing that
        // would admit a concurrent delivery. A mismatch means this wake no longer owns anything.
        if runtime[id]?.deliveryClaim == claim { runtime[id]?.deliveryClaim = nil }
    }

    /// Is this card a legal delivery target right now? `.live(.waiting(.humanTurn))` — never
    /// `.running` (its Stop hook owns delivery; this is also the background-work safety gate) and
    /// never `.waiting(.permission)` (mid-turn; wake mechanisms only latch at turn-end). A
    /// non-archived `.dead` card is deliverable too: the arm revives a resumable/provisional one
    /// through the resume intent (a send to a completed card is an explicit request for more work),
    /// and a non-resumable dead card is charged straight to stuck by the arm.
    func deliverable(_ t: Task) -> Bool {
        if t.archived { return false }
        if case .live(.waiting(.humanTurn)) = t.phase { return true }
        if case .dead = t.phase { return true }
        return false
    }

    /// The ladder body. Split out so `wake` owns the in-flight claim/release symmetrically.
    private func deliver(_ t: Task) async {
        guard let adapter = try? registry.get(t.agentId) else { return }
        let transport = adapter.capabilities.wakeTransport
        let epoch = t.sessionEpoch

        // 2 · the harness will re-invoke it — defer, don't charge (a turn IS coming).
        if transport == .nativeReinvoke, (runtime[t.id]?.activeWaitProcesses ?? 0) > 0 { return }

        // 3 · a delivery is mid-confirm — defer, don't charge.
        if await inbox.hasLiveLease(t.id, epoch: epoch, now: now()) { return }
        guard var card = await reguard(t.id, epoch: epoch) else { return }

        // 4 · cold: the resume intent. `resume` is intent-only — it records `.relaunching` (bumping
        // the epoch, which invalidates prior-epoch leases) and returns; the
        // RelaunchStepper claims the seed and folds it into the opening turn. `isResumable` hops
        // off-actor (a filesystem stat), so re-guard AFTER it — a relaunch that landed during the
        // stat must not get a second, redundant resume on top of the generation it just created.
        let resumable = await isResumable(card)
        guard let reg = await reguard(t.id, epoch: epoch) else { return }
        card = reg
        if resumable || card.awaitingFirstPrompt {
            // The one wake VISIBLE to the human: a cold delivery tears the session down and brings it
            // back. Say so — an unexplained restart in the terminal reads as a crash. The in-place
            // routes (D's channel push, E1's app-server turn injection) emit nothing. Emit ONLY once
            // the resume intent is ACCEPTED — on the `catch` (a rejected intent) nothing restarts, so
            // announcing one would be a lie.
            do {
                _ = try await resumeInCard(card.id, source: .daemon)
                emitActivity(.recovered, card, .daemon, "idle wake — restarting to deliver queued messages")
            } catch { chargeDeliveryAttempt(card.id) }             // intent rejected
        } else {
            chargeDeliveryAttempt(card.id)   // no route; the arm retries, then flips stuck
        }
    }

    /// Post-await epilogue: re-read the card and require it is still a legal, same-generation target.
    /// `nil` ⇒ abandon this wake (archived / left the deliverable set / superseded by a relaunch).
    private func reguard(_ id: UUID, epoch: Int) async -> Task? {
        guard let t = await store.get(id), !t.archived, deliverable(t), t.sessionEpoch == epoch
        else { return nil }
        return t
    }

    /// Charge one failed delivery attempt and back the next one off (capped exponential, mirroring
    /// the step backoff). Attempts reset ONLY on a confirmed delivery (`deliveryConfirmed`) or a new
    /// `send` — never on mere dispatch success, so an acking-but-not-notifying bridge cannot suppress
    /// the stuck flip.
    func chargeDeliveryAttempt(_ id: UUID) {
        let count = (runtime[id]?.deliveryAttempt?.count ?? 0) + 1
        let delay = deliveryBackoffOverrideSeconds
            ?? min(pow(2.0, Double(min(count, 6))), 64)            // 2,4,8,…,64 capped
        runtime[id]?.deliveryAttempt = DeliveryAttempt(count: count,
                                                       nextEligible: now().addingTimeInterval(delay))
    }

    /// A card's conclusion kind from REAL card state, or nil if not settled-terminal. NEVER git.
    /// Every `.dead` reason (incl. `sessionVanished`/`rebootUnrevived`/`resumeFailed`) → `.exited`, so a
    /// suspended `wait` resolves on crash death rather than hanging. `.archived` (and the `archived` Bool
    /// bridge) → `.done`.
    func isConcluded(_ t: Task) -> Conclusion.Kind? {
        if case .archived = t.phase { return .done }
        if t.archived { return .done }                 // archive-verb funnel routing is Stage 4; keep the Bool bridge
        if case .dead = t.phase { return .exited }
        return nil
    }

    /// Test / introspection: count of active conclusion subscriptions.
    public func activeWaitSubscriptionCount() async -> Int { await mergeWatch.subscriptionCount() }
}
