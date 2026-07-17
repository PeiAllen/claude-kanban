import Foundation

/// One durable inbox message. Conclusions/sends ride the inbox; artifacts ride git.
///
/// Client-safe value type: it lives in OrchestraKit (not OrchestraCore) because the shared `BoardModel`
/// in OrchestraUI surfaces the inbox editor on both desktop and the future iOS client. The daemon-side
/// `Inbox` actor (persistence) stays in OrchestraCore and consumes this type. (Moved here in F2 for the
/// same reason F1 moved `BoardNavigator`/`TaskRef` — a shared client type the phone model needs.)
public struct InboxMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let cardId: UUID
    public let text: String
    /// Optional idempotency key. When an `enqueue` supplies a `dedupKey`, a pending message already
    /// carrying the same `(cardId, dedupKey)` suppresses the new append — so a crash-then-redrive
    /// (e.g. Teardown's child "parent archived" nudge) never double-delivers. Additive-optional Codable:
    /// absent on legacy records ⇒ nil ⇒ never dedups.
    public let dedupKey: String?
    public let createdAt: Date
    /// In-flight delivery lease, or nil when the message is pending. Additive-optional Codable: legacy
    /// rows decode leaseless. Set only by `Inbox.claim`, cleared by `release`; the message is REMOVED
    /// (never merely unleased) by `confirm`.
    public let lease: DeliveryLease?
    public init(id: UUID = UUID(), cardId: UUID, text: String, dedupKey: String? = nil,
                createdAt: Date = Date(), lease: DeliveryLease? = nil) {
        self.id = id; self.cardId = cardId; self.text = text
        self.dedupKey = dedupKey; self.createdAt = createdAt; self.lease = lease
    }
}
