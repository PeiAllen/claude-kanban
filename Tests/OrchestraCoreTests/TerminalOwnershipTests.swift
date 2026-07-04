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

@Suite("Agent-terminal ownership — state machine")
struct TerminalOwnershipStateTests {
    let card = UUID()
    let ref = "ab12cd"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("drives available → desktopOwned → phoneOwned → desktopOwned with a monotonic epoch")
    func fullDrive() throws {
        var s = TerminalOwnershipStore()
        #expect(s.snapshot(cardId: card, ref: ref, now: t0).owner == nil)          // available
        #expect(s.snapshot(cardId: card, ref: ref, now: t0).epoch == 0)

        let d1 = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0)
        #expect(d1.owner?.ownerKind == .desktop)
        #expect(d1.epoch == 1)

        let p2 = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(p2.owner?.ownerKind == .phone)
        #expect(p2.owner?.clientId == "phone")
        #expect(p2.epoch == 2)

        let d3 = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0)  // Retake
        #expect(d3.owner?.ownerKind == .desktop)
        #expect(d3.epoch == 3)
    }

    @Test("a release by the current epoch+clientId clears the owner; epoch stays monotonic")
    func releaseByCurrent() throws {
        var s = TerminalOwnershipStore()
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        let after = try s.release(cardId: card, ref: ref, clientId: "phone", epoch: a.epoch, now: t0)
        #expect(after.owner == nil)                 // available
        #expect(after.epoch == 1)                   // epoch preserved
        // next takeOver must increment PAST the released epoch
        #expect(s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0).epoch == 2)
    }

    @Test("a stale-epoch release is REJECTED and does not clear the newer owner")
    func staleReleaseRejected() throws {
        var s = TerminalOwnershipStore()
        let p1 = s.takeOver(cardId: card, ref: ref, clientId: "phoneA", kind: .phone, now: t0)  // epoch 1
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phoneB", kind: .phone, now: t0)       // epoch 2 wins
        #expect(throws: OrchestraError.self) {
            _ = try s.release(cardId: card, ref: ref, clientId: "phoneA", epoch: p1.epoch, now: t0)
        }
        // phoneB is still the fresh owner
        let now = s.snapshot(cardId: card, ref: ref, now: t0)
        #expect(now.owner?.clientId == "phoneB")
        #expect(now.epoch == 2)
    }

    @Test("a release with the right epoch but the wrong clientId is REJECTED")
    func wrongClientReleaseRejected() throws {
        var s = TerminalOwnershipStore()
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(throws: OrchestraError.self) {
            _ = try s.release(cardId: card, ref: ref, clientId: "intruder", epoch: a.epoch, now: t0)
        }
    }

    @Test("heartbeat by the current owner refreshes updatedAt and stays fresh")
    func heartbeatRefreshes() throws {
        var s = TerminalOwnershipStore()
        s.heartbeatTimeout = 30
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        let t20 = t0.addingTimeInterval(20)
        let hb = try s.heartbeat(cardId: card, ref: ref, clientId: "phone", epoch: a.epoch, now: t20)
        #expect(hb.stale == false)
        #expect(hb.owner?.updatedAt == t20)
        // 20s after the heartbeat is still inside the 30s window
        #expect(s.snapshot(cardId: card, ref: ref, now: t20.addingTimeInterval(20)).stale == false)
    }

    @Test("a stale-epoch heartbeat is REJECTED")
    func staleHeartbeatRejected() throws {
        var s = TerminalOwnershipStore()
        let p1 = s.takeOver(cardId: card, ref: ref, clientId: "phoneA", kind: .phone, now: t0)
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phoneB", kind: .phone, now: t0)
        #expect(throws: OrchestraError.self) {
            _ = try s.heartbeat(cardId: card, ref: ref, clientId: "phoneA", epoch: p1.epoch, now: t0)
        }
    }

    @Test("an owner with no heartbeat goes stale after the timeout (a phone disconnect)")
    func goesStaleAfterTimeout() throws {
        var s = TerminalOwnershipStore()
        s.heartbeatTimeout = 30
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(29)).stale == false)
        #expect(s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(31)).stale == true)
        // stale, but the owner is NOT cleared — a desktop Force Retake overrides it
        let s31 = s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(31))
        #expect(s31.owner?.ownerKind == .phone)
        let retake = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop,
                                now: t0.addingTimeInterval(31))
        #expect(retake.owner?.ownerKind == .desktop)
        #expect(retake.epoch == 2)
        #expect(retake.stale == false)
    }

    @Test("ownership is per-card: two cards keep independent epochs and owners")
    func perCardIsolation() throws {
        var s = TerminalOwnershipStore()
        let cardB = UUID()
        _ = s.takeOver(cardId: card, ref: "a", clientId: "p1", kind: .phone, now: t0)
        _ = s.takeOver(cardId: card, ref: "a", clientId: "p1", kind: .phone, now: t0)  // epoch 2 on card A
        let b = s.takeOver(cardId: cardB, ref: "b", clientId: "p2", kind: .desktop, now: t0)
        #expect(b.epoch == 1)                                                          // card B independent
        #expect(s.snapshot(cardId: card, ref: "a", now: t0).epoch == 2)
    }
}
