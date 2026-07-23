import Foundation
import OrchestraKit

/// One drawn slot in a card's L4 subtree bar (slice 2b). Colour means workflow stage and only stage:
/// `.merged` green · `.stage(column)` purple/blue/teal (plan/impl/review) · `.todo` a dashed outline.
/// Pure value type — the SwiftUI `SubtreeSegments` view maps each case to a `theme.stageColor` fill.
public enum SegStyle: Equatable {
    case merged
    case stage(Column)
    case todo
}

/// The pure segment model for a card's subtree bar. Deliberately takes the merged/planned counts as
/// OPTIONAL parameters rather than reading `TreeStat`: those fields do not exist on this branch yet (the
/// sibling daemon card owns them), so naming them would not compile. The `SubtreeSegments` view passes
/// `nil` today — the designed DEGRADED MODE: the bar shows one slot per LIVE lineage child, coloured by
/// its column, and grows as children spawn. When the counters land, the view passes them through and the
/// same function prepends green merged slots and pads dashed planned slots — no other change needed.
public enum StageSegment {
    /// Rank a column along the workflow so the bar reads left-to-right as progression.
    private static func rank(_ c: Column) -> Int {
        switch c { case .plan: return 0; case .impl: return 1; case .review: return 2 }
    }

    /// The slots for a subtree: `merged` (if non-nil) green slots first, then one `.stage` slot per live
    /// lineage child (ordered by workflow stage), then — if `planned` exceeds that running total — dashed
    /// `.todo` slots padding up to `planned`. `nil` counters ⇒ live slots only.
    public static func segments(liveChildren: [Task], merged: Int? = nil, planned: Int? = nil) -> [SegStyle] {
        var segs: [SegStyle] = []
        if let merged, merged > 0 { segs += Array(repeating: .merged, count: merged) }
        segs += liveChildren.sorted { rank($0.column) < rank($1.column) }.map { .stage($0.column) }
        if let planned, planned > segs.count {
            segs += Array(repeating: .todo, count: planned - segs.count)
        }
        return segs
    }
}
