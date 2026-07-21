import Foundation
import Testing
@testable import OrchestraKit

@Suite("B1 · Delivery lease types")
struct DeliveryLeaseTypeTests {
    @Test("a lease-less message round-trips and decodes from a legacy row (no lease key)")
    func leaselessRowsDecode() throws {
        // NB: OrchestraJSON is iso8601-dated (Coders.swift) — a numeric createdAt would NOT decode.
        let legacy = #"{"id":"\#(UUID().uuidString)","cardId":"\#(UUID().uuidString)","text":"hi","createdAt":"2020-01-01T00:00:00Z"}"#
        let msg = try OrchestraJSON.decoder.decode(InboxMessage.self, from: Data(legacy.utf8))
        #expect(msg.lease == nil)
        #expect(msg.text == "hi")
    }

    @Test("a lease round-trips including the B3-owned watermark fields")
    func leaseRoundTrips() throws {
        let lease = DeliveryLease(token: UUID(), route: .relaunchSeed, epoch: 3,
                                  leasedAt: Date(timeIntervalSince1970: 100),
                                  tailWatermark: 4096, tailPath: "/tmp/r.jsonl")
        let msg = InboxMessage(cardId: UUID(), text: "m", lease: lease)
        let back = try OrchestraJSON.decoder.decode(
            InboxMessage.self, from: try OrchestraJSON.pretty.encode(msg))
        #expect(back.lease == lease)
        #expect(back.lease?.route == .relaunchSeed)
    }
}
