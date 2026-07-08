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
    public let createdAt: Date
    public init(id: UUID = UUID(), cardId: UUID, text: String, createdAt: Date = Date()) {
        self.id = id; self.cardId = cardId; self.text = text; self.createdAt = createdAt
    }
}
