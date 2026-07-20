import Foundation

/// The delivery arm (B4) — the reconciler branch that makes send delivery a CONVERGENCE.
///
/// `send` stays the fast path (enqueue + opportunistic wake), but a fast path alone loses every
/// delivery whose receipt never came back: a lost `decision:block` reply, a dead bridge, a crashed
/// relaunch, or B3's two documented residuals (a provisional card with no watermark to capture, and a
/// rollout line consumed between `ensure` and `setTailWatermark`). Each leaves a durable message under
/// an expiring lease with nothing to re-drive it. This arm is that something: every tick, any
/// deliverable card with claimable messages, no dispatch in flight, past its backoff and not already
/// stuck gets `wake`d again.
///
/// It deliberately does the LEAST it can: decide eligibility, call the one chokepoint. Route
/// selection, the in-flight claim, and every post-await re-guard belong to `wake`.
extension OrchestraService {

    /// One card's delivery pass, run from `reconcile()`'s per-card loop. Ordering matters: the expiry
    /// charge runs BEFORE the dispatch decision so a token that died this tick is accounted before we
    /// consider re-driving, and the stuck flip runs last so it sees the freshest attempt count.
    func reconcileDelivery(_ snapshot: Task) async {
        // RE-READ. `snapshot` came from this tick's `store.all()`, taken before the phase switch ran —
        // and the switch's `.live` branch can `markDead` this very card WITHOUT `continue`ing
        // (+Reconcile.swift, the `!alive → reallyGone` path). Evaluating `deliverable`, the stuck flag,
        // or `hasClaimable(epoch:)` against that stale snapshot would test a phase and a generation the
        // switch just invalidated — and a stale-epoch `hasClaimable` is a genuine mis-evaluation, not
        // merely a wasted dispatch.
        guard let t = await store.get(snapshot.id), !t.archived else { return }
        await chargeExpiredTokens(t)
        guard deliverable(t) else { return }
        // A stuck card is STABLE: no re-claiming, no lease churn, so the human's clear/retry window
        // (the inbox editor) is never raced. Only a `send`, a confirm, or an EMPTIED inbox re-arms it
        // — and the last of those is the arm's own duty, so a stuck card still runs `clearStuckIfDrained`
        // (a no-op unless its queue actually drained) before standing down.
        if t.deliveryStuckSince != nil { await clearStuckIfDrained(t.id); return }
        if let attempt = deliveryAttempts[t.id], now() < attempt.nextEligible { return }
        guard !deliveriesInFlight.contains(t.id) else { return }
        guard await inbox.hasClaimable(t.id, epoch: t.sessionEpoch, now: now()) else {
            await clearStuckIfDrained(t.id)
            return
        }
        // 02 §deliverable-card, literally: a `.dead` card is arm-deliverable only when
        // `isResumable || titleProvisional`; "dead and not resumable → stuck-eligible DIRECTLY".
        // Dispatching it would burn five backed-off wakes (minutes of silence) to reach the same end
        // state, so the contract short-circuits — there is provably no route, and the human is the
        // only thing that can help. "Eligible" is read as bypassing the ATTEMPT budget while keeping
        // the message-age condition, so a one-second-old message still isn't nagged about.
        // Capture the generation BEFORE the suspending `isResumable` so the flip is fenced to it: a
        // `restart` reviving the card during that await bumps the epoch, and the flip must not stamp
        // stuck on the now-reviving generation.
        let deadEpoch = t.sessionEpoch
        if case .dead = t.phase, !(await isResumable(t)), !t.titleProvisional {
            await deliveryDeadBypassPause?()   // test seam: land a reviving restart in this window
            await flipStuckIfExhausted(t.id, expectedEpoch: deadEpoch, bypassAttemptBudget: true)
            return
        }
        // AWAITED, not detached. `wake`'s own body is short — actor-local reads, one inbox check, and a
        // `transition` — with the heavy bring-up owned by the RelaunchStepper on a later tick, and
        // `reconcile()` already awaits far costlier per-card off-actor tmux probes. An unstructured
        // task here would buy nothing and cost two real things: the stuck flip below would race this
        // tick's charge (so it would NOT "see the freshest attempt count" as it must), and every arm
        // test would have to poll for an effect with no happens-before edge.
        // Fence to the pre-`wake` generation: if `wake` recorded a cold relaunch (bumping the epoch to
        // `.relaunching`) the card is being delivered to, not stuck — the epoch mismatch aborts the flip.
        let liveEpoch = t.sessionEpoch
        await wake(t.id)
        await flipStuckIfExhausted(t.id, expectedEpoch: liveEpoch)
    }

    // MARK: - attempt accounting

    /// Charge the arm's retry budget for every dispatched token that is no longer live and was never
    /// confirmed — exactly ONCE per token.
    ///
    /// `outstandingTokens[cardId]` is the ledger of tokens we dispatched; a token disappears from it on
    /// `deliveryConfirmed` (confirm OR release — no longer in flight). So a token still in the set whose
    /// lease is no longer live in the inbox was, by construction, a delivery that was dispatched and
    /// died: expired, or re-owned by a later claim. We charge it and REMOVE it, so an expired lease
    /// sitting across many ticks costs one attempt, and a fresh claim (a new token) re-arms the
    /// accounting.
    func chargeExpiredTokens(_ t: Task) async {
        guard let outstanding = outstandingTokens[t.id], !outstanding.isEmpty else { return }
        // Ask the Inbox per token, through the TOKEN-scoped, EXPIRY-aware predicate. Presence alone is
        // the wrong test: a stale-epoch held relaunchSeed lease still carries its token, and since the
        // wave-1 fence it can never confirm — a presence test would leave it outstanding forever.
        var dead: Set<UUID> = []
        for token in outstanding where !(await inbox.isLeaseLive(token: token, now: now())) {
            dead.insert(token)
        }
        guard !dead.isEmpty else { return }
        await deliveryExpiryScanPause?()   // test seam: land a confirm/dispatch in the re-read window
        // RE-READ the ledger after the awaits above — never write back the pre-await snapshot. While we
        // were suspended, `deliveryConfirmed` may have removed a token (writing the snapshot back would
        // RESURRECT it, then we'd charge a delivery that actually succeeded) or a new dispatch may have
        // added one (the snapshot would DISCARD it). Subtract from what is there NOW, and charge only
        // tokens still present at this instant.
        let current = outstandingTokens[t.id] ?? []
        let chargeable = dead.intersection(current)
        guard !chargeable.isEmpty else { return }
        let remaining = current.subtracting(chargeable)
        outstandingTokens[t.id] = remaining.isEmpty ? nil : remaining
        for _ in chargeable { chargeDeliveryAttempt(t.id) }
    }

    // MARK: - stuck lifecycle

    /// How many charged attempts the retry budget allows before a card is stuck-eligible.
    static let deliveryStuckAttemptThreshold = 5

    /// Flip a card to delivery-stuck when BOTH halves of the contract's condition hold: the retry
    /// budget is spent (≥ 5 charged attempts) AND the oldest pending message has outlived
    /// `deliveryStuckAfter`. Two conditions, not one, because either alone lies: a burst of attempts
    /// against a briefly-unreachable bridge is not a human's problem, and an old message on a card that
    /// has not actually failed anything is not stuck.
    ///
    /// **The guard is re-validated on the actor immediately before the write.** Everything above this
    /// line suspended (the store read, the inbox peek), and `send` (B5a) and `deliveryConfirmed` (B2)
    /// both zero `deliveryAttempts` — so a flip decided a moment ago can be stale by the time it would
    /// be written, and a stuck badge on a just-re-armed card is exactly the false alarm this feature
    /// must not produce.
    ///
    /// **`expectedEpoch` fences a concurrent REVIVAL.** The caller decided this card was stuck-eligible
    /// at a specific generation; but `isResumable`/`wake` above the callers both suspend, and a
    /// `restart`/`resume` can legally move the card to `.relaunching` (bump the epoch, set
    /// `titleProvisional`) or a report can adopt it back to `.live` during that window. Stamping stuck
    /// on a card that is now being delivered to leaves a false flag the arm then suppresses on and B5b
    /// would notify about. So the flip proceeds ONLY while the card is still at `expectedEpoch` AND
    /// still in the phase the decision was made for (`.dead` for the direct-dead bypass, else
    /// `.live(.waiting(.humanTurn))`) — checked before the write AND re-checked after it, since the
    /// write itself suspends.
    func flipStuckIfExhausted(_ id: UUID, expectedEpoch: Int, bypassAttemptBudget: Bool = false) async {
        func budgetSpent() -> Bool {
            bypassAttemptBudget || (deliveryAttempts[id]?.count ?? 0) >= Self.deliveryStuckAttemptThreshold
        }
        guard budgetSpent() else { return }
        let oldest = await inbox.peek(id).map(\.createdAt).min()
        guard let oldest,
              now().timeIntervalSince(oldest) > TimeInterval(config.deliveryStuckAfter) else { return }
        // RE-VALIDATE on the actor, after every suspension, immediately before the write: same
        // generation + still stuck-eligible + budget still spent + not already flagged.
        guard budgetSpent(),
              let card = await store.get(id), card.deliveryStuckSince == nil,
              stuckOwnershipHolds(card, expectedEpoch: expectedEpoch, expectDead: bypassAttemptBudget),
              budgetSpent()
        else { return }
        let stamp = now()
        guard let (saved, rev) = try? await store.update(id, { $0.deliveryStuckSince = stamp })
        else { return }
        // COMPENSATE AFTER THE WRITE — `store.update` itself suspends, so "re-validate immediately
        // before the write" cannot make the write atomic. A `send`/confirm re-arming the budget or
        // draining the queue, OR a `restart`/adopt REVIVING the card (new epoch / eligible phase gone),
        // landing during that write would otherwise be overwritten by our stamp, leaving a false flag.
        //
        // ORDER IS LOAD-BEARING. Re-read the suspending reads FIRST (queue, then the fresh card), then
        // the actor-local budget LAST with no `await` before the guard/emit, so the thing `send`/`confirm`
        // reset is checked ATOMICALLY. NOTHING IS EMITTED UNTIL HERE, so no subscriber observes a
        // transient true→false flip — B5b's AttentionTracker fires once on false→true and would send an
        // irreversible push for a stuck state that never really existed. Residual, accepted: the
        // PERSISTED field can hold `stamp` for one actor hop before the undo; nothing reads it in-flight.
        let stillQueued = !(await inbox.peek(id).isEmpty)
        let fresh = await store.get(id)
        let stillOwned = fresh.map { stuckOwnershipHolds($0, expectedEpoch: expectedEpoch, expectDead: bypassAttemptBudget) } ?? false
        guard stillQueued, stillOwned, budgetSpent() else {
            if let (undone, r) = try? await store.update(id, { $0.deliveryStuckSince = nil }) {
                emit(.taskUpserted(undone), rev: r)      // emit ONLY the final state
            }
            return
        }
        emit(.taskUpserted(saved), rev: rev)
        emitActivity(.warning, saved, .daemon, "delivery stuck — message(s) undelivered")
    }

    /// Does the flip still own this card? The card must be non-archived, at the generation the flip was
    /// decided for, and STILL in the phase that made it stuck-eligible — `.dead` for the direct-dead
    /// bypass, else `.live(.waiting(.humanTurn))`. Any revival (`.relaunching`, an adopt back to
    /// `.live(.running)`, or a completed dead card brought back live) changes one of those and aborts
    /// the flip, so a card now being delivered to never carries a false stuck flag.
    private func stuckOwnershipHolds(_ card: Task, expectedEpoch: Int, expectDead: Bool) -> Bool {
        guard !card.archived, card.sessionEpoch == expectedEpoch else { return false }
        if expectDead { if case .dead = card.phase { return true }; return false }
        if case .live(.waiting(.humanTurn)) = card.phase { return true }
        return false
    }

    /// Clear the stuck flag once there is genuinely nothing left to deliver (the human removed the
    /// messages, or a late confirm emptied the queue). The other two owners of the clear are
    /// `deliveryConfirmed` (B2) and the `send` handler (B5a).
    func clearStuckIfDrained(_ id: UUID) async {
        guard let card = await store.get(id), card.deliveryStuckSince != nil else { return }
        guard await inbox.peek(id).isEmpty else { return }
        guard let (saved, rev) = try? await store.update(id, { $0.deliveryStuckSince = nil })
        else { return }
        emit(.taskUpserted(saved), rev: rev)
    }
}
