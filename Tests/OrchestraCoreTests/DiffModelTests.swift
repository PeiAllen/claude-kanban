import Foundation
import Testing
@testable import OrchestraCore

@Suite("Diff models — DiffStat / DiffBase / Task fields")
struct DiffModelTests {

    @Test("DiffStat round-trips")
    func diffStatRoundtrip() throws {
        let s = DiffStat(filesChanged: 3, insertions: 42, deletions: 7)
        let back = try OrchestraJSON.decoder.decode(DiffStat.self, from: OrchestraJSON.wire.encode(s))
        #expect(back == s)
    }

    @Test("DiffBase round-trips all cases")
    func diffBaseRoundtrip() throws {
        for b in [DiffBase.working, .branch, .parent] {
            let back = try OrchestraJSON.decoder.decode(DiffBase.self, from: OrchestraJSON.wire.encode(b))
            #expect(back == b)
        }
    }

    @Test("Task round-trips diffStat + parentBranch")
    func taskRoundtripsNewFields() throws {
        var t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        t.parentBranch = "main-feature"
        t.diffStat = DiffStat(filesChanged: 2, insertions: 10, deletions: 3)
        let back = try OrchestraJSON.decoder.decode(Task.self, from: OrchestraJSON.wire.encode(t))
        #expect(back.parentBranch == "main-feature")
        #expect(back.diffStat == DiffStat(filesChanged: 2, insertions: 10, deletions: 3))
    }

    @Test("old card with no diffStat/parentBranch decodes to nil (nil-default)")
    func oldCardDecodesToNil() throws {
        // A card persisted before this feature: no diffStat / parentBranch keys.
        let old = """
        {"id":"\(UUID().uuidString)","title":"x","titleProvisional":false,"desc":"",
         "repo":"/r/app","branch":"feat","cwd":"/wt/app/feat","origin":"worktree","access":"readWrite",
         "agentId":"claude-code","model":"claude-opus-4-8","startIn":"impl","column":"impl","order":0,
         "status":"running","ctxPct":0,"priorSessionIds":[],"initialPrompt":"go","archived":false,
         "createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}
        """
        let t = try OrchestraJSON.decoder.decode(Task.self, from: Data(old.utf8))
        #expect(t.diffStat == nil)
        #expect(t.parentBranch == nil)
    }
}
