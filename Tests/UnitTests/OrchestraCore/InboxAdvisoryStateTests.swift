import Foundation
import Testing
@testable import OrchestraCore

@Suite("Inbox advisory message states")
struct InboxAdvisoryStateTests {
    private static func temporaryPath() -> String {
        NSTemporaryDirectory() + "inbox-advisory-\(UUID().uuidString).json"
    }

    private static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".bak")
    }

    @Test("queued, failed, and handed-off rows survive restart with their metadata")
    func stateAndMetadataSurviveRestart() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        let source = InboxMessageSource.card(id: UUID(), title: "child-review")
        let completedAt = Date(timeIntervalSince1970: 10)
        let failedAt = Date(timeIntervalSince1970: 20)
        let queuedAt = Date(timeIntervalSince1970: 30)

        try await inbox.enqueue(InboxMessage(
            cardId: card,
            text: "completed",
            source: source,
            dedupKey: "completed-key",
            createdAt: completedAt))
        try await inbox.enqueue(InboxMessage(
            cardId: card,
            text: "failed",
            source: .human,
            dedupKey: "failed-key",
            createdAt: failedAt))
        try await inbox.enqueue(InboxMessage(
            cardId: card,
            text: "queued",
            source: .orchestra,
            dedupKey: "queued-key",
            createdAt: queuedAt))

        let completed = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            completed.id, expectedText: completed.text, expectedState: completed.state))
        let failed = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markFailed(
            failed.id, expectedText: failed.text, expectedState: failed.state))

        let restarted = Inbox(path: path)
        let unresolved = await restarted.peek(card)
        let history = await restarted.history(card)

        #expect(unresolved.map(\.text) == ["failed", "queued"])
        #expect(unresolved.map(\.state) == [.failed, .queued])
        #expect(unresolved[0].source == .human)
        #expect(unresolved[0].dedupKey == "failed-key")
        #expect(unresolved[0].createdAt == failedAt)
        #expect(unresolved[1].source == .orchestra)
        #expect(unresolved[1].dedupKey == "queued-key")
        #expect(unresolved[1].createdAt == queuedAt)
        #expect(history.map(\.text) == ["completed"])
        #expect(history[0].state == .handedOff)
        #expect(history[0].source == source)
        #expect(history[0].dedupKey == "completed-key")
        #expect(history[0].createdAt == completedAt)
    }

    @Test("handed-off history is capped without pruning unresolved rows")
    func handedOffHistoryIsBoundedPerCard() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        let count = Inbox.handedOffHistoryCap + 1

        for index in 0..<count {
            try await inbox.enqueue(card, "message-\(index)")
        }
        let rows = await inbox.peek(card)
        for row in rows {
            #expect(try await inbox.markHandedOff(
                row.id, expectedText: row.text, expectedState: row.state))
        }

        let history = await inbox.history(card)
        #expect(history.count == Inbox.handedOffHistoryCap)
        #expect(history.first?.text == "message-1")
        #expect(history.last?.text == "message-\(count - 1)")
        #expect(await inbox.peek(card).isEmpty)
    }

    @Test("a failed head blocks later queued messages")
    func failedHeadBlocksFIFO() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        try await inbox.enqueue(card, "first")
        try await inbox.enqueue(card, "later")

        let first = try #require(await inbox.nextDeliverable(card))
        #expect(first.text == "first")
        #expect(try await inbox.markFailed(
            first.id, expectedText: first.text, expectedState: first.state))

        #expect(await inbox.nextDeliverable(card) == nil)
        #expect(await inbox.peek(card).map(\.state) == [.failed, .queued])
    }

    @Test("retry, edit, and remove each unblock a failed head")
    func unresolvedInterventionsUnblockFIFO() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        try await inbox.enqueue(card, "first")
        try await inbox.enqueue(card, "later")

        let original = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markFailed(
            original.id, expectedText: original.text, expectedState: original.state))
        #expect(try await inbox.retry(original.id))
        let retried = try #require(await inbox.nextDeliverable(card))
        #expect(retried.id == original.id)
        #expect(retried.state == .queued)

        #expect(try await inbox.markFailed(
            retried.id, expectedText: retried.text, expectedState: retried.state))
        #expect(try await inbox.edit(original.id, text: "fixed") == card)
        let edited = try #require(await inbox.nextDeliverable(card))
        #expect(edited.text == "fixed")
        #expect(edited.state == .queued)

        #expect(try await inbox.markFailed(
            edited.id, expectedText: edited.text, expectedState: edited.state))
        #expect(try await inbox.remove(original.id) == card)
        #expect(await inbox.nextDeliverable(card)?.text == "later")
    }

    @Test("handed-off rows are immutable history until removed")
    func handedOffRowsAreImmutableExceptRemove() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        try await inbox.enqueue(card, "accepted")
        let accepted = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            accepted.id, expectedText: accepted.text, expectedState: accepted.state))

        #expect(try await inbox.retry(accepted.id) == false)
        #expect(try await inbox.markFailed(
            accepted.id, expectedText: accepted.text, expectedState: .handedOff) == false)
        await #expect(throws: OrchestraError.self) {
            try await inbox.edit(accepted.id, text: "rewritten")
        }
        #expect(await inbox.history(card).map(\.text) == ["accepted"])
        #expect(await inbox.peek(card).isEmpty)

        #expect(try await inbox.remove(accepted.id) == card)
        #expect(await inbox.history(card).isEmpty)
    }

    @Test("reorder changes only unresolved slots and leaves history in place")
    func reorderOnlyPermutesUnresolvedRows() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        for text in ["history-1", "history-2", "queued-1", "queued-2"] {
            try await inbox.enqueue(card, text)
        }

        let firstHistory = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            firstHistory.id, expectedText: firstHistory.text, expectedState: firstHistory.state))
        let secondHistory = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            secondHistory.id, expectedText: secondHistory.text, expectedState: secondHistory.state))
        let unresolved = await inbox.peek(card)

        try await inbox.reorder(card, orderedIds: Array(unresolved.map(\.id).reversed()))

        #expect(await inbox.peek(card).map(\.text) == ["queued-2", "queued-1"])
        #expect(await inbox.history(card).map(\.text) == ["history-1", "history-2"])
        let moved = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            moved.id, expectedText: moved.text, expectedState: moved.state))
        #expect(await inbox.history(card).map(\.text) == ["history-1", "history-2", "queued-2"])
    }

    @Test("a stale completion cannot change text edited during send")
    func stalePostSendTransitionIsANoop() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        try await inbox.enqueue(card, "old text")
        let sent = try #require(await inbox.nextDeliverable(card))

        #expect(try await inbox.edit(sent.id, text: "new text") == card)
        #expect(try await inbox.markHandedOff(
            sent.id, expectedText: sent.text, expectedState: sent.state) == false)
        #expect(try await inbox.markFailed(
            sent.id, expectedText: sent.text, expectedState: sent.state) == false)

        let current = try #require(await inbox.nextDeliverable(card))
        #expect(current.text == "new text")
        #expect(current.state == .queued)
        #expect(await inbox.history(card).isEmpty)
    }

    @Test("dedup keys suppress unresolved duplicates but not advisory history")
    func dedupOnlySeesUnresolvedRows() async throws {
        let path = Self.temporaryPath(); defer { Self.remove(path) }
        let inbox = Inbox(path: path)
        let card = UUID()
        let original = InboxMessage(cardId: card, text: "first", dedupKey: "same")
        try await inbox.enqueue(original)
        try await inbox.enqueue(InboxMessage(cardId: card, text: "suppressed", dedupKey: "same"))
        #expect(await inbox.peek(card).map(\.text) == ["first"])

        let first = try #require(await inbox.nextDeliverable(card))
        #expect(try await inbox.markHandedOff(
            first.id, expectedText: first.text, expectedState: first.state))
        try await inbox.enqueue(InboxMessage(cardId: card, text: "new", dedupKey: "same"))
        let new = try #require(await inbox.nextDeliverable(card))
        #expect(new.text == "new")

        #expect(try await inbox.enqueueIfUnknown(card, "duplicate id", id: first.id) == false)
        #expect(await inbox.history(card).map(\.id) == [first.id])
        #expect(await inbox.peek(card).map(\.text) == ["new"])
    }

    @Test("a persist failure restores the exact pre-transition rows in memory")
    func persistFailureRollsBackStateTransition() async throws {
        let root = NSTemporaryDirectory() + "inbox-advisory-wall-\(UUID().uuidString)"
        let parent = root + "/store"
        let path = parent + "/inbox.json"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let inbox = Inbox(path: path)
        let card = UUID()
        try await inbox.enqueue(card, "unchanged")
        let pending = try #require(await inbox.nextDeliverable(card))

        // Turn the path's parent into a file after the initial write. The actor still has its loaded
        // row, but the next save fails at createDirectory, which makes this a deterministic rollback seam.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.removeItem(atPath: parent)
        FileManager.default.createFile(atPath: parent, contents: Data())

        await #expect(throws: (any Error).self) {
            _ = try await inbox.markFailed(
                pending.id, expectedText: pending.text, expectedState: pending.state)
        }
        let afterFailure = await inbox.peek(card)
        #expect(afterFailure == [pending])

        try FileManager.default.removeItem(atPath: parent)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        #expect(try await inbox.markFailed(
            pending.id, expectedText: pending.text, expectedState: pending.state))
        #expect(await Inbox(path: path).peek(card).map(\.state) == [.failed])
    }
}
