import Foundation
import Testing
@testable import OrchestraCore

@Suite("Task migration — cwd + origin backfill")
struct TaskMigrationTests {
    // Old persisted card: has `worktree`, no `cwd`/`origin`. (ISO-8601 dates to match OrchestraJSON.)
    @Test("legacy card backfills cwd from worktree and origin=.worktree")
    func legacyBackfillsCwdAndOrigin() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"x","titleProvisional":false,"desc":"",
         "repo":"/r/app","branch":"feat","worktree":"/wt/app/feat","agentId":"claude-code",
         "model":"claude-opus-4-8","startIn":"impl","column":"impl","order":0,"status":"running",
         "ctxPct":0,"priorSessionIds":[],"initialPrompt":"go","archived":false,
         "createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}
        """
        let t = try OrchestraJSON.decoder.decode(Task.self, from: Data(legacy.utf8))
        #expect(t.cwd == "/wt/app/feat")
        #expect(t.origin == .worktree)
    }

    @Test("new card round-trips cwd + origin")
    func newTaskRoundtripsCwdAndOrigin() throws {
        let t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        let data = try OrchestraJSON.wire.encode(t)
        let back = try OrchestraJSON.decoder.decode(Task.self, from: data)
        #expect(back.cwd == "/wt/app/feat")
        #expect(back.origin == .worktree)
    }
}
