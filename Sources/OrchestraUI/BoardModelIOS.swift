import Combine
import Foundation
import OrchestraKit

// The iOS UX layer over the cross-platform `BoardStore` sync core — the mirror of the macOS-only
// `BoardUX` (`BoardUX.swift`). Where desktop adds keyboard/palette/search + a selection-driven reveal,
// iOS adds attached-agents embedding, roots/peek/drill, and a TAP-driven inline reveal. It consumes the
// shared hierarchy/attention seams (`hierarchyRoot`/`subordinates`/`ownAttention`/…) and overrides the
// three the base marks "the subclass owns its presentation": `isEmbedded` (scope-aware), `showsInlineRows`
// (tap-toggled), and `expandedRows` (all subordinates, not attached-only).
//
// A subclass (not per-platform `#if`s inside the base) keeps the base a pure no-op for any other
// consumer. Fenced `#if !os(macOS)` to match the `BoardModel` typealias `#else` branch. App-iOS imports
// OrchestraUI NON-`@testable`, so every symbol the app reads is `public`.

#if !os(macOS)
@MainActor
public final class IOSBoardModel: BoardStore {

    // MARK: drill scope (slice 5) — pure app-local view state, mirror of `BoardUX`

    /// The root whose subtree the board is scoped to, or `nil` at the top level. Drilling re-homes the
    /// columns to one root's direct children (`isEmbedded` reads this); the drilled root itself leaves the
    /// columns (it becomes the drill banner). Purely app-local — nothing daemon-side, no persistence.
    @Published public private(set) var drillScope: UUID? = nil
    /// The durable identity of the drilled root: its `(repo, branch)`. The root's *branch* persists across
    /// card succession (planning card → orchestrator), so the reaper re-resolves `drillScope` from this key
    /// whenever `tasks` changes — surviving the owning card being replaced, clearing when no live card owns
    /// the branch. See `reapDrillScope`.
    private var drillScopeKey: BranchKey?
    public struct BranchKey: Hashable { let repo: String; let branch: String }

    // MARK: scope-aware embedding gate (slice 5)

    /// Three rungs, in order (BoardUX's gate minus the `/`-search rung — iOS has no search):
    ///  1. **Fail open on a malformed lineage.** A cycle has no real root (`hierarchyRoot == nil`) —
    ///     embedding both members would hide each behind the other, so render them as citizens (the
    ///     recorded gotcha: never a peek row AND a board citizen; here it keeps a stranded pair reachable).
    ///  2. **Attached read-only agents ALWAYS embed** — a reviewer is a subcard behind its target (peek
    ///     row / eye), in EVERY scope. Attachment must never become citizenship when the target is drilled.
    ///  3. **Lineage citizenship.** A non-attached card is a column citizen of the CURRENT scope iff its
    ///     LINEAGE parent is the scope anchor — at top level (`drillScope == nil`) that's the forest roots
    ///     + standalones (so non-root descendants embed → the roots-only top level); in a drill it's the
    ///     root's direct children. Deeper descendants and other subtrees embed (revealed via peek / drill).
    override func isEmbedded(_ task: Task) -> Bool {
        guard hierarchyRoot(of: task) != nil else { return false }   // 1
        if isAttached(task) { return true }                          // 2
        return lineageParent(of: task)?.id != drillScope             // 3
    }

    // MARK: tap-toggled peek reveal (slice 5) — generalized from attached-only to all subordinates

    /// Target cards whose peek accordion is expanded. Model-level (not view `@State`) so it survives
    /// `LazyVStack` cell recycling on scroll. `private(set)` — only `togglePeek` mutates it.
    @Published public private(set) var expandedPeekTargets: Set<UUID> = []

    /// Whether `task`'s peek accordion is currently expanded.
    public func isPeekExpanded(_ task: Task) -> Bool { expandedPeekTargets.contains(task.id) }

    /// Toggle `task`'s peek, then prune ids whose card has left the board so the set can't leak.
    public func togglePeek(_ task: Task) {
        if expandedPeekTargets.contains(task.id) { expandedPeekTargets.remove(task.id) }
        else { expandedPeekTargets.insert(task.id) }
        expandedPeekTargets.formIntersection(Set(tasks.map(\.id)))
    }

    /// iOS reveals the inline rows via an explicit TAP toggle, NOT `selectedId` (selection drives
    /// full-screen navigation, so a selection-reveal would fire when the board isn't on screen). Gated on
    /// having subordinates so an empty target never "expands" to nothing.
    override func showsInlineRows(_ target: Task) -> Bool {
        isPeekExpanded(target) && !subordinates(of: target).isEmpty
    }

    /// The peek rows: `target`'s DIRECT subordinates (lineage children first, then attached reviewers) —
    /// ONE hop. A deeper descendant (a grandchild, or a reviewer-of-reviewer) is revealed one level down
    /// by tapping the row → its own detail accordion, or by drilling. Never draws a card as both a row and
    /// a board citizen: everything here is embedded (`isEmbedded` true for non-root descendants).
    override public func expandedRows(for target: Task) -> [Task] {
        showsInlineRows(target) ? subordinates(of: target) : []
    }

    /// Drop peek expand ids whose card has left the board OR no longer has subordinates (its children +
    /// reviewers all left), so a removed/archived target can't leak its id and a target that lost then
    /// regained subordinates doesn't silently reopen from stale memory. Public so the reap is directly
    /// testable — asserting the render guard alone would not prove the id was actually dropped.
    public func reapExpandedPeekTargets() {
        expandedPeekTargets = expandedPeekTargets.filter { id in
            tasks.first(where: { $0.id == id }).map { !subordinates(of: $0).isEmpty } ?? false
        }
    }

    // MARK: drill actions (slice 5) — mirror of `BoardUX`

    /// Re-scope the board to the subtree of `id`. No-op unless the card exists and has ≥1 LINEAGE child:
    /// an attached-reviewer-only card (or a leaf) has nothing to re-scope to.
    public func drillInto(_ id: UUID?) {
        guard let id, let card = tasks.first(where: { $0.id == id }), hasLineageChildren(card) else { return }
        drillScopeKey = BranchKey(repo: card.repo, branch: card.branch)
        drillScope = id
    }

    /// Pop out one scope level: to the drilled root's own parent (deeper drills climb one at a time), or to
    /// the top level at a forest root. Lands the selection on the root we just exited.
    public func drillOut() {
        guard let scope = drillScope, let card = tasks.first(where: { $0.id == scope }) else {
            drillScope = nil; drillScopeKey = nil; return
        }
        if let parent = hierarchyParent(of: card) {
            drillScopeKey = BranchKey(repo: parent.repo, branch: parent.branch)
            drillScope = parent.id
        } else {
            drillScope = nil; drillScopeKey = nil
        }
        selectedId = scope
    }

    /// Jump straight to a specific scope on the breadcrumb path (or the top level with `nil`).
    public func setDrillScope(_ id: UUID?) {
        guard let id, let card = tasks.first(where: { $0.id == id }) else {
            drillScope = nil; drillScopeKey = nil; return
        }
        drillScopeKey = BranchKey(repo: card.repo, branch: card.branch)
        drillScope = id
    }

    /// The forest-root → current-scope chain (breadcrumb order), cycle-safe. Empty at the top level.
    public var scopePath: [Task] {
        guard let scope = drillScope, let card = tasks.first(where: { $0.id == scope }) else { return [] }
        var path = [card]
        var current = card
        var visited: Set<UUID> = [card.id]
        while let parent = hierarchyParent(of: current), visited.insert(parent.id).inserted {
            path.insert(parent, at: 0)
            current = parent
        }
        return path
    }

    /// The card the board is scoped to right now (the drill banner's subject), or `nil` at top level.
    public var drillScopeCard: Task? { drillScope.flatMap { id in tasks.first { $0.id == id } } }

    /// The rows the drill banner hosts inline: the drilled root's OWN direct subordinates that are embedded
    /// in its scope — i.e. its attached reviewers (its lineage children are the board columns). The root
    /// became the banner rather than a peekable card, so hosting them here is the only way they stay
    /// reachable in their target's drill. Empty at top level.
    public func drillHostedRows() -> [Task] {
        guard let root = drillScopeCard else { return [] }
        return subordinates(of: root).filter { isEmbedded($0) }
    }

    /// Re-resolve `drillScope` from its durable `(repo, branch)` key after any change to `tasks`. Root
    /// identity follows the BRANCH across card succession (planning card → orchestrator), so a replaced
    /// scoped card retargets to its successor rather than losing the drill; a branch with no live owner
    /// (root archived / merged away) clears to the top level so the board never strands on a gone scope.
    /// Public so the reap is directly tested.
    public func reapDrillScope() {
        guard let key = drillScopeKey else { drillScope = nil; return }
        // Deterministic winner among co-located cards (oldest by (createdAt, id)) — the same total order
        // `BoardTree.parentCard` uses — so a handoff window where two live cards briefly share a
        // (repo, branch) can't flip the banner target across snapshots.
        let owner = tasks.filter {
            !$0.archived && $0.origin == .worktree && $0.repo == key.repo && $0.branch == key.branch
        }.min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        drillScope = owner?.id
        if owner == nil { drillScopeKey = nil }
    }

    // MARK: reap hooks — both the streaming path AND the wholesale reconcile

    /// Reap after a live event (streaming path).
    override func apply(_ event: Event) {
        super.apply(event)
        reapExpandedPeekTargets()
        reapDrillScope()
    }

    /// Reap after a wholesale reconcile. REQUIRED in addition to `apply`: `BoardStore.refresh()` assigns
    /// `tasks` directly from the snapshot and never routes through `apply`, so a card removed while we were
    /// disconnected would otherwise keep its expand id / drill scope across the reconnect.
    override public func refresh() async {
        await super.refresh()
        reapExpandedPeekTargets()
        reapDrillScope()
    }
}
#endif
