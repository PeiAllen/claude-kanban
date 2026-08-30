import Foundation
import Testing
@testable import OrchestraCore   // @_exported re-exports OrchestraKit

@Suite("Lineage model additions — decode defaults + back-compat")
struct LineageModelTests {

    /// A Task that predates the tree feature has no `treeStat` key on the wire; it must still decode,
    /// with treeStat == nil (the `diffStat` decode-default-nil pattern).
    @Test("Task without treeStat → nil on the wire and decodes to nil (back-compat)")
    func taskDecodesWithoutTreeStat() throws {
        let t = Task(title: "t", repo: "/r", branch: "b", cwd: "/r",
                     model: AgentModel(id: "m"), startIn: .plan, column: .plan, order: 0,
                     initialPrompt: "p")            // treeStat defaults nil
        let jv = try JSONValue(encodable: t)
        #expect(jv["treeStat"] == nil)             // a nil optional is omitted from the wire form
        #expect(try jv.decode(Task.self).treeStat == nil)
    }

    @Test("Task round-trips a treeStat")
    func taskRoundTripsTreeStat() throws {
        var t = Task(title: "t", repo: "/r", branch: "b", cwd: "/r",
                     model: AgentModel(id: "m"), startIn: .plan, column: .plan, order: 0,
                     initialPrompt: "p")
        t.treeStat = TreeStat(state: .stale, behind: 2, parentIsRemote: false)
        let back = try JSONValue(encodable: t).decode(Task.self)
        #expect(back.treeStat == TreeStat(state: .stale, behind: 2, parentIsRemote: false))
    }

    // MARK: child-progress wire (slice 4) — decode-with-default + explicit encode

    @Test("TreeStat missing the child-progress keys → mergedChildren/plannedChildren/drained default")
    func treeStatChildFieldsDecodeDefault() throws {
        // A pre-slice-4 TreeStat on the wire has only the parent-facing keys.
        let old = JSONValue.object(["state": .string("stale"), "behind": .int(2),
                                    "parentIsRemote": .bool(false), "nudges": .int(0),
                                    "mergeStalled": .bool(false)])
        let s = try old.decode(TreeStat.self)
        #expect(s.mergedChildren == 0)
        #expect(s.plannedChildren == 0)
        #expect(s.drained == false)
        #expect(s.state == .stale && s.behind == 2)   // old fields still decode
    }

    @Test("TreeStat round-trips the child-progress dimension")
    func treeStatChildFieldsRoundTrip() throws {
        let s = TreeStat(state: .inSync, mergedChildren: 3, plannedChildren: 5, drained: true)
        #expect(try JSONValue(encodable: s).decode(TreeStat.self) == s)
    }

    @Test("SpawnInput decodes with and without base (back-compat); id is a required wire field")
    func spawnInputBaseDecode() throws {
        // `id` is now a REQUIRED wire field (client-minted; no id-less spawn). `base` stays optional.
        let idStr = UUID().uuidString
        let without = try JSONValue.object(["id": .string(idStr), "prompt": .string("p")]).decode(SpawnInput.self)
        #expect(without.base == nil)
        #expect(without.id.uuidString == idStr)
        let with = try JSONValue.object(["id": .string(idStr), "prompt": .string("p"), "base": .string("feature-a")])
            .decode(SpawnInput.self)
        #expect(with.base == "feature-a")
        // An id-less payload must now FAIL to decode (the clean wire break).
        #expect(throws: (any Error).self) {
            _ = try JSONValue.object(["prompt": .string("p")]).decode(SpawnInput.self)
        }
    }

    @Test("TreeSnapshot round-trips through JSONValue")
    func treeSnapshotRoundTrips() throws {
        let node = TreeNode(ref: "orchestra://task/abc", cardId: UUID(), repo: "/r", branch: "child",
                            parent: "parent", parentCardId: nil, children: ["gc"], treeStat: nil)
        let snap = TreeSnapshot(nodes: [node])
        #expect(try JSONValue(encodable: snap).decode(TreeSnapshot.self) == snap)
    }
}
