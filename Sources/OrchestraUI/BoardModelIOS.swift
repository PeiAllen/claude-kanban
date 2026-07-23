import Combine
import Foundation
import OrchestraKit

// The iOS UX layer over the cross-platform `BoardStore` sync core — the mirror of the macOS-only
// `BoardUX` (`BoardUX.swift`). Where desktop adds keyboard/palette/search + a selection-driven reveal,
// iOS adds attached-agents embedding + a TAP-driven inline reveal. It consumes desktop's shared attached
// seam (`attachedRoot`/`attachedAgents`/`expandedRows`/`showsInlineRows`/`isEmbedded`) and overrides only
// the two seams the seam docs mark as "iOS owns its own presentation".
//
// A subclass (not per-platform `#if`s inside the base) keeps the base a pure no-op for any other
// consumer — the same shape the desktop uses. No stored properties beyond the tap-expand set, so it still
// inherits `BoardStore.init(platform:clock:)` and `BoardModel(platform: .ios)` constructs it unchanged.
// Fenced `#if !os(macOS)` to match the `BoardModel` typealias `#else` branch.

#if !os(macOS)
@MainActor
public final class IOSBoardModel: BoardStore {
    /// Embed attached read-only agents behind their target (dropping them from `visibleTasks` → the pager
    /// columns, freeform dock, and tree indentation). REQUIRED, not just cosmetic: `expandedRows`' own doc
    /// warns that the base never embeds, so drawing inline rows WITHOUT embedding would render each
    /// reviewer twice — once as a full board card, once as a row. Embedding is the fix. Gate on
    /// `attachedRoot != nil`, NOT `isAttached`, matching `BoardUX` — the fail-open cycle guard: a malformed
    /// read-only cycle (R1↔R2) has `isAttached == true` but `attachedRoot == nil`; embedding it would hide
    /// every member behind another hidden member AND supply no root to list it as a row, stranding them.
    /// `attachedRoot == nil` keeps such a card a normal board citizen (reachable). No `/`-search on iOS
    /// (BoardTab is a plain pager), so — unlike `BoardUX` — no search exemption is folded in.
    override func isEmbedded(_ task: Task) -> Bool { attachedRoot(of: task) != nil }

    /// Reap expand ids whose card has left the board OR is no longer a target (its reviewers all left), so
    /// a removed/archived target doesn't leak its id (unbounded without a later toggle) and a target that
    /// lost then regained reviewers doesn't silently reopen from stale "expanded" memory. Runs on every
    /// live event — the toggle-time `formIntersection` only fires on a toggle. Cheap (the set is tiny).
    override func apply(_ event: Event) {
        super.apply(event)
        expandedAttachedTargets = expandedAttachedTargets.filter { id in
            tasks.first(where: { $0.id == id }).map { attachedLiveness(of: $0) != nil } ?? false
        }
    }

    /// iOS reveals the inline rows via an explicit TAP toggle, NOT `selectedId`. The shared
    /// `revealsAttached` (which the base `showsInlineRows` uses) is `selectedId`-based, but on iOS
    /// `selectedId` drives full-screen navigation (`navigationDestination(item:)` pushes the card's
    /// detail), so a selection-reveal would fire exactly when the board ISN'T on screen — never visible.
    /// So iOS gates the rows on `isAttachedExpanded` instead. `expandedRows`/inline render read this one
    /// gate. Still requires actual agents so an empty target never "expands" to nothing.
    override func showsInlineRows(_ target: Task) -> Bool {
        isAttachedExpanded(target) && !attachedAgents(of: target).isEmpty
    }

    // MARK: attached-agents inline accordion (iOS: tap-to-expand)

    /// Target cards whose attached-agents accordion is expanded. Model-level (not view `@State`) so it
    /// survives `LazyVStack` cell recycling on scroll. `private(set)` — only `toggleAttachedExpanded`
    /// mutates it.
    @Published public private(set) var expandedAttachedTargets: Set<UUID> = []

    /// Whether `task`'s accordion is currently expanded.
    public func isAttachedExpanded(_ task: Task) -> Bool { expandedAttachedTargets.contains(task.id) }

    /// Toggle `task`'s accordion, then prune ids whose card has left the board so the set can't leak.
    public func toggleAttachedExpanded(_ task: Task) {
        if expandedAttachedTargets.contains(task.id) { expandedAttachedTargets.remove(task.id) }
        else { expandedAttachedTargets.insert(task.id) }
        expandedAttachedTargets.formIntersection(Set(tasks.map(\.id)))
    }
}
#endif
