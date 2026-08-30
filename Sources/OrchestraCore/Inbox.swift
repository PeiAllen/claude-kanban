import Foundation

/// Durable, per-card advisory inbox. Rows are retained as provider-accepted history instead of being
/// deleted, so a completion only means that the provider accepted the request, never that a model read it.
public actor Inbox {
    public static let maxMessageChars = 10_000
    static let handedOffHistoryCap = 100

    private let path: String
    private let now: @Sendable () -> Date
    private var messages: [InboxMessage] = []
    private var loaded = false

    private struct InboxEnvelope: Encodable {
        let messages: [InboxMessage]
    }

    /// Decoding is intentionally row-tolerant. A malformed row must not turn an otherwise valid inbox
    /// into a backup file and discard unrelated queued work.
    private struct StoredInbox: Decodable {
        let messages: [FailableInboxMessage]
    }

    private struct FailableInboxMessage: Decodable {
        let message: InboxMessage?
        init(from decoder: Decoder) throws { message = try? InboxMessage(from: decoder) }
    }

    public init(path: String = Config.inboxPath,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.now = now
    }

    @discardableResult
    public func load() -> [InboxMessage] {
        guard FileManager.default.fileExists(atPath: path) else {
            messages = []
            loaded = true
            return messages
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let envelope = try? OrchestraJSON.decoder.decode(StoredInbox.self, from: data) {
                messages = envelope.messages.compactMap(\.message)
            } else {
                messages = try OrchestraJSON.decoder
                    .decode([FailableInboxMessage].self, from: data)
                    .compactMap(\.message)
            }
        } catch {
            let backup = path + ".bak"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.moveItem(atPath: path, toPath: backup)
            messages = []
        }
        loaded = true
        return messages
    }

    /// Returns one actor-snapshot of the unresolved queue, optionally including provider-accepted history.
    /// The opt-in keeps background consumers on their existing unresolved-only contract.
    public func peek(_ cardId: UUID, includeHistory: Bool = false) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter {
            $0.cardId == cardId && (includeHistory || $0.state != .handedOff)
        }
    }

    public func history(_ cardId: UUID) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter { $0.cardId == cardId && $0.state == .handedOff }
    }

    /// Returns the FIFO head eligible for a sender. A failed head deliberately blocks later queued rows.
    public func nextDeliverable(_ cardId: UUID) -> InboxMessage? {
        ensureLoaded()
        for message in messages where message.cardId == cardId {
            switch message.state {
            case .handedOff: continue
            case .failed: return nil
            case .queued: return message
            }
        }
        return nil
    }

    public func enqueue(_ message: InboxMessage) throws {
        ensureLoaded()
        if let key = message.dedupKey,
           messages.contains(where: {
               $0.cardId == message.cardId && $0.dedupKey == key && $0.state != .handedOff
           }) {
            return
        }
        try mutatePersistently {
            messages.append(message)
            if message.state == .handedOff { trimHandedOffHistory(for: message.cardId) }
        }
    }

    /// Client-minted ids make a retried send idempotent while its durable row is retained.
    @discardableResult
    public func enqueueIfUnknown(_ cardId: UUID, _ text: String, id: UUID,
                                 source: InboxMessageSource? = .orchestra) throws -> Bool {
        ensureLoaded()
        guard !messages.contains(where: { $0.id == id }) else { return false }
        try mutatePersistently {
            messages.append(InboxMessage(id: id, cardId: cardId, text: text, source: source, createdAt: now()))
        }
        return true
    }

    public func enqueue(_ cardId: UUID, _ text: String,
                        source: InboxMessageSource? = .orchestra,
                        dedupKey: String? = nil) throws {
        try enqueue(InboxMessage(cardId: cardId, text: text, source: source,
                                 dedupKey: dedupKey, createdAt: now()))
    }

    /// A provider acceptance can only transition the exact queued row the sender observed.
    @discardableResult
    public func markHandedOff(cardId: UUID, messageId: UUID, expectedText: String) throws -> Bool {
        try transition(cardId: cardId, messageId: messageId, expectedText: expectedText, to: .handedOff)
    }

    /// A locally exhausted attempt can only fail the exact queued row it attempted.
    @discardableResult
    public func markFailed(cardId: UUID, messageId: UUID, expectedText: String) throws -> Bool {
        try transition(cardId: cardId, messageId: messageId, expectedText: expectedText, to: .failed)
    }

    @discardableResult
    public func retry(cardId: UUID, messageId: UUID) throws -> Bool {
        ensureLoaded()
        guard let index = messages.firstIndex(where: { $0.id == messageId && $0.cardId == cardId }),
              messages[index].state == .failed else { return false }
        try mutatePersistently {
            messages[index] = rebuilding(messages[index], state: .queued)
        }
        return true
    }

    @discardableResult
    public func remove(cardId: UUID, messageId: UUID) throws -> Bool {
        ensureLoaded()
        guard messages.contains(where: { $0.id == messageId && $0.cardId == cardId }) else { return false }
        try mutatePersistently { messages.removeAll { $0.id == messageId && $0.cardId == cardId } }
        return true
    }

    /// Editing requeues a failed row. Provider-accepted history is immutable.
    @discardableResult
    public func edit(cardId: UUID, messageId: UUID, text: String) throws -> Bool {
        ensureLoaded()
        guard let index = messages.firstIndex(where: { $0.id == messageId && $0.cardId == cardId }) else {
            return false
        }
        guard messages[index].state != .handedOff else {
            throw OrchestraError.invalidParams("handed-off inbox history is immutable")
        }
        let old = messages[index]
        try mutatePersistently {
            messages[index] = rebuilding(old, text: text, state: .queued)
        }
        return true
    }

    public func reorder(_ cardId: UUID, orderedIds: [UUID]) throws {
        ensureLoaded()
        let slots = messages.enumerated().filter {
            $0.element.cardId == cardId && $0.element.state != .handedOff
        }
        let current = slots.map(\.element)
        guard !current.contains(where: { $0.state == .failed }) else {
            throw OrchestraError.invalidParams(
                "failed inbox messages must be retried, edited, or removed before reordering"
            )
        }
        guard orderedIds.count == current.count, Set(orderedIds) == Set(current.map(\.id)) else {
            throw OrchestraError.invalidParams("orderedIds must be a permutation of the card's unresolved message ids")
        }
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        try mutatePersistently {
            for (slot, message) in zip(slots.map(\.offset), orderedIds.map { byId[$0]! }) {
                messages[slot] = message
            }
        }
    }

    private func transition(cardId: UUID, messageId: UUID, expectedText: String,
                            to state: InboxMessageState) throws -> Bool {
        ensureLoaded()
        guard let index = messages.firstIndex(where: {
            $0.id == messageId && $0.cardId == cardId && $0.text == expectedText && $0.state == .queued
        }) else { return false }
        try mutatePersistently {
            messages[index] = rebuilding(messages[index], state: state)
            if state == .handedOff { trimHandedOffHistory(for: cardId) }
        }
        return true
    }

    private func rebuilding(_ message: InboxMessage, text: String? = nil,
                            state: InboxMessageState? = nil) -> InboxMessage {
        InboxMessage(id: message.id, cardId: message.cardId, text: text ?? message.text,
                     source: message.source, dedupKey: message.dedupKey, createdAt: message.createdAt,
                     state: state ?? message.state)
    }

    private func trimHandedOffHistory(for cardId: UUID) {
        let history = messages.indices.filter {
            messages[$0].cardId == cardId && messages[$0].state == .handedOff
        }
        let excess = history.count - Self.handedOffHistoryCap
        guard excess > 0 else { return }
        for index in history.prefix(excess).reversed() { messages.remove(at: index) }
    }

    private func ensureLoaded() {
        if !loaded { _ = load() }
    }

    private func mutatePersistently(_ mutation: () throws -> Void) throws {
        let previous = messages
        do {
            try mutation()
            try persist()
        } catch {
            messages = previous
            throw error
        }
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(InboxEnvelope(messages: messages))
        let url = URL(fileURLWithPath: path)
        let temporary = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
