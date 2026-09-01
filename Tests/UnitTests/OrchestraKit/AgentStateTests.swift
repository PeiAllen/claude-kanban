import Foundation
import Testing
@testable import OrchestraKit

@Suite("Agent state value contract")
struct AgentStateTests {
    @Test("work in flight follows only turn status and automatic resume")
    func workInFlightTruthTable() {
        #expect(AgentState(turnStatus: .running).workInFlight == true)
        #expect(AgentState(turnStatus: .waiting()).workInFlight == false)
        #expect(AgentState(turnStatus: .waiting(.init(resume: .init()))).workInFlight == true)
        #expect(AgentState(turnStatus: .unavailable).workInFlight == nil)
    }

    @Test("human need round-trips every optional provider classification")
    func humanNeedCodableRoundTrip() throws {
        for need: ProviderHumanNeed? in [nil, .unspecified, .permission, .input] {
            let state = AgentState(
                turnStatus: .waiting(.init(resume: .init())),
                activity: .init(text: "Running tests"),
                humanNeed: need
            )

            let data = try JSONEncoder().encode(state)

            #expect(try JSONDecoder().decode(AgentState.self, from: data) == state)
            #expect(state.providerRequiresHuman == (need != nil))
        }
    }

    @Test("a persisted request-array snapshot restarts as unavailable without stale request detail")
    func requestArraySnapshotRestartsUnavailable() throws {
        let legacy = Data(#"""
        {
          "turnStatus": { "name": "running" },
          "activity": { "text": "stale tool" },
          "activeRequests": [
            { "id": "permission-1", "kind": "permission", "prompt": "Allow Bash?" }
          ]
        }
        """#.utf8)

        #expect(try JSONDecoder().decode(AgentState.self, from: legacy)
            == AgentState(turnStatus: .unavailable))
    }

    @Test("turn status has a stable name/detail wire shape")
    func turnStatusWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(TurnStatus.waiting(.init(resume: .init())))

        #expect(String(decoding: data, as: UTF8.self)
            == #"{"detail":{"resume":{}},"name":"waiting"}"#)
    }
}
