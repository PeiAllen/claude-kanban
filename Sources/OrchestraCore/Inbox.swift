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

    /// Pending messages for a card, in append (FIFO) order. Non-destructive.
    public func peek(_ cardId: UUID) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter { $0.cardId == cardId }
    }

    /// Append an exact message, retaining its durable identity and delivery provenance. With a `dedupKey`,
    /// a no-op-safe idempotency guard suppresses an already-pending message for the same card and key.
    public func enqueue(_ message: InboxMessage) throws {
        ensureLoaded()
        if let dedupKey = message.dedupKey,
           messages.contains(where: { $0.cardId == message.cardId && $0.dedupKey == dedupKey }) {
            return   // already queued for this card under the same key — dedup
        }
        // Transactional: publish the in-memory row only after the disk commit succeeds. A persist throw
        // must not leave a dedup key resident in memory, or a redrive could be suppressed even though the
        // original message never reached durable storage.
        messages.append(message)
        do { try persist() } catch { messages.removeAll { $0.id == message.id }; throw error }
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
        // TRANSACTIONAL: the candidate is published in memory ONLY after the disk commit succeeds. If
        // `persist()` throws (disk full / permission / replace error), roll the append back before
        // rethrowing — otherwise the contracted retry (`send` re-issues the same id) would find the row
        // still in memory, return `false`, and `send:722` would report SUCCESS without the message ever
        // reaching disk. A daemon death before the next inbox mutation flushes would then LOSE an
        // acknowledged send — the at-least-once violation B exists to prevent. No `await` sits between
        // the append and the persist, so `removeAll { id }` restores the exact prior state.
        messages.append(InboxMessage(id: id, cardId: cardId, text: text, source: source, createdAt: now()))
        do { try persist() } catch { messages.removeAll { $0.id == id }; throw error }
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

    // `drain`/`drainFirst` DELETED (B4): after B3's de-drain they had zero production callers, and a
    // public remove-without-receipt primitive is the exact trap this at-least-once design exists to
    // eliminate — the confirm funnel guards `confirm`, not a raw drain, so a later delivery-path
    // author (B5a/D1/E1) could silently reintroduce remove-before-receipt with nothing to catch it.
    // Delivery removes ONLY through `confirm(token:)` on a proven receipt; the editor removes through
    // `remove(_:)`; readers use the non-destructive `peek`.

    /// Remove one message by id (no-op if absent). Used by the inbox editor. Returns the removed
    /// message's OWNER `cardId`, or `nil` when no message matched — B5a's editor stuck-reset re-arms
    /// exactly that owner, never the caller's ref (this lookup is GLOBAL by message id, so the ref a
    /// verb was given and the message's true owner can differ, or the id may not exist at all).
    ///
    /// FORCE-RELEASES the message's in-flight batch (the human always wins): the rendered payload no
    /// longer matches the queue, so the batch returns to pending and re-delivers as a fresh claim. The
    /// already-rendered payload may still arrive once — benign and disclosed.
    @discardableResult
    public func remove(_ id: UUID) throws -> UUID? {
        ensureLoaded()
        guard let msg = messages.first(where: { $0.id == id }) else { return nil }
        if let token = msg.lease?.token { unlease { $0.lease?.token == token } }
        messages.removeAll { $0.id == id }
        try persist()
        return msg.cardId
    }

    /// Replace a message's text in place; id / cardId / source / deduplication / createdAt are preserved.
    /// Force-releases the batch for the same reason `remove` does — an in-flight token must never confirm
    /// text the human has since rewritten. Returns the edited message's OWNER `cardId` (throws if absent)
    /// so B5a's editor stuck-reset re-arms that owner, not the caller's ref (the lookup is global by id).
    @discardableResult
    public func update(_ id: UUID, text: String) throws -> UUID {
        ensureLoaded()
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.invalidParams("no inbox message with id \(id)")
        }
        if let token = messages[idx].lease?.token { unlease { $0.lease?.token == token } }
        let old = messages[idx]
        messages[idx] = InboxMessage(id: old.id, cardId: old.cardId, text: text, source: old.source,
                                     dedupKey: old.dedupKey, createdAt: old.createdAt, lease: nil)
        try persist()
        return old.cardId
    }

    /// Reorder a single card's pending messages. `orderedIds` must be a permutation of that card's
    /// current message ids. Because all cards share one append-ordered array, this refills exactly the
    /// array slots the card already occupies (in the new order), leaving other cards' interleaving intact.
    public func reorder(_ cardId: UUID, orderedIds: [UUID]) throws {
        ensureLoaded()
        let slots = messages.enumerated().filter { $0.element.cardId == cardId }
        let current = slots.map(\.element)
        guard Set(orderedIds) == Set(current.map(\.id)) else {
            throw OrchestraError.invalidParams("orderedIds must be a permutation of the card's pending message ids")
        }
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let reordered = orderedIds.map { byId[$0]! }
        for (slot, msg) in zip(slots.map(\.offset), reordered) { messages[slot] = msg }
        try persist()
    }

    /// Clear the lease on every message matching `where` (in place, preserving all other fields).
    /// Introduced HERE (not with release/releaseAll in Task 6) because `claim` is its first reference.
    private func unlease(where match: (InboxMessage) -> Bool) {
        for (idx, msg) in messages.enumerated() where match(msg) && msg.lease != nil {
            messages[idx] = InboxMessage(id: msg.id, cardId: msg.cardId, text: msg.text, source: msg.source,
                                         dedupKey: msg.dedupKey, createdAt: msg.createdAt, lease: nil)
        }
    }

    /// Is this message claimable by `route` at `epoch`, as of `now`? The claimable set (L2):
    /// unleased ∪ leases older than `leaseTimeout` ∪ leases from a lower epoch (their session is
    /// provably gone — the funnel's epoch bump is the invalidation boundary) ∪ — for a `relaunchSeed`
    /// claim — the card's own prior `relaunchSeed` lease at ANY epoch, so a retried relaunch re-owns its
    /// in-flight batch instead of coming up seedless.
    private func isClaimable(_ msg: InboxMessage, route: DeliveryRoute, epoch: Int, now: Date) -> Bool {
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
        for (idx, msg) in messages.enumerated() where takenIds.contains(msg.id) {
            messages[idx] = InboxMessage(id: msg.id, cardId: msg.cardId, text: msg.text, source: msg.source,
                                         dedupKey: msg.dedupKey, createdAt: msg.createdAt, lease: lease)
        }
        // Kill the DEAD leases on the claimable-but-unconsumed tail. A message that entered the pool did
        // so because its lease was expired/stale-epoch/re-ownable — i.e. already invalid. Leaving that old
        // token on an untaken message keeps it live, and `confirm` matches on token alone: a late ack from
        // the provably-gone prior-epoch session would then remove a message that was never re-delivered.
        // "Re-leasing mints a fresh token and invalidates the old one" has to cover the whole pool, not
        // just the prefix we took.
        let staleTail = pool.filter { !takenIds.contains($0.id) && $0.lease != nil }
        if !staleTail.isEmpty {
            let staleIds = Set(staleTail.map(\.id))
            unlease { staleIds.contains($0.id) }
        }
        // A handoff-only batch (consumed == 0) leases nothing; persist only if something actually changed.
        if !taken.isEmpty || !staleTail.isEmpty { try persist() }
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
        let hit = messages.filter { $0.lease?.token == token }
        guard !hit.isEmpty else { return false }
        messages.removeAll { $0.lease?.token == token }
        confirmedIds.append(contentsOf: hit.map(\.id))
        if confirmedIds.count > Self.confirmedRingCap {
            confirmedIds.removeFirst(confirmedIds.count - Self.confirmedRingCap)   // FIFO evict
        }
        try persist()
        return true
    }

    /// Return a batch to pending (its route abandoned). Stale/unknown token → no-op.
    public func release(token: UUID) throws {
        ensureLoaded()
        guard messages.contains(where: { $0.lease?.token == token }) else { return }
        unlease { $0.lease?.token == token }
        try persist()
    }

    /// Lifecycle teardown: drop every lease for a card. The messages stay durable — a reopen's relaunch
    /// delivers them.
    public func releaseAll(_ cardId: UUID) throws {
        ensureLoaded()
        guard messages.contains(where: { $0.cardId == cardId && $0.lease != nil }) else { return }
        unlease { $0.cardId == cardId }
        try persist()
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
            $0.lease?.token == token
            && $0.lease.map { now.timeIntervalSince($0.leasedAt) < leaseTimeout } == true
        }
    }

    /// Same predicate, callable from other already-on-actor methods (`claim`'s `blockIfLiveLease`) without a
    /// re-`ensureLoaded`. An EXPIRED lease is not live — it is re-claimable, so it does not count.
    private func liveLeaseExists(_ cardId: UUID, epoch: Int, now: Date) -> Bool {
        messages.contains {
            $0.cardId == cardId && $0.lease?.epoch == epoch
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
        var changed = false
        for (idx, msg) in messages.enumerated()
        where msg.cardId == cardId && msg.lease?.route == .relaunchSeed && msg.lease?.epoch == epoch {
            guard let lease = msg.lease else { continue }
            let stamped = DeliveryLease(token: lease.token, route: lease.route, epoch: lease.epoch,
                                        leasedAt: lease.leasedAt, tailWatermark: watermark, tailPath: path)
            messages[idx] = InboxMessage(id: msg.id, cardId: msg.cardId, text: msg.text, source: msg.source,
                                         dedupKey: msg.dedupKey, createdAt: msg.createdAt, lease: stamped)
            changed = true
        }
        if changed { try persist() }
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
