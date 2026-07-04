import Foundation
import OrchestraKit

// Pure, view-free logic for the Board pager (M1). Kept separate from the SwiftUI views so it is unit
// testable: page ordering + titles, the freeform/lifecycle-column mapping, card move targets, and the
// Activity feed's Live/CLI filter. The views (`BoardTab`, `ActivityFeedView`) render these decisions.

/// The four full-width pager pages, in swipe order: **Freeform · Plan · Impl · Review** (design §2a).
/// Freeform is the leftmost peer page (active borrowed/scratch agents), distinct from the linear
/// Plan → Review worktree lifecycle. `column` is the backing lifecycle column, or `nil` for Freeform.
public enum BoardPage: Int, CaseIterable, Identifiable, Sendable {
    case freeform, plan, impl, review

    public var id: Int { rawValue }

    /// Short segmented-indicator label (the page header). Deliberately terser than `Column.displayName`
    /// ("Impl" not "Implementation") so four segments + counts fit a phone width.
    public var title: String {
        switch self {
        case .freeform: return "Freeform"
        case .plan:     return "Plan"
        case .impl:     return "Impl"
        case .review:   return "Review"
        }
    }

    /// The lifecycle column this page shows, or `nil` for the freeform page (which shows non-worktree
    /// cards that have no board column).
    public var column: Column? {
        switch self {
        case .freeform: return nil
        case .plan:     return .plan
        case .impl:     return .impl
        case .review:   return .review
        }
    }

    public var isFreeform: Bool { self == .freeform }
}

/// Which lifecycle columns a card can be moved to, given where it is now — every column except its
/// current one (design §2: the "Move to…" context menu). Freeform cards don't move (they have no
/// column and the daemon's `move` guards `origin == .worktree`), so callers pass a `Column` only for
/// worktree cards.
public func moveTargets(from current: Column) -> [Column] {
    Column.allCases.filter { $0 != current }
}

/// The adjacent lifecycle column one step left/right of `current`, or `nil` at the ends — the
/// tap-and-hold → swipe-to-adjacent move (design §2). Order is the board's Plan → Impl → Review.
public func adjacentColumn(from current: Column, movingRight: Bool) -> Column? {
    let order = Column.allCases                 // [.plan, .impl, .review]
    guard let i = order.firstIndex(of: current) else { return nil }
    let j = movingRight ? i + 1 : i - 1
    return order.indices.contains(j) ? order[j] : nil
}

/// The Activity feed's Live/CLI filter (design §5). **Live** = events originating in the app / agents /
/// daemon (the live board); **CLI** = the `cli` source. MCP rides with Live (it's another live surface,
/// not a human typing at a terminal).
public enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case live, cli

    public var id: String { rawValue }
    public var title: String { self == .live ? "Live" : "CLI" }

    public func matches(_ item: ActivityItem) -> Bool {
        switch self {
        case .cli:  return item.source == .cli
        case .live: return item.source != .cli
        }
    }
}
