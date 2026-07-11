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

    public init(path: String = Config.inboxPath) { self.path = path }

    @discardableResult
    public func load() -> [InboxMessage] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { messages = []; loaded = true; return messages }
        do {
            messages = try OrchestraJSON.decoder.decode([InboxMessage].self, from: Data(contentsOf: url))
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            messages = []
        }
        loaded = true
        return messages
    }

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
        messages.append(InboxMessage(cardId: cardId, text: text, dedupKey: dedupKey))
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
        let data = try OrchestraJSON.pretty.encode(messages)
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
