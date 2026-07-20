import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

@Suite("B4 · ChannelBroker skeleton (starved — nothing parks until D1)")
struct ChannelBrokerTests {

    private func batch() -> ClaimedBatch {
        ClaimedBatch(token: UUID(), ids: [UUID()], payload: "hi")
    }

    @Test("no card is attached — nothing ever parks in B4")
    func nothingAttached() async {
        let b = ChannelBroker()
        #expect(await b.isAttached(UUID(), epoch: 1) == false)
    }

    @Test("push to an unattached card refuses, so wake falls through cold")
    func pushRefusesWhenUnattached() async {
        let b = ChannelBroker()
        #expect(await b.push(UUID(), batch(), epoch: 1) == false)
    }

    @Test("teardown + epoch-revoke are no-ops on an empty broker, never a trap")
    func teardownDutiesAreSafe() async {
        let b = ChannelBroker()
        let id = UUID()
        await b.detachAll(id)
        await b.revokeOlderEpochs(id, epoch: 7)
        await b.detach(connection: UUID())
        #expect(await b.isAttached(id, epoch: 7) == false)
    }
}
