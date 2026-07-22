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
    /// reviewer twice — once as a full board card, once as a row. Embedding is the fix. No `/`-search on
    /// iOS (BoardTab is a plain pager), so — unlike desktop's `BoardUX` — no search exemption: `isAttached`
    /// alone is the gate. The base `isEmbedded == false` still governs the not-attached cases.
    override func isEmbedded(_ task: Task) -> Bool { isAttached(task) }

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
