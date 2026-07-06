import Foundation
import Testing
@testable import OrchestraCore

@Suite("Task — cwd + origin round-trip")
struct TaskMigrationTests {
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
