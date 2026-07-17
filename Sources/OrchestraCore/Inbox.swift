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

    /// The envelope we READ — rows AND ring entries decode element-wise so one bad record can't strand
    /// the file. `confirmedIds` is `[String]?` (not `[UUID]?`) deliberately: a single malformed id string
    /// (`"not-a-uuid"`) in an otherwise-valid envelope would make a strict `[UUID]` decode throw, fall
    /// through to the legacy-array attempt, fail that too, and `.bak` every valid pending send beside it —
    /// the exact top-level-only-`.bak` boundary this loader promises. We map to `UUID` in `load`, dropping
    /// any unparseable entry (a lost tombstone at worst re-delivers a message once — never drops a send).
    private struct StoredInbox: Decodable { let messages: [FailableInboxMessage]; let confirmedIds: [String]? }

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
                confirmedIds = (env.confirmedIds ?? []).compactMap(UUID.init(uuidString:))  // drop bad ids
            } else {
                // Pre-upgrade bare array → messages + an empty ring. TOLERANT BY CONSTRUCTION: an
                // envelope-only decoder would .bak every existing inbox on upgrade and drop every
                // pending send (round-4 gate CRITICAL). Mirrors TaskStore's {rev,tasks} precedent.
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

    /// Append a message for a card. With a `dedupKey`, a no-op-safe idempotency guard: if a message for
    /// this card already carries the same `dedupKey`, the append is SKIPPED (the crash-then-redrive
    /// discipline — Teardown's child nudge fires at most once per `(childId, parent-archived:<branch>)`).
    public func enqueue(_ cardId: UUID, _ text: String, dedupKey: String? = nil) throws {
        ensureLoaded()
        if let dedupKey,
           messages.contains(where: { $0.cardId == cardId && $0.dedupKey == dedupKey }) {
            return   // already queued for this card under the same key — dedup
        }
        messages.append(InboxMessage(cardId: cardId, text: text, dedupKey: dedupKey, createdAt: now()))
        try persist()
    }

    /// Return + remove all pending messages for a card, in order.
    @discardableResult
    public func drain(_ cardId: UUID) throws -> [InboxMessage] {
        ensureLoaded()
        let pending = messages.filter { $0.cardId == cardId }
        guard !pending.isEmpty else { return [] }
        messages.removeAll { $0.cardId == cardId }
        try persist()
        return pending
    }

    /// Remove + return the first `count` pending messages for a card, in order, leaving the rest queued.
    /// Backs the Stop-hook's whole-messages-to-fit drain (`StopDrain.fit`): only the messages that fit the
    /// payload budget this turn are removed; the overflow stays durable for the next turn-end.
    @discardableResult
    public func drainFirst(_ cardId: UUID, _ count: Int) throws -> [InboxMessage] {
        ensureLoaded()
        let pending = messages.filter { $0.cardId == cardId }
        guard !pending.isEmpty, count > 0 else { return [] }
        let take = Array(pending.prefix(count))
        let takeIds = Set(take.map(\.id))
        messages.removeAll { takeIds.contains($0.id) }
        try persist()
        return take
    }

    /// Remove one message by id (no-op if absent). Used by the inbox editor.
    ///
    /// FORCE-RELEASES the message's in-flight batch (the human always wins): the rendered payload no
    /// longer matches the queue, so the batch returns to pending and re-delivers as a fresh claim. The
    /// already-rendered payload may still arrive once — benign and disclosed.
    public func remove(_ id: UUID) throws {
        ensureLoaded()
        if let token = messages.first(where: { $0.id == id })?.lease?.token {
            unlease { $0.lease?.token == token }
        }
        messages.removeAll { $0.id == id }
        try persist()
    }

    /// Replace a message's text in place; id / cardId / createdAt are preserved. Force-releases the
    /// batch for the same reason `remove` does — an in-flight token must never confirm text the human
    /// has since rewritten.
    public func update(_ id: UUID, text: String) throws {
        ensureLoaded()
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.invalidParams("no inbox message with id \(id)")
        }
        if let token = messages[idx].lease?.token { unlease { $0.lease?.token == token } }
        let old = messages[idx]
        messages[idx] = InboxMessage(id: old.id, cardId: old.cardId, text: text,
                                     dedupKey: old.dedupKey, createdAt: old.createdAt)
        try persist()
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
            messages[idx] = InboxMessage(id: msg.id, cardId: msg.cardId, text: msg.text,
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
    /// invalidates the old one. `nil` when the render has nothing to deliver.
    public func claim(_ cardId: UUID, route: DeliveryRoute, epoch: Int, budget: Int,
                      render: ([InboxMessage], Int) -> (payload: String, consumed: Int)?,
                      now: Date) throws -> ClaimedBatch? {
        ensureLoaded()
        let pool = messages.filter { $0.cardId == cardId && isClaimable($0, route: route, epoch: epoch, now: now) }
        guard let (payload, consumed) = render(pool, budget), !payload.isEmpty else { return nil }
        let token = UUID()
        let taken = Array(pool.prefix(max(0, consumed)))
        let takenIds = Set(taken.map(\.id))
        let lease = DeliveryLease(token: token, route: route, epoch: epoch, leasedAt: now)
        for (idx, msg) in messages.enumerated() where takenIds.contains(msg.id) {
            messages[idx] = InboxMessage(id: msg.id, cardId: msg.cardId, text: msg.text,
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
    /// Landed here in Task 4 (not with `release`/`releaseAll`/`hasClaimable`/`confirmHeldRelaunch` in
    /// Task 6) because `InboxClaimTests.partialReclaimKillsStaleTailToken` needs it to verify the
    /// stale-tail-unlease invariant: a late confirm from a provably-superseded lease must not delete an
    /// undelivered message. Task 6 adds the rest of the confirm/release surface + the ring-eviction test.
    public func confirm(token: UUID) throws {
        ensureLoaded()
        let hit = messages.filter { $0.lease?.token == token }
        guard !hit.isEmpty else { return }
        messages.removeAll { $0.lease?.token == token }
        confirmedIds.append(contentsOf: hit.map(\.id))
        if confirmedIds.count > Self.confirmedRingCap {
            confirmedIds.removeFirst(confirmedIds.count - Self.confirmedRingCap)   // FIFO evict
        }
        try persist()
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

    /// Confirm a HELD `relaunchSeed` lease at exactly `epoch` — one atomic find-and-confirm, so B3's
    /// first-signal confirm can't drift from the lease it means. No-op when absent.
    public func confirmHeldRelaunch(_ cardId: UUID, epoch: Int) throws {
        ensureLoaded()
        guard let token = messages.first(where: {
            $0.cardId == cardId && $0.lease?.route == .relaunchSeed && $0.lease?.epoch == epoch
        })?.lease?.token else { return }
        try confirm(token: token)
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
