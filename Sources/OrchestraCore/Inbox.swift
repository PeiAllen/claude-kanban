import Foundation

/// One durable inbox message (F3). Conclusions/sends ride the inbox; artifacts ride git.
public struct InboxMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let cardId: UUID
    public let text: String
    public let createdAt: Date
    public init(id: UUID = UUID(), cardId: UUID, text: String, createdAt: Date = Date()) {
        self.id = id; self.cardId = cardId; self.text = text; self.createdAt = createdAt
    }
}

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

    public func enqueue(_ cardId: UUID, _ text: String) throws {
        ensureLoaded()
        messages.append(InboxMessage(cardId: cardId, text: text))
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
