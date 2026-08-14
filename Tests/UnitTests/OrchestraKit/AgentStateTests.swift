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

    @Test("agent state round-trips all independent fields")
    func codableRoundTrip() throws {
        let state = AgentState(
            turnStatus: .waiting(.init(resume: .init())),
            activity: .init(text: "Running tests"),
            activeRequests: [
                .init(id: "permission-1", kind: .permission, prompt: "Allow Bash?")
            ]
        )

        let data = try JSONEncoder().encode(state)

        #expect(try JSONDecoder().decode(AgentState.self, from: data) == state)
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
