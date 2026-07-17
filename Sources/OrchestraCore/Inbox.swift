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
    public func remove(_ id: UUID) throws {
        ensureLoaded()
        messages.removeAll { $0.id == id }
        try persist()
    }

    /// Replace a message's text in place; id / cardId / createdAt are preserved.
    public func update(_ id: UUID, text: String) throws {
        ensureLoaded()
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.invalidParams("no inbox message with id \(id)")
        }
        let old = messages[idx]
        messages[idx] = InboxMessage(id: old.id, cardId: old.cardId, text: text, createdAt: old.createdAt)
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
