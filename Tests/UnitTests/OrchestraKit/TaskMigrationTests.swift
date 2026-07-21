import Foundation
import Testing
import OrchestraKit
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

    // NOTE: the `.dead(.completed)` legacy-migration tests were removed with the migration itself.
    // `DeadReason.completed` is gone as a clean on-disk break (no records to migrate), so a stored
    // `{"phase":{"name":"dead","detail":"completed"}}` record simply fails to decode and is dropped by
    // `FailableTask` — there is no longer a conversion to pin.
}
