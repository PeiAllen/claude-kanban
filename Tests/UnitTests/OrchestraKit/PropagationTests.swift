import Foundation
import Testing
@testable import OrchestraKit

@Suite("Propagation — Kit types")
struct PropagationTests {
    @Test("PropagationPolicy raw values round-trip", arguments: [
        (PropagationPolicy.tracked, "tracked"),
        (PropagationPolicy.shared, "shared"),
        (PropagationPolicy.ephemeral, "ephemeral"),
    ])
    func rawValueRoundTrip(policy: PropagationPolicy, raw: String) throws {
        #expect(policy.rawValue == raw)
        #expect(PropagationPolicy(rawValue: raw) == policy)

        let data = try OrchestraJSON.pretty.encode(policy)
        let decoded = try OrchestraJSON.decoder.decode(PropagationPolicy.self, from: data)
        #expect(decoded == policy)
    }

    @Test("PropagationPolicy.allCases covers exactly the three values")
    func allCases() {
        #expect(Set(PropagationPolicy.allCases) == [.tracked, .shared, .ephemeral])
    }

    @Test("PropagationItem round-trips through Codable")
    func itemRoundTrip() throws {
        let item = PropagationItem(name: "claude", paths: ["CLAUDE.md", ".claude"], exclusions: [".claude/skills"])
        let data = try OrchestraJSON.pretty.encode(item)
        let decoded = try OrchestraJSON.decoder.decode(PropagationItem.self, from: data)
        #expect(decoded == item)
    }

}
