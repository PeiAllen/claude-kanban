import Foundation
import OrchestraKit

/// Board-hierarchy derivations (slice 2b) — the unified subordinate relation over the flat `tasks`
/// array, delegating to the pure `BoardTree` functions so the logic stays unit-testable without a
/// store. Kept out of `BoardStore.swift` (already >750 lines) as a focused extension.
///
/// Two axes (see `BoardTree`): **lineage** (`lineageParent`, the citizenship axis — what makes a card a
/// column citizen of a scope) and **attachment** (read-only cards hanging off a target, which ALWAYS
/// embed). `hierarchyParent = attachTarget ?? lineageParent` is the presentation hop used by the anchor
/// climb, peek reveal, and drill traversal. The scope-aware embedding gate lives in `BoardUX` (desktop);
/// the base store never embeds.
extension BoardStore {
    /// The lineage-only parent (worktree `parentBranch` → owning card). The citizenship axis.
    public func lineageParent(of task: Task) -> Task? { BoardTree.lineageParent(tasks, of: task) }

    /// One presentation hop upward: attach target if any, else lineage parent. Nil ⇒ own root.
    public func hierarchyParent(of task: Task) -> Task? { BoardTree.hierarchyParent(tasks, of: task) }

    /// Climb to the root; self when rootless, **nil on a cycle** (the fail-open signal `isEmbedded` reads).
    public func hierarchyRoot(of task: Task) -> Task? { BoardTree.hierarchyRoot(tasks, of: task) }

    /// DIRECT children (one hop), read-write (lineage) first then read-only (attached). Peek renders these.
    public func subordinates(of parent: Task) -> [Task] { BoardTree.subordinates(tasks, of: parent) }

    /// Every descendant (full subtree, cycle-safe). Search reveals matches anywhere in here.
    public func descendants(of parent: Task) -> [Task] { BoardTree.descendants(tasks, of: parent) }

    /// Whether `task` has any live lineage child — the gate for whether drilling it makes sense (an
    /// attached-reviewer-only card has nothing to re-scope to, so it is not a drill target).
    public func hasLineageChildren(_ task: Task) -> Bool {
        subordinates(of: task).contains { $0.access != .readOnly }
    }
}
