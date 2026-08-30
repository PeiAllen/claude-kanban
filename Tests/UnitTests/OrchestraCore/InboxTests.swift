import Foundation
import Testing
@testable import OrchestraCore

@Suite("Native inbox persistence")
struct InboxTests {
    private static func temporaryPath() -> String {
        NSTemporaryDirectory() + "native-inbox-\(UUID().uuidString).json"
    }

    private static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".bak")
    }

    @Test("queued and provider-accepted rows retain their durable state across restart")
    func persistsQueueAndHistory() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID()
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "accepted", source: .human)
        try await inbox.enqueue(card, "queued", source: .orchestra)

        let accepted = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            cardId: card, messageId: accepted.id, expectedText: accepted.text))

        let restarted = Inbox(path: path)
        #expect(await restarted.history(card).map(\.text) == ["accepted"])
        #expect(await restarted.history(card).map(\.state) == [.handedOff])
        #expect(await restarted.peek(card).map(\.text) == ["queued"])
        #expect(await restarted.peek(card).map(\.state) == [.queued])
    }

    @Test("history is opt-in while a single snapshot preserves inbox order")
    func peekCanIncludeProviderAcceptedHistory() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID()
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "handed off")
        try await inbox.enqueue(card, "queued")

        let first = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            cardId: card, messageId: first.id, expectedText: first.text
        ))

        #expect(await inbox.peek(card).map(\.text) == ["queued"])
        #expect(await inbox.peek(card, includeHistory: true).map(\.text) == ["handed off", "queued"])
    }

    @Test("failed FIFO head blocks later work until the owner retries it")
    func failedHeadBlocksAndRetryRequeues() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID()
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "first")
        try await inbox.enqueue(card, "later")

        let first = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markFailed(cardId: card, messageId: first.id, expectedText: first.text))
        #expect(await inbox.nextDeliverable(card) == nil)

        #expect(try await inbox.retry(cardId: card, messageId: first.id))
        #expect(await inbox.nextDeliverable(card)?.id == first.id)
        #expect(await inbox.peek(card).map(\.state) == [.queued, .queued])
    }

    @Test("a failed row cannot be reordered behind later queued work")
    func failedHeadCannotBeMovedBehindQueuedWork() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID()
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "failed first")
        try await inbox.enqueue(card, "queued later")

        let failed = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markFailed(
            cardId: card, messageId: failed.id, expectedText: failed.text
        ))
        let queued = try #require(await inbox.peek(card).last)

        await #expect(throws: OrchestraError.invalidParams(
            "failed inbox messages must be retried, edited, or removed before reordering"
        )) {
            try await inbox.reorder(card, orderedIds: [queued.id, failed.id])
        }
        #expect(await inbox.peek(card).map(\.text) == ["failed first", "queued later"])
        #expect(await inbox.peek(card).map(\.state) == [.failed, .queued])
    }

    @Test("owner-scoped edits, removals, and reorders cannot affect another card")
    func ownerScopedMutations() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let owner = UUID(), other = UUID()
        try await inbox.enqueue(owner, "one")
        try await inbox.enqueue(owner, "two")
        let ids = await inbox.peek(owner).map(\.id)

        #expect(try await inbox.edit(cardId: other, messageId: ids[0], text: "wrong owner") == false)
        #expect(try await inbox.remove(cardId: other, messageId: ids[0]) == false)
        await #expect(throws: OrchestraError.self) {
            try await inbox.reorder(other, orderedIds: Array(ids.reversed()))
        }
        try await inbox.reorder(owner, orderedIds: Array(ids.reversed()))
        #expect(await inbox.peek(owner).map(\.text) == ["two", "one"])
    }

    @Test("an edited row defeats a stale provider completion by text and state CAS")
    func staleCompletionCannotWinAfterEdit() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID()
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "old")
        let observed = try #require(await inbox.nextDeliverable(card))

        #expect(try await inbox.edit(cardId: card, messageId: observed.id, text: "new"))
        #expect(try await inbox.markHandedOff(
            cardId: card, messageId: observed.id, expectedText: observed.text) == false)
        #expect(await inbox.nextDeliverable(card)?.text == "new")
        #expect(await inbox.history(card).isEmpty)
    }

    @Test("client-minted ids remain idempotent while retained as history")
    func deduplicatesRetriedClientId() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let card = UUID(), id = UUID()
        let inbox = Inbox(path: path)
        #expect(try await inbox.enqueueIfUnknown(card, "once", id: id, source: .human))
        let row = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(cardId: card, messageId: row.id, expectedText: row.text))
        #expect(try await inbox.enqueueIfUnknown(card, "duplicate", id: id, source: .human) == false)
        #expect(await inbox.history(card).map(\.text) == ["once"])
    }
}
