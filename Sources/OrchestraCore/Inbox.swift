import Foundation

// `InboxMessage` (the client-safe value type) now lives in OrchestraKit so the shared BoardModel can
// use it on iOS; the daemon-side `Inbox` actor below stays here and sees it via Core's re-export.

/// Durable per-card message queue (F3), sibling to `TaskStore`: actor-over-JSON, atomic save, malformed
/// → `.bak` + `[]`. A single append-ordered array gives FIFO-per-card via a stable filter, and survives
/// a daemon restart (messages persist until drained).
public actor Inbox {
    private let path: String
    private var messages: [InboxMessage] = []
    private var loaded = false

    /// The confirmed-ids ring: a bounded FIFO tombstone of delivered message ids. `confirm` removes the
    /// row, so `send`'s idempotency (B5a) needs this to no-op a retry whose response was lost AFTER the
    /// message was delivered and removed. Bounded so the file can't grow without limit.
    private var confirmedIds: [UUID] = []
    static let confirmedRingCap = 256

    /// Advisory delivery history is bounded independently for each card. Queued and failed rows are
    /// never evicted because they still need a human decision or a native sender attempt.
    static let handedOffHistoryCap = 100

    /// The on-disk envelope we WRITE, encoding real `[InboxMessage]`.
    private struct InboxEnvelope: Encodable { let messages: [InboxMessage]; let confirmedIds: [UUID] }

    /// The envelope we READ — messages AND ring entries decode element-wise, and a malformed-or-non-array
    /// `confirmedIds` degrades to an empty ring, so nothing but top-level-unparseable JSON can `.bak` the
    /// file. A lost tombstone at worst re-delivers a message once; it never drops a pending send.
    private struct StoredInbox: Decodable {
        let messages: [FailableInboxMessage]
        let confirmedIds: [FailableString]
        private enum CodingKeys: String, CodingKey { case messages, confirmedIds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([FailableInboxMessage].self, forKey: .messages)
            // A non-array `confirmedIds` (`5`, `{}`) or an absent/null one becomes an empty ring rather
            // than throwing the whole envelope into the `.bak` path; malformed ELEMENTS drop individually
            // via FailableString.
            confirmedIds = ((try? c.decodeIfPresent([FailableString].self, forKey: .confirmedIds)) ?? nil) ?? []
        }
    }

    /// A string wrapper whose decode NEVER throws: a non-string ring element (`5`) becomes nil and drops,
    /// instead of failing the whole ring decode.
    private struct FailableString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws { self.value = try? String(from: decoder) }
    }

    /// A row wrapper whose decode NEVER throws: a malformed record becomes nil and is dropped, instead
    /// of failing the whole array decode and sending every pending send to `.bak`. Mirrors
    /// `TaskStore.FailableTask` — the precedent that earns the "only top-level-unparseable .bak's"
    /// boundary. B1 grows this row schema (`lease`) and B3 grows it again (watermark/path), which is
    /// exactly when element-wise fragility starts to bite.
    private struct FailableInboxMessage: Decodable {
        let message: InboxMessage?
        init(from decoder: Decoder) throws { self.message = try? InboxMessage(from: decoder) }
    }

    private let leaseTimeout: TimeInterval
    /// `now()` stamps PERSISTED timestamps only (`createdAt`), never scheduling — the TaskStore pattern.
    /// Lease expiry math takes `now` as an explicit argument instead (see `claim`), so the caller's
    /// instant governs both the expiry decision and the `leasedAt` it writes.
    private let now: @Sendable () -> Date

    public init(path: String = Config.inboxPath,
                leaseTimeout: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path; self.leaseTimeout = leaseTimeout; self.now = now
    }

    @discardableResult
    public func load() -> [InboxMessage] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            messages = []; confirmedIds = []; loaded = true; return messages
        }
        do {
            let data = try Data(contentsOf: url)
            if let env = try? OrchestraJSON.decoder.decode(StoredInbox.self, from: data) {
                messages = env.messages.compactMap(\.message)                   // post-upgrade envelope
                confirmedIds = env.confirmedIds.compactMap(\.value).compactMap(UUID.init(uuidString:))  // drop bad ids
            } else {
                // Pre-upgrade bare array → messages + an empty ring. TOLERANT BY CONSTRUCTION: an
                // envelope-only decoder would .bak every existing inbox on upgrade and drop every
                // pending send. Mirrors TaskStore's {rev,tasks} precedent.
                messages = try OrchestraJSON.decoder
                    .decode([FailableInboxMessage].self, from: data).compactMap(\.message)
                confirmedIds = []
            }
        } catch {
            // Top-level unparseable ONLY — a single malformed row is dropped element-wise above.
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            messages = []; confirmedIds = []
        }
        loaded = true
        return messages
    }

    /// Has this message id already been confirmed (delivered + removed)? Backs B5a's send dedup.
    public func wasConfirmed(_ id: UUID) -> Bool { ensureLoaded(); return confirmedIds.contains(id) }

    private func ensureLoaded() { if !loaded { _ = load() } }

    /// Unresolved messages for a card, in append (FIFO) order. Handed-off rows live in `history` so
    /// they remain advisory evidence without being candidates for delivery or editing.
    public func peek(_ cardId: UUID) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter { $0.cardId == cardId && $0.state != .handedOff }
    }

    /// Read-only local history of provider-accepted messages for a card, preserving their durable order.
    public func history(_ cardId: UUID) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter { $0.cardId == cardId && $0.state == .handedOff }
    }

    /// The only row a native sender may attempt. Handed-off history is skipped; a failed unresolved head
    /// deliberately blocks later queued rows until a human retries, edits, or removes it.
    public func nextDeliverable(_ cardId: UUID) -> InboxMessage? {
        ensureLoaded()
        for message in messages where message.cardId == cardId {
            switch message.state {
            case .handedOff:
                continue
            case .failed:
                return nil
            case .queued:
                return message
            }
        }
        return nil
    }

    /// Append an exact message, retaining its durable identity and delivery provenance. With a `dedupKey`,
    /// a no-op-safe idempotency guard suppresses an already-unresolved message for the same card and key.
    public func enqueue(_ message: InboxMessage) throws {
        ensureLoaded()
        if let dedupKey = message.dedupKey,
           messages.contains(where: {
               $0.cardId == message.cardId && $0.dedupKey == dedupKey && $0.state != .handedOff
           }) {
            return   // unresolved duplicate for this card and key
        }
        try mutatePersistently {
            messages.append(message)
            if message.state == .handedOff { trimHandedOffHistory(for: message.cardId) }
        }
    }

    /// Append a message carrying an explicit client-minted `id`, but ONLY if that id is unknown — not
    /// already pending AND not in the confirmed-ids ring. Returns whether it actually enqueued (`false`
    /// = a duplicate that mutated nothing). This is B5a's `send` idempotency, and the check+append MUST
    /// be ONE atomic actor call: `OrchestraService` is reentrant, so a caller-side `wasConfirmed`-then-
    /// `enqueue` across two awaits lets two concurrent same-id sends both observe "unknown" and both
    /// append — the exact check-then-act race B2's atomic `claim` closed. `confirm` tombstones the id in
    /// the ring, so this no-ops a retry whose response was lost even AFTER the message was delivered and
    /// removed. `source` is retained beside the client id and delivery lease; internal nudge callers use
    /// the plain `enqueue`, which mints its own id — no dedup.
    @discardableResult
    public func enqueueIfUnknown(_ cardId: UUID, _ text: String, id: UUID,
                                 source: InboxMessageSource? = .orchestra) throws -> Bool {
        ensureLoaded()
        if messages.contains(where: { $0.id == id }) || confirmedIds.contains(id) { return false }
        try mutatePersistently {
            messages.append(InboxMessage(id: id, cardId: cardId, text: text, source: source, createdAt: now()))
        }
        return true
    }

    /// Append a message for a card. Internal Orchestra-generated nudges default to `.orchestra`; direct
    /// user delivery enters through `OrchestraService.send`, whose default is `.human`.
    public func enqueue(_ cardId: UUID, _ text: String,
                        source: InboxMessageSource? = .orchestra,
                        dedupKey: String? = nil) throws {
        try enqueue(InboxMessage(cardId: cardId, text: text, source: source,
                                 dedupKey: dedupKey, createdAt: now()))
    }

    /// Mark a queued send as accepted by the native provider. The text-and-state compare prevents a
    /// future sender completion from changing a row that a user edited while that send was in flight.
    @discardableResult
    public func markHandedOff(_ id: UUID, expectedText: String,
                              expectedState: InboxMessageState) throws -> Bool {
        try transition(id, expectedText: expectedText, expectedState: expectedState, to: .handedOff)
    }

    /// Mark a queued native send as locally failed. A failed head remains durable and blocks later work
    /// until a user explicitly resolves it.
    @discardableResult
    public func markFailed(_ id: UUID, expectedText: String,
                           expectedState: InboxMessageState) throws -> Bool {
        try transition(id, expectedText: expectedText, expectedState: expectedState, to: .failed)
    }

    /// Move only a failed row back to queued. Retrying an absent, queued, or handed-off row is a no-op.
    @discardableResult
    public func retry(_ id: UUID) throws -> Bool {
        ensureLoaded()
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].state == .failed else {
            return false
        }
        try mutatePersistently {
            messages[index] = rebuilding(messages[index], state: .queued, lease: nil)
        }
        return true
    }

    /// Remove one retained row by id, including handed-off history. Returns its owner or `nil` when absent.
    /// The temporary lease release keeps current callers safe until the old delivery path is deleted.
    @discardableResult
    public func remove(_ id: UUID) throws -> UUID? {
        ensureLoaded()
        guard let msg = messages.first(where: { $0.id == id }) else { return nil }
        try mutatePersistently {
            if let token = msg.lease?.token { unlease { $0.lease?.token == token } }
            messages.removeAll { $0.id == id }
        }
        return msg.cardId
    }

    /// Replace an unresolved row's text while preserving identity and provenance. Editing a failed row
    /// requeues it; handed-off history is immutable. The temporary lease release keeps old callers safe.
    @discardableResult
    public func edit(_ id: UUID, text: String) throws -> UUID {
        ensureLoaded()
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.invalidParams("no inbox message with id \(id)")
        }
        let old = messages[idx]
        guard old.state != .handedOff else {
            throw OrchestraError.invalidParams("handed-off inbox history is immutable")
        }
        try mutatePersistently {
            if let token = old.lease?.token { unlease { $0.lease?.token == token } }
            messages[idx] = rebuilding(old, text: text, state: .queued, lease: nil)
        }
        return old.cardId
    }

    /// Compatibility spelling used by current service callers; native inbox code should use `edit`.
    @discardableResult
    public func update(_ id: UUID, text: String) throws -> UUID { try edit(id, text: text) }

    /// Reorder only a card's unresolved rows. Re-filling just those slots leaves handed-off history at
    /// its durable positions and leaves other cards' interleaving intact.
    public func reorder(_ cardId: UUID, orderedIds: [UUID]) throws {
        ensureLoaded()
        let slots = messages.enumerated().filter {
            $0.element.cardId == cardId && $0.element.state != .handedOff
        }
        let current = slots.map(\.element)
        guard orderedIds.count == current.count, Set(orderedIds) == Set(current.map(\.id)) else {
            throw OrchestraError.invalidParams("orderedIds must be a permutation of the card's unresolved message ids")
        }
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let reordered = orderedIds.map { byId[$0]! }
        try mutatePersistently {
            for (slot, msg) in zip(slots.map(\.offset), reordered) { messages[slot] = msg }
        }
    }

    /// Apply one advisory post-send transition only while the row is still the exact queued snapshot the
    /// sender attempted. `expectedState` is explicit so a stale completion cannot rewrite an edited row.
    private func transition(_ id: UUID, expectedText: String, expectedState: InboxMessageState,
                            to state: InboxMessageState) throws -> Bool {
        ensureLoaded()
        guard expectedState == .queued,
              let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].text == expectedText,
              messages[index].state == expectedState
        else { return false }
        try mutatePersistently {
            messages[index] = rebuilding(messages[index], state: state, lease: nil)
            if state == .handedOff { trimHandedOffHistory(for: messages[index].cardId) }
        }
        return true
    }

    /// Make all in-memory mutations all-or-nothing with their atomic file replacement. This is used by
    /// both advisory transitions and the temporary lease shims below, so a save error never leaves a
    /// different in-memory queue than the last durable one.
    private func mutatePersistently(_ mutation: () throws -> Void) throws {
        let priorMessages = messages
        let priorConfirmedIds = confirmedIds
        do {
            try mutation()
            try persist()
        } catch {
            messages = priorMessages
            confirmedIds = priorConfirmedIds
            throw error
        }
    }

    private func rebuilding(_ message: InboxMessage, text: String? = nil,
                            state: InboxMessageState? = nil, lease: DeliveryLease?) -> InboxMessage {
        InboxMessage(id: message.id, cardId: message.cardId, text: text ?? message.text,
                     source: message.source, dedupKey: message.dedupKey, createdAt: message.createdAt,
                     state: state ?? message.state, lease: lease)
    }

    private func trimHandedOffHistory(for cardId: UUID) {
        let history = messages.indices.filter {
            messages[$0].cardId == cardId && messages[$0].state == .handedOff
        }
        let excess = history.count - Self.handedOffHistoryCap
        guard excess > 0 else { return }
        for index in history.prefix(excess).reversed() { messages.remove(at: index) }
    }

    // MARK: Transitional lease/claim compatibility — delete in native sender cutover

    /// The current service still calls these lease methods until commit 4 switches it to the advisory
    /// sender loop. They intentionally operate only on queued rows, so retained history is never
    /// delivered by the outgoing protocol.

    /// Clear the lease on every matching row while preserving its advisory state and metadata.
    private func unlease(where match: (InboxMessage) -> Bool) {
        for (idx, msg) in messages.enumerated()
        where msg.state == .queued && match(msg) && msg.lease != nil {
            messages[idx] = rebuilding(msg, lease: nil)
        }
    }

    /// Is this message claimable by `route` at `epoch`, as of `now`? The claimable set (L2):
    /// unleased ∪ leases older than `leaseTimeout` ∪ leases from a lower epoch (their session is
    /// provably gone — the funnel's epoch bump is the invalidation boundary) ∪ — for a `relaunchSeed`
    /// claim — the card's own prior `relaunchSeed` lease at ANY epoch, so a retried relaunch re-owns its
    /// in-flight batch instead of coming up seedless.
    private func isClaimable(_ msg: InboxMessage, route: DeliveryRoute, epoch: Int, now: Date) -> Bool {
        guard msg.state == .queued else { return false }
        guard let lease = msg.lease else { return true }
        if now.timeIntervalSince(lease.leasedAt) >= leaseTimeout { return true }
        if lease.epoch < epoch { return true }
        return route == .relaunchSeed && lease.route == .relaunchSeed
    }

    /// Atomically select + fit + lease a FIFO batch for `cardId` — ONE actor call, so the select/lease
    /// split races (cross-route double-claim, truncated-render over-confirm) are unrepresentable.
    ///
    /// `render` runs INSIDE the claim and reports how many whole messages its payload actually consumed;
    /// exactly that prefix is leased and the overflow stays pending. No route renders outside a claim, so
    /// a truncated render can never confirm unrendered messages. Re-leasing mints a fresh token, which
    /// invalidates the old one. `nil` when the render has nothing to deliver. The `render` MUST consume
    /// a **prefix** of the passed pool — `claim` leases exactly `pool.prefix(consumed)`; a render that
    /// consumed a non-prefix subset would lease the wrong messages (all current renders — `StopDrain.fit`,
    /// `HandoffSeed.compose` — honor this).
    public func claim(_ cardId: UUID, route: DeliveryRoute, epoch: Int, budget: Int,
                      render: ([InboxMessage], Int) -> (payload: String, consumed: Int)?,
                      now: Date, blockIfLiveLease: Bool = false) throws -> ClaimedBatch? {
        ensureLoaded()
        // `blockIfLiveLease` refuses a claim while any UNEXPIRED same-epoch lease is outstanding — checked
        // HERE, inside the single atomic actor call, not by a caller's separate `hasLiveLease` await (two
        // awaits let concurrent same-epoch Stops both pass the check and lease different batches, resurrecting
        // the two-leases `.first`-confirm loss the guard exists to kill). The stop path passes it; other
        // routes may coexist, so it is opt-in.
        if blockIfLiveLease && liveLeaseExists(cardId, epoch: epoch, now: now) { return nil }
        let pool = messages.filter { $0.cardId == cardId && isClaimable($0, route: route, epoch: epoch, now: now) }
        guard let (payload, consumed) = render(pool, budget), !payload.isEmpty else { return nil }
        let token = UUID()
        let taken = Array(pool.prefix(max(0, consumed)))
        let takenIds = Set(taken.map(\.id))
        let lease = DeliveryLease(token: token, route: route, epoch: epoch, leasedAt: now)
        // Kill the DEAD leases on the claimable-but-unconsumed tail. A message that entered the pool did
        // so because its lease was expired/stale-epoch/re-ownable — i.e. already invalid. Leaving that old
        // token on an untaken message keeps it live, and `confirm` matches on token alone: a late ack from
        // the provably-gone prior-epoch session would then remove a message that was never re-delivered.
        // "Re-leasing mints a fresh token and invalidates the old one" has to cover the whole pool, not
        // just the prefix we took.
        let staleTail = pool.filter { !takenIds.contains($0.id) && $0.lease != nil }
        // A handoff-only batch (consumed == 0) leases nothing; persist only if something actually changed.
        if !taken.isEmpty || !staleTail.isEmpty {
            try mutatePersistently {
                for (idx, msg) in messages.enumerated() where takenIds.contains(msg.id) {
                    messages[idx] = rebuilding(msg, lease: lease)
                }
                if !staleTail.isEmpty {
                    let staleIds = Set(staleTail.map(\.id))
                    unlease { staleIds.contains($0.id) }
                }
            }
        }
        return ClaimedBatch(token: token, ids: taken.map(\.id), payload: payload)
    }

    /// Remove a confirmed batch — **the ONLY removal on a delivery path** — and tombstone its ids in the
    /// ring, in ONE persist (a crash leaves both halves or neither). A stale/unknown token is an
    /// idempotent no-op: a late ack from a superseded attempt can never remove a re-claimed message.
    ///
    /// Landed here in Task 4 (not with `release`/`releaseAll`/`hasClaimable`/`setTailWatermark` in
    /// Task 6) because `InboxClaimTests.partialReclaimKillsStaleTailToken` needs it to verify the
    /// stale-tail-unlease invariant: a late confirm from a provably-superseded lease must not delete an
    /// undelivered message. Task 6 adds the rest of the confirm/release surface + the ring-eviction test.
    /// Returns whether it actually removed a batch — `false` for a stale/unknown token. The
    /// service funnel (`confirmDelivery`) needs this to reset delivery state ONLY on a real
    /// confirmation: a late ack from a superseded attempt must not re-arm the retry budget.
    @discardableResult
    public func confirm(token: UUID) throws -> Bool {
        ensureLoaded()
        let hit = messages.filter { $0.state == .queued && $0.lease?.token == token }
        guard !hit.isEmpty else { return false }
        try mutatePersistently {
            messages.removeAll { $0.state == .queued && $0.lease?.token == token }
            confirmedIds.append(contentsOf: hit.map(\.id))
            if confirmedIds.count > Self.confirmedRingCap {
                confirmedIds.removeFirst(confirmedIds.count - Self.confirmedRingCap)   // FIFO evict
            }
        }
        return true
    }

    /// Return a batch to pending (its route abandoned). Stale/unknown token → no-op.
    public func release(token: UUID) throws {
        ensureLoaded()
        guard messages.contains(where: { $0.state == .queued && $0.lease?.token == token }) else { return }
        try mutatePersistently { unlease { $0.lease?.token == token } }
    }

    /// Lifecycle teardown: drop every lease for a card. The messages stay durable — a reopen's relaunch
    /// delivers them.
    public func releaseAll(_ cardId: UUID) throws {
        ensureLoaded()
        guard messages.contains(where: { $0.cardId == cardId && $0.state == .queued && $0.lease != nil }) else { return }
        try mutatePersistently { unlease { $0.cardId == cardId } }
    }

    /// Is anything deliverable for this card right now? Route-agnostic on purpose: a message riding a
    /// held same-epoch lease is NOT claimable, so a card mid-delivery is never re-woken (B4's
    /// `wakeIfPending` gate).
    public func hasClaimable(_ cardId: UUID, epoch: Int, now: Date) -> Bool {
        ensureLoaded()
        return messages.contains {
            $0.cardId == cardId && isClaimable($0, route: .channelPush, epoch: epoch, now: now)
        }
    }

    /// Is any UNEXPIRED lease outstanding at exactly `epoch` on this card? Route-agnostic — a delivery is
    /// mid-flight. The stop path uses it to refuse a SECOND stopDrain claim while a prior batch is still
    /// live: two same-epoch leases would let a later `stopHookActive` Stop confirm the WRONG (older,
    /// lost-reply) batch. B4's wake `unexpiredLeaseOutstanding` reuses this (first-reference here). An
    /// EXPIRED lease is not "live" — it is re-claimable, so it does not block.
    public func hasLiveLease(_ cardId: UUID, epoch: Int, now: Date) -> Bool {
        ensureLoaded()
        return liveLeaseExists(cardId, epoch: epoch, now: now)
    }

    /// Is THIS token still a live lease — present on some message AND not yet expired? The delivery
    /// arm's expiry-charge predicate (B4), deliberately epoch-AGNOSTIC where `hasLiveLease` is
    /// epoch-exact: the arm must charge a token whose generation is long gone. Presence alone would be
    /// wrong — a stale-epoch held `relaunchSeed` lease still carries its token, and since the
    /// held-confirm epoch fence it can never confirm, so a presence test would strand it outstanding
    /// forever with no other reaper. `false` therefore means "dispatched and dead": re-owned by a
    /// later claim (token gone) or expired in place.
    public func isLeaseLive(token: UUID, now: Date) -> Bool {
        ensureLoaded()
        return messages.contains {
            $0.state == .queued && $0.lease?.token == token
            && $0.lease.map { now.timeIntervalSince($0.leasedAt) < leaseTimeout } == true
        }
    }

    /// Same predicate, callable from other already-on-actor methods (`claim`'s `blockIfLiveLease`) without a
    /// re-`ensureLoaded`. An EXPIRED lease is not live — it is re-claimable, so it does not count.
    private func liveLeaseExists(_ cardId: UUID, epoch: Int, now: Date) -> Bool {
        messages.contains {
            $0.cardId == cardId && $0.state == .queued && $0.lease?.epoch == epoch
            && $0.lease.map { now.timeIntervalSince($0.leasedAt) < leaseTimeout } == true
        }
    }

    /// Stamp the held `relaunchSeed` lease at exactly `epoch` with the post-kill tail watermark + the
    /// rollout path it was captured from (B3's `finishLaunch` duty). One atomic lease UPDATE that keeps
    /// the token/route/epoch/leasedAt intact, so `report()`'s fileTail held-confirm can later fence a
    /// line by `path == lease.tailPath && startOffset >= lease.tailWatermark`. No-op when there is no
    /// such held lease (a fresh spawn, a handoff-only 0-message batch, or a non-fileTail agent).
    ///
    /// The held-relaunch CONFIRM itself is NOT here: B3 routes it through the service `confirmDelivery`
    /// funnel (peek the lease token → `confirmDelivery`), so the archive guard + attempt/stuck resets
    /// can't be bypassed — an atomic self-confirming Inbox helper would skip them.
    public func setTailWatermark(cardId: UUID, epoch: Int, watermark: Int64, path: String) throws {
        ensureLoaded()
        let matching = messages.indices.filter {
            messages[$0].cardId == cardId && messages[$0].state == .queued
                && messages[$0].lease?.route == .relaunchSeed
                && messages[$0].lease?.epoch == epoch
        }
        guard !matching.isEmpty else { return }
        try mutatePersistently {
            for index in matching {
                guard let lease = messages[index].lease else { continue }
                let stamped = DeliveryLease(token: lease.token, route: lease.route, epoch: lease.epoch,
                                            leasedAt: lease.leasedAt, tailWatermark: watermark, tailPath: path)
                messages[index] = rebuilding(messages[index], lease: stamped)
            }
        }
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(InboxEnvelope(messages: messages,
                                                                 confirmedIds: confirmedIds))
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
