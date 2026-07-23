import Testing
import Foundation
@testable import OrchestraUI

/// The L1 squish ladder. `CardView` hands these rungs to `ViewThatFits`, so the ORDER of loss is
/// pinned here (SwiftUI only measures); the view itself needs no test.
@Suite struct CardL1LayoutTests {

    /// The spec's order of loss, pinned once: model → glyph → state word → diffstat.
    @Test func test_dropOrderIsTheSpecOrder() {
        #expect(CardL1Layout.dropOrder == [.model, .treeGlyph, .stateWord, .diffstat])
    }

    /// The ladder spans "everything" to "nothing but the dot and the time", one rung per drop.
    @Test func test_ladderSpansFullToBare() {
        #expect(CardL1Layout.ladder.count == CardL1Layout.dropOrder.count + 1)
        #expect(CardL1Layout.ladder.first?.visible == Set(L1Element.allCases))
        #expect(CardL1Layout.ladder.last?.visible.isEmpty == true)
    }

    /// Each rung is a STRICT subset of the one above it — a narrower card can never regain an
    /// element it just dropped, which is what makes the ladder a precedence and not a preference.
    @Test func test_ladderIsStrictlyMonotonic() {
        for (wider, narrower) in zip(CardL1Layout.ladder, CardL1Layout.ladder.dropFirst()) {
            #expect(narrower.visible.isStrictSubset(of: wider.visible))
        }
    }

    /// Out-of-range indices clamp, so the view can walk the ladder without bounds-checking.
    @Test func test_rungClampsAtBothEnds() {
        #expect(CardL1Layout.rung(dropping: -3) == CardL1Layout.ladder.first)
        #expect(CardL1Layout.rung(dropping: 99) == CardL1Layout.ladder.last)
    }

    /// The state word yields before the diffstat: "how big is this change" survives longer than the
    /// word beside a dot that already carries the same state in colour.
    @Test func test_stateWordDropsBeforeDiffstat() {
        let wordGone = CardL1Layout.ladder.firstIndex { !$0.showsStateWord }
        let diffGone = CardL1Layout.ladder.firstIndex { !$0.showsDiffstat }
        #expect(wordGone != nil && diffGone != nil)
        #expect(wordGone! < diffGone!)
    }
}
