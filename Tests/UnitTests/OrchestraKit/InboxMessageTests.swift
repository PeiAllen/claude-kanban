import Foundation
import Testing
@testable import OrchestraKit

@Suite("Inbox message state")
struct InboxMessageStateTests {
    @Test("a legacy row without state decodes as queued")
    func legacyRowsDefaultToQueued() throws {
        // `createdAt` uses OrchestraJSON's ISO-8601 strategy; keep this fixture in the exact durable
        // form written before advisory states existed.
        let legacy = #"{"id":"\#(UUID().uuidString)","cardId":"\#(UUID().uuidString)","text":"still pending","createdAt":"2020-01-01T00:00:00Z"}"#

        let message = try OrchestraJSON.decoder.decode(InboxMessage.self, from: Data(legacy.utf8))

        #expect(message.state == .queued)
        #expect(message.text == "still pending")
    }

    @Test("advisory state round-trips beside delivery metadata")
    func stateRoundTripsBesideExistingMetadata() throws {
        let source = InboxMessageSource.card(id: UUID(), title: "review")
        let message = InboxMessage(
            cardId: UUID(),
            text: "needs attention",
            source: source,
            dedupKey: "review-result",
            createdAt: Date(timeIntervalSince1970: 12_345),
            state: .failed)

        let decoded = try OrchestraJSON.decoder.decode(
            InboxMessage.self,
            from: OrchestraJSON.pretty.encode(message))

        #expect(decoded.state == .failed)
        #expect(decoded.source == source)
        #expect(decoded.dedupKey == "review-result")
        #expect(decoded.createdAt == message.createdAt)
    }
}
