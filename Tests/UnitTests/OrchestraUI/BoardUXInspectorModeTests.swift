import Testing
import Foundation
import Combine
@testable import OrchestraUI
@testable import OrchestraKit

/// `inspectorMode` is written by a SwiftUI `Picker` binding from inside `InspectorView.body`, so its
/// setter runs DURING a view update. `inspectorModeByCard` is `@Published` on the app-wide model, and
/// `@Published` publishes on every assignment — equal values included. A no-op write therefore
/// invalidates every view observing the model, mid-update, which SwiftUI reports as "Publishing
/// changes from within view updates is not allowed".
///
/// So the setter must be idempotent: an assignment that changes nothing must publish nothing.
@Suite @MainActor struct BoardUXInspectorModeTests {
    private func makeCard() -> Task {
        Task(title: "c", repo: "/repo", branch: "b", cwd: "/repo/wt",
             model: AgentModel(id: "claude-opus-4-8"),
             startIn: .plan, column: .plan, order: 0, initialPrompt: "c")
    }

    /// Counts `objectWillChange` emissions while `body` runs, without a UI.
    private func publishCount(_ model: BoardModel, during work: () -> Void) -> Int {
        var count = 0
        let token = model.objectWillChange.sink { _ in count += 1 }
        work()
        token.cancel()
        return count
    }

    @Test func test_rewritingTheSameModePublishesNothing() throws {
        let model = TestModel.make()
        let card = makeCard()
        model.apply(EventEnvelope(rev: 1, event: .taskUpserted(card)))
        model.selectedId = card.id
        model.inspectorMode = .diff

        // What the Picker does on every update: write back the value already there.
        let n = publishCount(model) { model.inspectorMode = .diff }

        #expect(n == 0, "a no-op inspectorMode write published \(n) change(s)")
        #expect(model.inspectorMode == .diff)
    }

    /// An unset card already READS `.agent`, so writing `.agent` to it changes nothing observable and
    /// must stay silent as well — otherwise the very first Picker echo on every newly selected card
    /// re-enters the update.
    @Test func test_writingTheDefaultToAnUnsetCardPublishesNothing() throws {
        let model = TestModel.make()
        let card = makeCard()
        model.apply(EventEnvelope(rev: 1, event: .taskUpserted(card)))
        model.selectedId = card.id

        let n = publishCount(model) { model.inspectorMode = .agent }

        #expect(n == 0, "writing the default mode to an unset card published \(n) change(s)")
        #expect(model.inspectorMode == .agent)
    }

    @Test func test_realModeChangeStillPublishes() throws {
        let model = TestModel.make()
        let card = makeCard()
        model.apply(EventEnvelope(rev: 1, event: .taskUpserted(card)))
        model.selectedId = card.id
        model.inspectorMode = .agent

        let n = publishCount(model) { model.inspectorMode = .documents }

        #expect(n >= 1, "a real mode change must still publish")
        #expect(model.inspectorMode == .documents)
    }
}
