import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The pure L4 subtree-segment model (slice 2b): live lineage children coloured by stage, with optional
/// merged/planned counters folded in. The counters are PARAMETERS (not `TreeStat` reads) so this builds
/// on a branch where those daemon fields don't exist yet — nil ⇒ the designed live-children-only mode.
@Suite struct StageSegmentTests {
    private func child(_ id: String, _ col: Column) -> Task {
        Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
             title: id, repo: "/r", branch: id, cwd: "/r/\(id)",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col, order: 0,
             phase: .live(.running), initialPrompt: id)
    }

    @Test func planImplReviewMapToStageSlotsInWorkflowOrder() {
        let live = [child("03", .review), child("01", .plan), child("02", .impl)]  // out of order
        #expect(StageSegment.segments(liveChildren: live) == [.stage(.plan), .stage(.impl), .stage(.review)])
    }

    @Test func nilCountersRenderLiveChildrenOnly() {
        let live = [child("01", .impl), child("02", .impl)]
        // No merged (green) and no todo (dashed) slots without the daemon counters — just the live bar.
        #expect(StageSegment.segments(liveChildren: live) == [.stage(.impl), .stage(.impl)])
    }

    @Test func mergedCountPrependsGreenSlots() {
        let live = [child("01", .impl)]
        #expect(StageSegment.segments(liveChildren: live, merged: 2)
                == [.merged, .merged, .stage(.impl)])
    }

    @Test func plannedCountPadsDashedSlots() {
        let live = [child("01", .plan)]
        // planned total of 4: 1 live + 3 dashed placeholders.
        #expect(StageSegment.segments(liveChildren: live, planned: 4)
                == [.stage(.plan), .todo, .todo, .todo])
    }

    @Test func plannedBelowRunningTotalAddsNoPadding() {
        let live = [child("01", .plan), child("02", .impl), child("03", .review)]
        // planned (2) < already-present slots (3) ⇒ never truncates, never negative-pads.
        #expect(StageSegment.segments(liveChildren: live, planned: 2)
                == [.stage(.plan), .stage(.impl), .stage(.review)])
    }

    @Test func mergedAndPlannedCompose() {
        let live = [child("01", .impl)]
        // 2 merged + 1 live = 3 slots; planned 5 ⇒ pad 2 dashed.
        #expect(StageSegment.segments(liveChildren: live, merged: 2, planned: 5)
                == [.merged, .merged, .stage(.impl), .todo, .todo])
    }

    @Test func emptySubtreeIsNoSlots() {
        #expect(StageSegment.segments(liveChildren: []).isEmpty)
    }
}
