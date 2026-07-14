// MOVES-TO: ContractTests/Proc — real gh CLI probe
import Foundation
import Testing
@testable import OrchestraCore

@Suite("GhProbe — PrState decode + capability gate")
struct GhProbeTests {
    @Test("decodes gh pr view JSON (state/mergedAt/baseRefName) → merged")
    func decodeMerged() throws {
        let json = """
        {"state":"MERGED","mergedAt":"2026-07-07T00:00:00Z","mergeCommit":{"oid":"abc123"},"baseRefName":"main"}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(PrState.self, from: json)
        #expect(st.state == "MERGED")
        #expect(st.baseRefName == "main")
        #expect(st.mergeCommit?.oid == "abc123")
        #expect(st.merged)
    }

    @Test("an OPEN PR is not merged")
    func decodeOpen() throws {
        let json = #"{"state":"OPEN","mergedAt":null,"mergeCommit":null,"baseRefName":"main"}"#.data(using: .utf8)!
        let st = try JSONDecoder().decode(PrState.self, from: json)
        #expect(!st.merged)
        #expect(st.baseRefName == "main")
    }

    @Test("GhProbe.available reflects whether gh is on PATH")
    func availabilityGate() {
        #expect(GhProbe().available == Proc.toolExists("gh"))
    }
}
