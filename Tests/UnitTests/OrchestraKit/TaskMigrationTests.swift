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

    /// IMPORTANT regression: the legacy Bool-bridge `archive()` (PR2/PR3/PR4a) persisted a record WITH a
    /// `phase` key as `.dead(.completed)` + `archived == true`. Post-PR4b that decodes as `.dead`, whose
    /// gate rejects `reopen` (and `.dead → .creatingWorktree` is an illegal edge) — the card could never be
    /// reopened. `Phase.init` now maps the legacy `"completed"` detail directly to the real `.archived`
    /// terminal (rather than via the archived-Bool normalize), so decode never produces `.dead(.completed)`.
    @Test("a legacy .dead(.completed)+archived record with a phase key decodes as .archived")
    func legacyArchivedDeadCompletedNormalizesToArchived() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","phase":{"name":"dead","detail":"completed"},"archived":true}
        """
        let decoded = try OrchestraJSON.decoder.decode(Task.self, from: Data(json.utf8))
        #expect(decoded.phase == .archived(teardownComplete: true))
        #expect(decoded.archived == true)
    }

    /// The data-loss guardrail: a legacy non-archived `.dead(.completed)` record (a finished read-only
    /// reviewer that was never retired) must NOT throw on decode now that `DeadReason.completed` is gone —
    /// `Phase.init` maps the legacy `"completed"` detail to `.archived(teardownComplete:true)` so the card
    /// is kept, not dropped by FailableTask.
    @Test("a legacy non-archived .dead(.completed) record decodes to .archived and is not dropped")
    func legacyCompletedNotArchivedDecodesToArchived() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","phase":{"name":"dead","detail":"completed"},"archived":false}
        """
        let decoded = try OrchestraJSON.decoder.decode(Task.self, from: Data(json.utf8))
        #expect(decoded.phase == .archived(teardownComplete: true))
        #expect(decoded.archived == true)   // the Bool must be synced (see Step 6) — else the card is a dead end
        // …and the synced card is admitted by the reopen gate (mirrors normalizedLegacyArchivedCardIsReopenable):
        let kind = CommandRegistry.gatedKind(of: decoded)
        let reopen = try #require(CommandCatalog.all.first { $0.name == "reopen" })
        #expect(reopen.phaseGate.contains(kind))
    }

    /// End-to-end: the normalized card is REOPENABLE — the `reopen` gate ({archivedPending, archivedComplete})
    /// admits its effective kind, where the un-normalized `.dead` kind was gated out.
    @Test("the normalized legacy-archived card is admitted by the reopen phase gate")
    func normalizedLegacyArchivedCardIsReopenable() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","phase":{"name":"dead","detail":"completed"},"archived":true}
        """
        let decoded = try OrchestraJSON.decoder.decode(Task.self, from: Data(json.utf8))
        let kind = CommandRegistry.gatedKind(of: decoded)
        #expect(kind == .archivedComplete)
        let reopen = try #require(CommandCatalog.all.first { $0.name == "reopen" })
        #expect(reopen.phaseGate.contains(kind))   // admitted (would be rejected for `.dead`)
    }
}
