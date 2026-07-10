import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// Construction helper mirroring `BoardModelPlatformTests`'s `makeModel()` — a `BoardModel` backed by
/// the no-op platform bundle (these tests exercise the rev-gate, not the UI-op seam).
enum TestModel {
    @MainActor static func make() -> BoardModel { BoardModel(platform: .noop) }
}

/// Per-card `rev`-gated apply + reconnect-driven resync (Task 6.3). The gate is PER CARD, not board-
/// global: `rev` is sparse AND non-monotonic in wire order (spawn's deferred emit), so a global cursor
/// would drop a legit lower-rev event for a different card. Resync is driven by `adoptSnapshotRev`
/// (which a reconnect's fresh `boardSnapshot` calls), never by gap size.
@Suite @MainActor struct BoardStoreTests {
    private func makeCard(_ title: String) -> Task {
        Task(title: title, repo: "/repo", branch: "feat/seam",
             cwd: "/repo/.worktrees/feat-seam", model: AgentModel(id: "claude-opus-4-8"),
             startIn: .plan, column: .plan, order: 0, initialPrompt: title)
    }

    @Test func test_staleEventDropped() throws {
        let model = TestModel.make()
        var card = makeCard("v-new")
        model.apply(EventEnvelope(rev: 10, event: .taskUpserted(card)))
        card.title = "v-old"
        model.apply(EventEnvelope(rev: 6, event: .taskUpserted(card)))          // stale ≤ 10 → drop
        #expect(model.tasks.first { $0.id == card.id }?.title == "v-new")
        let other = makeCard("other")
        model.apply(EventEnvelope(rev: 8, event: .taskUpserted(other)))         // lower rev, DIFFERENT card → apply
        #expect(model.tasks.contains { $0.id == other.id })
    }

    @Test func test_revGapTriggersResync() throws {
        let model = TestModel.make()
        let card = makeCard("c")
        model.apply(EventEnvelope(rev: 5, event: .taskUpserted(card)))
        model.adoptSnapshotRev(20)                                              // reconnect → snapshot@20
        model.apply(EventEnvelope(rev: 12, event: .taskUpserted(card)))         // pre-outage stale ≤ 20 → drop
        #expect(model.tasks.first { $0.id == card.id }?.title == "c")
        var newer = card; newer.title = "c2"
        model.apply(EventEnvelope(rev: 25, event: .taskUpserted(newer)))        // post-snapshot → apply
        #expect(model.tasks.first { $0.id == card.id }?.title == "c2")
    }

    // GUARD (sparse-rev contract): a bare forward gap on the LIVE stream applies through — no resync.
    // Structural: apply(_ env:) has no fetch branch, so this documents intent (it cannot fail on the impl).
    @Test func test_forwardGapDoesNotResync() throws {
        let model = TestModel.make()
        let card = makeCard("c")
        model.apply(EventEnvelope(rev: 5, event: .taskUpserted(card)))
        model.apply(EventEnvelope(rev: 99, event: .taskUpserted(card)))         // huge sparse gap, not loss
        #expect(model.tasks.contains { $0.id == card.id })                      // applied through, no fetch
    }
}
