import Foundation
import OrchestraKit

/// Advisory inbox RPCs. The daemon owns each row's state; this store only returns the RPC result or
/// refreshes a UI projection after a mutation.
public extension BoardStore {
    /// Queue a fresh user-authored message. A successful RPC means Orchestra durably admitted the row;
    /// provider handoff remains a later advisory state, and model consumption is never claimed.
    @discardableResult
    func send(_ id: UUID, _ message: String) async -> Bool {
        let messageId = UUID()
        do {
            _ = try await client.call("send", .object([
                "ref": .string(id.uuidString),
                "message": .string(message),
                "id": .string(messageId.uuidString),
            ]))
            return true
        } catch {
            toast("Couldn't send message", sub: "\(error)", color: .red)
            return false
        }
    }

    /// List unresolved advisory rows by default, with provider-accepted history only when a UI asks for it.
    func inboxPeek(_ id: UUID, includeHistory: Bool = false) async -> [InboxMessage] {
        (try? await client.call("inbox", .object([
            "ref": .string(id.uuidString),
            "includeHistory": .bool(includeHistory),
        ])).decode([InboxMessage].self)) ?? []
    }

    /// Edit an unresolved advisory row. Editing a failed row requeues it on the daemon.
    func inboxEdit(_ id: UUID, messageId: UUID, text: String) async {
        _ = try? await client.call("inbox-edit", .object([
            "ref": .string(id.uuidString),
            "id": .string(messageId.uuidString),
            "text": .string(text),
        ]))
    }

    /// Remove any advisory row, including immutable handed-off history.
    func inboxRemove(_ id: UUID, messageId: UUID) async {
        _ = try? await client.call("inbox-remove", .object([
            "ref": .string(id.uuidString),
            "id": .string(messageId.uuidString),
        ]))
    }

    /// Give an explicitly failed row a fresh native submission budget.
    func inboxRetry(_ id: UUID, messageId: UUID) async {
        _ = try? await client.call("inbox-retry", .object([
            "ref": .string(id.uuidString),
            "id": .string(messageId.uuidString),
        ]))
    }

    /// Reorder the full unresolved sequence. The daemon rejects a sequence containing a failed row.
    func inboxReorder(_ id: UUID, orderedIds: [UUID]) async {
        _ = try? await client.call("inbox-reorder", .object([
            "ref": .string(id.uuidString),
            "ids": .array(orderedIds.map { .string($0.uuidString) }),
        ]))
    }
}
