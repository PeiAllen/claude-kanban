import Foundation
import Testing
@testable import OrchestraCore

@Suite("Agent-terminal ownership — wire types")
struct TerminalOwnershipWireTests {

    @Test("AgentTerminalOwnerState round-trips through the shared JSON codec")
    func stateRoundTrips() throws {
        let card = UUID()
        let owner = AgentTerminalOwner(ownerKind: .phone, clientId: "phone-abc", epoch: 3,
                                       cardId: card, window: "agent",
                                       updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let state = AgentTerminalOwnerState(ref: "ab12cd", cardId: card, window: "agent",
                                            owner: owner, epoch: 3, stale: false)
        let data = try OrchestraJSON.wire.encode(state)
        let back = try OrchestraJSON.decoder.decode(AgentTerminalOwnerState.self, from: data)
        #expect(back == state)
        #expect(back.owner?.ownerKind == .phone)
        #expect(back.owner?.clientId == "phone-abc")
    }

    @Test("an available state encodes owner == null")
    func availableEncodesNull() throws {
        let state = AgentTerminalOwnerState(ref: "x", cardId: UUID(), window: "agent",
                                            owner: nil, epoch: 0, stale: false)
        let data = try OrchestraJSON.wire.encode(state)
        let back = try OrchestraJSON.decoder.decode(AgentTerminalOwnerState.self, from: data)
        #expect(back.owner == nil)
    }

    @Test("Event.agentTerminalOwner survives the same Event codec the stream uses")
    func eventRoundTrips() throws {
        let state = AgentTerminalOwnerState(ref: "x", cardId: UUID(), window: "agent",
                                            owner: nil, epoch: 0, stale: false)
        let event = Event.agentTerminalOwner(state)
        let data = try OrchestraJSON.wire.encode(event)
        let back = try OrchestraJSON.decoder.decode(Event.self, from: data)
        #expect(back == event)
    }
}
