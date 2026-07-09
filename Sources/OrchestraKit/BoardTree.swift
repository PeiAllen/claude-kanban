import Foundation

/// Pure branch-tree layout for the board — no UI, no daemon, fully unit-testable. Mirrors
/// `BoardNavigator`: it operates on the same `[Task]` the board draws. Children indent under
/// their parent **within the same column only** (owner gate); cross-column parent relationships
/// are surfaced by the parent chip + `parentCard(of:)` jump, never a reorder or connector.
public enum BoardTree {
    /// Maximum indent level for nested children (the chip/indent stays legible on narrow cards).
    public static let maxIndent = 3

    /// The card in `cards` that owns `child`'s parent branch (same repo, `branch == parentBranch`),
    /// or nil when the child is parentless, self-parented, or its parent lives outside this column.
    public static func inColumnParent(_ cards: [Task], of child: Task) -> Task? {
        guard let parent = child.parentBranch else { return nil }
        // S2-6: co-located siblings are permitted, so pick the OLDEST match deterministically instead of
        // an arbitrary `.first` (board indentation must be stable across siblings).
        return cards.filter { $0.id != child.id && $0.repo == child.repo && $0.branch == parent }
            .min { $0.createdAt < $1.createdAt }
    }

    /// One column's cards, flattened depth-first so each child directly follows its parent. Roots
    /// (no in-column parent) keep their incoming order; siblings keep theirs. When no card has an
    /// in-column parent the input is returned unchanged (byte-stable vs today). Cycle-safe: a
    /// `visited` set emits every card exactly once, and a defensive final pass sweeps any card a
    /// parent-cycle left unreached.
    public static func ordered(_ cards: [Task]) -> [Task] {
        var childrenOf: [UUID: [Task]] = [:]
        var hasParent: Set<UUID> = []
        for c in cards {
            if let p = inColumnParent(cards, of: c) {
                childrenOf[p.id, default: []].append(c)
                hasParent.insert(c.id)
            }
        }
        if hasParent.isEmpty { return cards }

        var result: [Task] = []
        result.reserveCapacity(cards.count)
        var visited: Set<UUID> = []
        func visit(_ c: Task) {
            guard visited.insert(c.id).inserted else { return }
            result.append(c)
            for child in childrenOf[c.id] ?? [] { visit(child) }
        }
        for c in cards where !hasParent.contains(c.id) { visit(c) }  // roots, original order
        for c in cards { visit(c) }                                  // defensive: cycles / orphans
        return result
    }

    /// Indent level of `task` within its column tree — the number of in-column ancestors, capped at
    /// `maxIndent`. Roots and parentless cards are 0. Cycle-safe (a `visited` set bounds the walk).
    public static func indent(_ cards: [Task], of task: Task) -> Int {
        var depth = 0
        var current = task
        var visited: Set<UUID> = [task.id]
        while let parent = inColumnParent(cards, of: current) {
            guard visited.insert(parent.id).inserted else { break }
            depth += 1
            if depth >= maxIndent { break }
            current = parent
        }
        return min(depth, maxIndent)
    }

    /// The live card to jump to for `task`'s parent branch: an active (non-archived) worktree card
    /// in the same repo whose branch is `task.parentBranch`, across ANY column. Nil when the card
    /// has no parent branch or no live card owns it (bare/archived parent ⇒ chip is a no-op).
    public static func parentCard(_ tasks: [Task], of task: Task) -> Task? {
        guard let parent = task.parentBranch else { return nil }
        // S2-6: deterministic (oldest) among co-located siblings, not an arbitrary `.first`.
        return tasks.filter {
            !$0.archived && $0.origin == .worktree && $0.id != task.id
                && $0.repo == task.repo && $0.branch == parent
        }.min { $0.createdAt < $1.createdAt }
    }
}
