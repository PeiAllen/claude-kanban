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

    /// A record persisted before `humanPaced` existed migrates it from `awaitingFirstPrompt`: a
    /// still-provisional "New agent" card decodes human-paced (exempt the moment the field ships, no
    /// relaunch), while an already-prompted card decodes agent-paced and re-derives on its next human turn.
    @Test("a legacy record without humanPaced migrates it from awaitingFirstPrompt")
    func humanPacedMigratesFromAwaitingFirstPrompt() throws {
        func decodeWithoutHumanPaced(awaiting: Bool) throws -> Task {
            let t = Task(title: "x", awaitingFirstPrompt: awaiting, repo: "/r", branch: "b", cwd: "/wt/b",
                         model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                         order: 0, initialPrompt: "go", humanPaced: awaiting)
            let data = try OrchestraJSON.wire.encode(t)
            var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            obj.removeValue(forKey: "humanPaced")   // simulate a pre-field record
            let legacy = try JSONSerialization.data(withJSONObject: obj)
            return try OrchestraJSON.decoder.decode(Task.self, from: legacy)
        }
        #expect(try decodeWithoutHumanPaced(awaiting: true).humanPaced == true)
        #expect(try decodeWithoutHumanPaced(awaiting: false).humanPaced == false)
    }

    // NOTE: the `.dead(.completed)` legacy-migration tests were removed with the migration itself.
    // `DeadReason.completed` is gone as a clean on-disk break (no records to migrate), so a stored
    // `{"phase":{"name":"dead","detail":"completed"}}` record simply fails to decode and is dropped by
    // `FailableTask` — there is no longer a conversion to pin.
}
