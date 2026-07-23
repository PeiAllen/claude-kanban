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
        // S2-6: deterministic among co-located siblings, not an arbitrary `.first`. A total
        // (createdAt, id) order — `createdAt` alone is NOT total, since task dates serialize at
        // second resolution (Coders.swift), so equal-timestamp cards on the same repo/branch would
        // otherwise resolve by snapshot-input order. The id break makes the winner stable.
        return tasks.filter {
            !$0.archived && $0.origin == .worktree && $0.id != task.id
                && $0.repo == task.repo && $0.branch == parent
        }.min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    // MARK: - Board hierarchy (slice 2b): the unified subordinate relation
    //
    // Two axes over the flat `[Task]`, both derived (never stored):
    //   • lineage — a worktree card's `parentBranch` resolves to the card owning that branch
    //     (`parentCard`). This is the CITIZENSHIP axis: what makes a card a column citizen of a scope.
    //   • attachment — a read-only card hangs off a target (branchless: the worktree card sharing its
    //     `cwd`; worktree reviewer: its lineage parent). Attached cards ALWAYS embed (peek), never a
    //     column citizen, so attachment must NOT feed citizenship — hence `lineageParent` is separate
    //     from `hierarchyParent`.
    // `hierarchyParent = attachedTarget ?? lineageParent` is the presentation hop (climb/reveal); a
    // read-write PR child has no attach target and resolves via lineage.

    /// The card a read-only card is attached to: a branchless (borrowed/scratch) reviewer → the oldest
    /// worktree card sharing its `cwd`; a read-only worktree reviewer → its lineage parent. Nil for
    /// read-write cards and read-only cards with no derivable target.
    public static func attachTarget(_ tasks: [Task], of task: Task) -> Task? {
        guard task.access == .readOnly, !task.archived else { return nil }
        if task.origin == .worktree { return parentCard(tasks, of: task) }
        return tasks.filter { $0.id != task.id && $0.origin == .worktree && !$0.archived
                              && $0.cwd == task.cwd }
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// The lineage-only parent (worktree `parentBranch` → owning card). Never the cwd-attach rule —
    /// this is the citizenship axis (`isCitizen ⟺ lineageParent?.id == drillScope`).
    public static func lineageParent(_ tasks: [Task], of task: Task) -> Task? {
        parentCard(tasks, of: task)
    }

    /// One presentation hop upward: the attach target if any, else the lineage parent. Nil ⇒ the card
    /// is its own root (a forest root or standalone).
    public static func hierarchyParent(_ tasks: [Task], of task: Task) -> Task? {
        attachTarget(tasks, of: task) ?? lineageParent(tasks, of: task)
    }

    /// Climb `hierarchyParent` to the top. A rootless card is its own root (returns self). A malformed
    /// lineage (a cycle) has NO real root ⇒ **nil** — the fail-open signal the embedding gate reads to
    /// keep both cards on the board as citizens rather than stranding them (mirrors the shipped
    /// `attachedRoot` contract).
    public static func hierarchyRoot(_ tasks: [Task], of task: Task) -> Task? {
        guard var current = hierarchyParent(tasks, of: task) else { return task }
        var visited: Set<UUID> = [task.id]
        while let next = hierarchyParent(tasks, of: current) {
            guard visited.insert(current.id).inserted else { return nil }  // cycle → no root
            current = next
        }
        guard visited.insert(current.id).inserted else { return nil }
        return current
    }

    /// The DIRECT children of `parent` (one `hierarchyParent` hop away), read-write (lineage) first
    /// then read-only (attached), each group stable by `(createdAt, id)`. Peek renders these as rows.
    /// A child caught in a lineage CYCLE (`hierarchyRoot == nil`) is excluded: it fails open to an
    /// ordinary board citizen (rendered in its own right), so listing it here too would double-render it
    /// (a card AND a peek row) and duplicate it in the `n`/`N` search cycle.
    public static func subordinates(_ tasks: [Task], of parent: Task) -> [Task] {
        let kids = tasks.filter { !$0.archived && $0.id != parent.id
                                  && hierarchyParent(tasks, of: $0)?.id == parent.id
                                  && hierarchyRoot(tasks, of: $0) != nil }
        func byAge(_ a: Task, _ b: Task) -> Bool {
            (a.createdAt, a.id.uuidString) < (b.createdAt, b.id.uuidString)
        }
        return kids.filter { $0.access != .readOnly }.sorted(by: byAge)
             + kids.filter { $0.access == .readOnly }.sorted(by: byAge)
    }

    /// Every descendant of `parent` (full subtree, any depth), cycle-safe. Search reveals matches
    /// anywhere in here regardless of selection. Order is a stable pre-order over `subordinates`.
    public static func descendants(_ tasks: [Task], of parent: Task) -> [Task] {
        var out: [Task] = []
        var visited: Set<UUID> = [parent.id]
        func walk(_ node: Task) {
            for child in subordinates(tasks, of: node) where visited.insert(child.id).inserted {
                out.append(child)
                walk(child)
            }
        }
        walk(parent)
        return out
    }
}
