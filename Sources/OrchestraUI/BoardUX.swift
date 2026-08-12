import SwiftUI
import OrchestraKit

/// The inspector's Agent vs Diff pane, tracked per card by `BoardUX.inspectorModeByCard` and by the
/// desktop `InspectorView`. A pure value type in the board's public API (`CopyTarget`/`GoTarget` are the
/// OrchestraKit-side siblings); folded here from the former 6-line BoardModelTypes.swift. Left outside the
/// `#if os(macOS)` fence to preserve its unconditional visibility.
/// The inspector's pane: the live agent terminal, the read-only diff, or the document reader.
public enum InspectorMode: CaseIterable { case agent, diff, documents

    /// `d` CYCLES rather than toggles. With three panes a two-way toggle strands one of them — from
    /// `.notes` it would land on `.agent` and no key would ever reach the reader.
    public var next: InspectorMode {
        switch self { case .agent: .diff; case .diff: .documents; case .documents: .agent }
    }
}

// The DESKTOP-ONLY UX layer split out of the old 1,159-line BoardModel (Lens-1 HIGH). `BoardStore` is the
// cross-platform daemon sync core; `BoardUX` adds the macOS keyboard navigation, command palette, link
// hints, `/` search, and `UserDefaults` pane-resize — all dead weight on the phone, so the whole type is
// `#if os(macOS)`-fenced and never compiled into the iOS app (which binds to `BoardStore` directly via the
// per-platform `BoardModel` typealias). The bodies are unchanged from the pre-split BoardModel: they call
// the inherited sync-core actions (`move`, `archive`, `closeShell`, …) and read inherited state
// (`tasks`, `selectedId`, `platform`, …).

#if os(macOS)
@MainActor
public final class BoardUX: BoardStore {

    // Keyboard-navigation state (see docs/07-app-ui.md, § Keyboard navigation).
    @Published public var focusZone: FocusZone = .board {
        didSet {
            // A committed `/` search bar stays up so `n`/`N` cycle matches while you browse the board.
            // But once focus descends into a card (terminal/shell) it can't be Esc-dismissed anymore
            // (Esc belongs to the pty), and `n`/`N` no longer apply — so the search has served its
            // purpose. Clear it the moment focus leaves the board so the bar never strands itself.
            if focusZone != .board, searchQuery != nil { searchQuery = nil }
        }
    }
    @Published public var showHelp = false
    /// Non-nil while the `/` card filter is active; the empty string means "field open, no query yet".
    @Published public var searchQuery: String? = nil

    // MARK: drill scope (slice 2b) — pure app-local view state

    /// The root whose subtree the board is currently scoped to, or `nil` at the top level. Drilling
    /// re-homes the columns to one root's direct children (`isEmbedded` reads this). The drilled root
    /// itself leaves the columns (it becomes the `DrillBanner`). Recursive: a nested drill points this
    /// deeper. Purely app-local — nothing daemon-side, no persistence.
    @Published public private(set) var drillScope: UUID? = nil
    /// The durable identity of the drilled root: its `(repo, branch)`. The root's *branch* is the thing
    /// that persists across card succession (planning card → orchestrator), so the reaper re-resolves
    /// `drillScope` from this key whenever `tasks` changes — surviving the owning card being replaced,
    /// and clearing the scope only when no live card owns the branch. See `reapDrillScope`.
    private var drillScopeKey: BranchKey?
    struct BranchKey: Hashable { let repo: String; let branch: String }
    /// The inspector's Agent/Diff mode, kept *per card* (keyed by task id) so switching cards preserves
    /// each card's own choice instead of carrying one global mode everywhere. Defaults to `.agent`.
    @Published public var inspectorModeByCard: [UUID: InspectorMode] = [:]
    /// The selected card's Agent/Diff mode. Hoisted here so the `d` verb can toggle it from the board;
    /// reads/writes route through `inspectorModeByCard` for the current selection.
    public var inspectorMode: InspectorMode {
        get { selectedId.flatMap { inspectorModeByCard[$0] } ?? .agent }
        set { if let id = selectedId { inspectorModeByCard[id] = newValue } }
    }
    /// A one-shot pulse the inspector observes to open its Inbox popover (from the `I` verb).
    @Published public var requestInboxOpen = false
    /// The `:` command palette overlay.
    @Published public var showPalette = false
    /// `f` link-hint mode: labels overlaid on cards; typing a label jumps to it.
    @Published public var hintActive = false
    @Published public var hintLabels: [UUID: String] = [:]
    /// Browser-style card visit history. Traversal suppresses the selection callback so moving the
    /// cursor does not record a fresh visit and accidentally truncate its own forward branch.
    private var cardNavigationHistory = CardNavigationHistory()
    private var replayingCardNavigationHistory = false

    // MARK: keyboard-navigation intents
    // Thin executors the KeyboardController calls; selection movement delegates to the pure
    // BoardNavigator, everything else reuses the existing daemon-backed actions above.

    /// `j`/`k` — the ONLY card-to-card axis. Anchors through `cardLevelAnchor` so a move from an
    /// embedded attached row steps off the row's VISIBLE target (never falls through to first-Plan);
    /// a normal card anchors to itself, so this is identical to before for un-attached selections.
    public func selectMove(_ dir: Direction) {
        selectedId = BoardNavigator.move(visibleTasks, selected: cardLevelAnchor(selectedId), dir)
    }
    /// `gg`/`G` — first/last card of the selection's column. Anchored like `selectMove` so it acts on
    /// the row's visible target column when an embedded attached row is selected (else it would find no
    /// column for the hidden row and silently no-op).
    public func selectEnd(first: Bool) {
        selectedId = BoardNavigator.end(visibleTasks, selected: cardLevelAnchor(selectedId), first: first)
    }

    /// Desktop reveal gate (slice 2b): a root expands its subordinate rows when it (or one of its
    /// descendants) is selected — `revealsPeek`, generic over lineage children AND attached reviewers,
    /// not attached-only — OR when a `/` search is active and a descendant matches (so the match surfaces
    /// in place). Both the render and the `↑`/`↓` walk read this, so they never disagree.
    override func showsInlineRows(_ target: Task) -> Bool {
        revealsPeek(target) || revealsSearchMatchRow(target)
    }

    /// The `↑`/`↓` walk sequence — a SINGLE group, never crossing cards: the anchor card followed by
    /// its own revealed peek rows (lineage children + attached reviewers, flattened). `expandedRows`
    /// carries the `showsInlineRows` gate, so a card with no revealed rows yields a 1-element list ⇒
    /// arrows clamp/no-op. Empty when nothing is selected.
    func groupSequence() -> [UUID] {
        guard let anchorId = cardLevelAnchor(selectedId),
              let anchor = tasks.first(where: { $0.id == anchorId }) else { return [] }
        return [anchorId] + expandedRows(for: anchor).map(\.id)
    }

    // MARK: peek rows (slice 2b) — the generalized inline-row reveal

    /// The ids on the path from the current selection up to its forest root (the selection plus its
    /// hierarchy ancestors), cycle-safe — the `insert(_).inserted` guard also breaks a malformed cycle.
    /// A subtree in the peek list expands exactly when its node is in this set.
    private func selectionAncestry() -> Set<UUID> {
        guard let sel = selectedId, var cur = tasks.first(where: { $0.id == sel }) else { return [] }
        var set: Set<UUID> = [cur.id]
        while let p = hierarchyParent(of: cur), set.insert(p.id).inserted { cur = p }
        return set
    }

    /// `target`'s peek rows should be revealed: it has subordinates AND it is on the selection's ancestry
    /// (itself selected, or an ancestor of the selected card — including a selected attached reviewer or a
    /// selected deep descendant). Generic replacement for the attached-only `revealsAttached`.
    public func revealsPeek(_ target: Task) -> Bool {
        guard !subordinates(of: target).isEmpty else { return false }
        return selectionAncestry().contains(target.id)
    }

    /// The subordinate rows to render inside `target`, each with an indent DEPTH. Direct children at
    /// depth 0; a child expands its OWN subordinates one level deeper iff it is on the selection path (or,
    /// under `/` search, on the path to a match). A stable pre-order flatten, cycle-safe — so
    /// `groupSequence`/`moveRow` walk the list and the depth only drives indentation.
    public func peekRows(of target: Task) -> [(task: Task, depth: Int)] {
        guard showsInlineRows(target) else { return [] }
        let expand = selectionAncestry().union(searchExpansionAncestry())
        var rows: [(task: Task, depth: Int)] = []
        var visited: Set<UUID> = [target.id]
        func add(_ node: Task, _ depth: Int) {
            for child in subordinates(of: node) where visited.insert(child.id).inserted {
                rows.append((task: child, depth: depth))
                if expand.contains(child.id) { add(child, depth + 1) }
            }
        }
        add(target, 0)
        return rows
    }

    /// Desktop replaces the base attached-only `expandedRows` with the full subordinate set (lineage +
    /// attached), so `groupSequence` and any `[Task]` consumer walk the whole peek group. iOS keeps the
    /// base (attached-only) — it has no scope/peek yet (slice 5).
    override public func expandedRows(for target: Task) -> [Task] {
        peekRows(of: target).map(\.task)
    }

    /// `↑`/`↓` — walk within the selected card's attached-row group only (never between cards; that
    /// stays `j`/`k`). No-op from no selection (arrows aren't a board-entry path) and on a card with no
    /// rows: `moveRow` clamps at both group edges and preserves the selection on an empty sequence.
    public func selectRowMove(_ dir: Direction) {
        selectedId = BoardNavigator.moveRow(groupSequence(), selected: selectedId, dir)
        focusZone = .board
    }

    /// Vim Ctrl-O / Ctrl-I traversal. The keyboard controller supplies the real responder-derived
    /// context so a board traversal stays on the board while a terminal traversal descends into the
    /// destination card's agent terminal through the existing honest-focus path.
    public func navigateCardHistoryBack(fromTerminal: Bool) {
        navigateCardHistory(backward: true, fromTerminal: fromTerminal)
    }

    public func navigateCardHistoryForward(fromTerminal: Bool) {
        navigateCardHistory(backward: false, fromTerminal: fromTerminal)
    }

    private func navigateCardHistory(backward: Bool, fromTerminal: Bool) {
        let validIds = Set((tasks + archived).map(\.id))
        let destination = backward
            ? cardNavigationHistory.back(validIds: validIds)
            : cardNavigationHistory.forward(validIds: validIds)
        guard let destination else { return }

        replayingCardNavigationHistory = true
        defer { replayingCardNavigationHistory = false }
        if fromTerminal {
            selectAndEnterTerminal(destination)
        } else {
            focusZone = .board
            selectedId = destination
        }
    }

    /// Carry the selected card one column left/right (Plan↔Impl↔Review). Over `visibleTasks` so an
    /// embedded (hidden) card can't be silently column-carried — a spatial move only acts on cards the
    /// board actually draws (an embedded card selected via its target's popover no-ops here).
    public func carrySelected(_ dir: Direction) {
        guard let id = selectedId, let col = BoardNavigator.columnOf(visibleTasks, id) else { return }
        let order: [Column] = [.plan, .impl, .review]
        guard let ci = order.firstIndex(of: col) else { return }
        let ti = dir == .left ? ci - 1 : ci + 1
        guard ti >= 0, ti < order.count else { return }
        _Concurrency.Task { await move(id, to: order[ti]) }
    }

    /// The invariant enforcement point: no selected card ⇒ no mounted inspector ⇒ focus belongs to the
    /// board. Every deselect path (inspector ✕, archive, taskRemoved, `closeFrontmost`) clears
    /// `selectedId`, which routes here, so the terminal/shell zone can never strand on a closed inspector.
    /// The keyboard eject path resets `focusZone` itself too; this makes the reset unconditional.
    override func onSelectionCleared() { focusZone = .board }

    override func onSelectionChanged(from oldValue: UUID?, to newValue: UUID?) {
        guard !replayingCardNavigationHistory, let newValue else { return }
        cardNavigationHistory.record(newValue)
    }

    /// Descend the keyboard into the selected card's agent terminal (Enter / i). No-op with no
    /// selection so the focus ring never lights on an empty inspector.
    public func enterTerminalZone() {
        guard selectedId != nil else { return }
        focusZone = .terminal
        _ = platform.window.enterTerminalFocus()
    }

    /// A mouse click on a card selects it AND descends into its agent terminal (matching Enter / i),
    /// so the card glow, the inspector ring, and the real first responder all agree after the click.
    /// Falls back to the board zone when the card has no mounted terminal (e.g. a dead agent showing
    /// RecoveryView), so `focusZone` never claims a terminal that isn't there.
    public func selectAndEnterTerminal(_ id: UUID) {
        let sameCard = selectedId == id
        selectedId = id
        focusZone = .terminal
        if sameCard {
            if !platform.window.enterTerminalFocus() { focusZone = .board }   // already mounted → claim now
        } else {
            // Selecting a different card remounts the inspector; its autofocus (focusZone == .terminal)
            // claims focus on mount. Re-assert once that terminal view exists, as a fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                if !self.platform.window.enterTerminalFocus() { self.focusZone = .board }
            }
        }
    }

    public func archiveSelected() { if let id = selectedId { _Concurrency.Task { await archive(id) } } }

    /// The keyboard `a` path: don't archive immediately — raise the confirm dialog. Archive is
    /// effectively permanent, and a bare `a` is too easy to fire when focus isn't where you think.
    public func requestArchiveSelected() { if let id = selectedId { archiveConfirm = id } }
    /// ⏎ in the confirm dialog: perform the archive we were holding.
    public func confirmArchive() { if let id = archiveConfirm { archiveConfirm = nil; _Concurrency.Task { await archive(id) } } }
    /// esc / ⌘W in the confirm dialog: back out, archive nothing.
    public func cancelArchive() { archiveConfirm = nil }
    /// A card's title by id (searches board + archived), for confirm-dialog copy. "" if unknown.
    public func cardTitle(_ id: UUID) -> String { (tasks + archived).first { $0.id == id }?.title ?? "" }
    public func openZedSelected() { if let id = selectedId { _Concurrency.Task { await openInZed(id) } } }
    public func openNotesSelected() { if let id = selectedId { _Concurrency.Task { await openNotes(id) } } }

    /// Yank a reference to the selected card to the pasteboard (chat link / tmux target / path / card reference).
    public func copySelected(_ target: CopyTarget) {
        guard let t = selected else { return }
        copy(target, of: t)
    }

    /// Yank a reference to a specific card — the card-reference badge copies the card it sits on, which is
    /// not necessarily the selected one.
    public func copy(_ target: CopyTarget, of t: Task) {
        let s: String
        switch target {
        case .chatLink: s = t.ref()
        case .tmux:     s = "\(t.tmuxSession):agent"
        case .path:     s = t.cwd
        case .id:       s = t.ref(slugging: false)
        }
        platform.clipboard.copy(s)
        toast("Copied", sub: s)
    }

    /// Jump to a region: select the first card of a column / freeform, or open a popover / settings.
    public func goTo(_ target: GoTarget) {
        switch target {
        case .plan:     selectedId = BoardNavigator.columnCards(visibleTasks, .plan).first?.id
        case .impl:     selectedId = BoardNavigator.columnCards(visibleTasks, .impl).first?.id
        case .review:   selectedId = BoardNavigator.columnCards(visibleTasks, .review).first?.id
        case .freeform: selectedId = freeformTasks.first?.id; focusZone = .board
        case .activity: showActivity = true
        case .done:     showDone = true
        case .settings: platform.opener.openSettings()
        }
    }

    /// Cmd-W / Esc "close the frontmost thing," peeling most-transient-first.
    public func closeFrontmost() {
        if archiveConfirm != nil { archiveConfirm = nil; return }   // the confirm dialog is frontmost
        if hintActive { endHint(); return }
        if showHelp { showHelp = false; return }
        if showPalette { showPalette = false; return }
        if showSpawn { showSpawn = false; return }
        if showDone { showDone = false; return }
        if showActivity { showActivity = false; return }
        if searchQuery != nil { searchQuery = nil; return }
        // A focused shell tab closes first.
        if focusZone == .shell, let id = selectedId, let w = selectedShell[id] {
            _Concurrency.Task { await closeShell(id, w) }
            return
        }
        // Keyboard inside the agent terminal → step back out to the board, keeping the card open so you
        // can carry on navigating (this is the Cmd-W path; a live terminal owns plain Esc itself).
        if focusZone != .board {
            focusZone = .board
            platform.window.resignInputFocus()
            return
        }
        // On the board with a card open → close the inspector. Archiving is the `a` verb only, never
        // Esc — now that "board + selection" is the resting state, Esc-to-archive would be a footgun.
        if selectedId != nil { selectedId = nil }
    }

    // MARK: search / hints / resize / collapse

    /// Every visible card in navigation order: Plan → Impl → Review columns, then the freeform dock.
    /// Projects over `visibleTasks` so embedded (attached read-only) cards drop out of keyboard/hint
    /// navigation in lock-step with the board render — and re-appear together under a matching search.
    public var orderedVisibleCards: [Task] {
        BoardNavigator.columnCards(visibleTasks, .plan)
            + BoardNavigator.columnCards(visibleTasks, .impl)
            + BoardNavigator.columnCards(visibleTasks, .review)
            + freeformTasks
    }

    /// Pure per-card search predicate (title / branch / repo substring, case-insensitive). Read
    /// straight off the task — works for an embedded reviewer row too. Shared by `searchMatchIds`,
    /// `isSearchMatch`, and `revealsSearchMatchRow`, all of which read it directly (never via
    /// `isSearchMatch`/`searchMatchIds`) so nothing recurses through `visibleTasks`.
    func matchesSearch(_ t: Task, query: String) -> Bool {
        let q = query.lowercased()
        return t.title.lowercased().contains(q) || t.branch.lowercased().contains(q)
            || (t.repo as NSString).lastPathComponent.lowercased().contains(q)
    }

    /// Ids matching the active `/` query, in board order — each visible card, then its matching attached
    /// rows (embedded reviewers) right after their root. So `n`/`N` cycles hits INCLUDING in-place
    /// reviewer matches; selecting a row hit reveals its target (`revealsAttached`).
    public var searchMatchIds: [UUID] {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return [] }
        var ids: [UUID] = []
        // In a drill, the scope root is the banner (not a visible card), so its OWN attached reviewers —
        // hosted as banner rows — would otherwise be unreachable by search. Surface their matches first.
        for r in drillHostedRows() where matchesSearch(r.task, query: q) { ids.append(r.task.id) }
        for card in orderedVisibleCards {
            if matchesSearch(card, query: q) { ids.append(card.id) }
            // Any DESCENDANT (embedded lineage child or attached reviewer, at any depth) matching the
            // query surfaces under its visible root — a deep grandchild match is reachable via n/N and
            // its ancestor path auto-expands (`searchExpansionAncestry`).
            for d in descendants(of: card) where matchesSearch(d, query: q) {
                ids.append(d.id)
            }
        }
        return ids
    }
    /// True when a search is active and `t` matches — drives the dim of non-matches (cards AND rows).
    /// Read straight off the task via `matchesSearch` (O(1), works for an embedded reviewer row), so it
    /// can't recurse through `searchMatchIds`/`visibleTasks`.
    public func isSearchMatch(_ t: Task) -> Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return true }
        return matchesSearch(t, query: q)
    }

    /// The scope-aware embedding gate (slice 2b). Three rungs, in order:
    ///  1. **Fail open on a malformed lineage.** A cycle has no real root (`hierarchyRoot == nil`) —
    ///     embedding both members would hide each behind the other, so render them as citizens. Subsumes
    ///     the old read-only-cycle guard (`attachedRoot == nil`), now over the unified relation.
    ///  2. **Attached read-only agents ALWAYS embed** (a reviewer is a subcard behind its target — the
    ///     peek row / eye — never a column card), in EVERY scope, even under `/` search (the search
    ///     surfaces it in place via `showsInlineRows`, it does NOT un-embed). This is the invariant the
    ///     plan-review BLOCKER protected: attachment must not become citizenship when we drill the target.
    ///  3. **Lineage citizenship.** A non-attached card is a column citizen of the CURRENT scope iff its
    ///     LINEAGE parent is the scope anchor — at top level (`drillScope == nil`) that's the forest roots
    ///     and standalones; in a drill it's the root's direct children. Deeper descendants and other
    ///     subtrees embed (revealed via peek, or reached by drilling).
    override func isEmbedded(_ task: Task) -> Bool {
        guard hierarchyRoot(of: task) != nil else { return false }   // 1
        if isAttached(task) { return true }                          // 2
        return lineageParent(of: task)?.id != drillScope             // 3
    }

    /// A `/` search is active and some DESCENDANT of `target` (any depth) matches it — the target then
    /// reveals the path to the hit (so it shows in place) and stays undimmed. Pure over task fields.
    public func revealsSearchMatchRow(_ target: Task) -> Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return false }
        return descendants(of: target).contains { matchesSearch($0, query: q) }
    }

    /// Under `/` search, the ancestor ids of every matching card — so a deep match's path auto-expands in
    /// `peekRows` (the root reveals, and each intermediate node expands down to the match). Empty when no
    /// search is active. Cycle-safe.
    private func searchExpansionAncestry() -> Set<UUID> {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return [] }
        var set: Set<UUID> = []
        for t in tasks where !t.archived && matchesSearch(t, query: q) {
            var cur = t
            guard set.insert(cur.id).inserted else { continue }
            while let p = hierarchyParent(of: cur), set.insert(p.id).inserted { cur = p }
        }
        return set
    }
    /// A search filter is active (a non-empty committed query).
    public var searchActive: Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces) else { return false }
        return !q.isEmpty
    }
    public func searchNext() { cycleMatch(+1) }
    public func searchPrev() { cycleMatch(-1) }
    private func cycleMatch(_ step: Int) {
        let ids = searchMatchIds
        guard !ids.isEmpty else { return }
        let cur = selectedId.flatMap { ids.firstIndex(of: $0) }
        let next = cur.map { ($0 + step + ids.count) % ids.count } ?? 0
        selectedId = ids[next]
    }

    // MARK: drill actions (slice 2b)

    /// Re-scope the board to the subtree of `id`. No-op unless the card exists and has ≥1 LINEAGE child:
    /// an attached-reviewer-only card (or a leaf) has nothing to re-scope to, and a drill into it would
    /// just show an empty board — its reviewers are reached by peek, not by drilling.
    public func drillInto(_ id: UUID?) {
        guard let id, let card = tasks.first(where: { $0.id == id }), hasLineageChildren(card) else { return }
        drillScopeKey = BranchKey(repo: card.repo, branch: card.branch)
        drillScope = id
    }

    /// Pop out one scope level: to the drilled root's own parent (deeper drills climb one at a time),
    /// or to the top level at a forest root. Lands the selection on the root we just exited.
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

    /// The card the board is scoped to right now (the `DrillBanner`'s subject), or `nil` at top level.
    public var drillScopeCard: Task? { drillScope.flatMap { id in tasks.first { $0.id == id } } }

    /// The rows the `DrillHeader` hosts inline (slice 2b): the drilled root's OWN direct subordinates that
    /// are embedded in its scope — i.e. its attached reviewers (its lineage children are the board
    /// columns). The root became the banner rather than a peekable card, so hosting them here is the only
    /// way they stay reachable in their target's drill (the reachability invariant). Empty at top level.
    public func drillHostedRows() -> [(task: Task, depth: Int)] {
        guard let root = drillScopeCard else { return [] }
        return subordinates(of: root).filter { isEmbedded($0) }.map { (task: $0, depth: 0) }
    }

    /// Re-resolve `drillScope` from its durable `(repo, branch)` key after any change to `tasks`. Root
    /// identity follows the BRANCH across card succession (planning card → orchestrator), so when the
    /// scoped card is replaced by its successor we retarget to the new owner rather than losing the drill;
    /// when the branch has no live owner at all (root archived / merged away) we clear to the top level so
    /// the board never strands on a scope whose banner card is gone. Public so the reap is directly tested.
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

    /// Reap after a live event (streaming path) and after a wholesale reconcile — `refresh()` assigns
    /// `tasks` directly and never routes through `apply`, so both hooks are required (mirrors iOS).
    override func apply(_ event: Event) {
        super.apply(event)
        reapDrillScope()
    }
    override public func refresh() async {
        await super.refresh()
        reapDrillScope()
    }

    // f link-hints: assign a short label to every visible card; the controller matches typed keys.
    private static let hintAlphabet = Array("asdfghjklqwertyuiopzxcvbnm")
    public func beginHint() {
        let cards = orderedVisibleCards
        guard !cards.isEmpty else { return }
        let a = Self.hintAlphabet
        let width = cards.count <= a.count ? 1 : 2
        var labels: [UUID: String] = [:]
        for (i, c) in cards.enumerated() {
            labels[c.id] = width == 1 ? String(a[i]) : "\(a[i / a.count])\(a[i % a.count])"
        }
        hintLabels = labels
        hintActive = true
    }
    public func endHint() { hintActive = false; hintLabels = [:] }
    /// The card whose hint label exactly equals `typed`, if any.
    public func hintTarget(_ typed: String) -> UUID? { hintLabels.first { $0.value == typed }?.key }

    /// Grow/shrink the focused pane's movable edge (Ctrl-Shift-hjkl), writing the same @AppStorage the
    /// drag handles use so the views update live.
    public func resizeFocusedPane(_ dir: Direction) {
        let d = UserDefaults.standard
        func bump(_ key: String, _ fallback: Double, _ delta: Double, _ lo: Double, _ hi: Double) {
            let cur = d.object(forKey: key) as? Double ?? fallback
            d.set(min(hi, max(lo, cur + delta)), forKey: key)
        }
        switch dir {
        case .left, .right:
            guard selectedId != nil else { return }         // inspector must be open
            bump("inspectorWidth", 392, dir == .left ? 40 : -40, 320, 1000)
        case .up, .down:
            let delta = dir == .up ? 30.0 : -30.0
            if focusZone == .shell || focusZone == .terminal {
                bump("shellPanelHeight", 220, delta, 80, 500)
            } else if !freeformTasks.isEmpty {
                bump("freeformPanelHeight", 208, delta, 140, 620)
            }
        }
    }

    /// Toggle the focused collapsible region (z): the shell panel when a terminal/shell is focused,
    /// else the freeform dock. Writes the same @AppStorage the chevrons use.
    public func toggleCollapseFocused() {
        let key = (focusZone == .shell || focusZone == .terminal) ? "shellMinimized" : "freeformCollapsed"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    // MARK: command palette (:)

    @Published public var paletteQuery = ""
    @Published public var paletteIndex = 0

    public struct PaletteCommand: Identifiable {
        public let id = UUID(); public let title: String; public let keys: String; public let run: () -> Void
    }

    public func openPalette() { paletteQuery = ""; paletteIndex = 0; showPalette = true }

    /// The full command catalogue (label · shortcut · action). Rebuilt each access; closures capture
    /// `self` weakly-enough (transient values) to avoid a retained cycle.
    public func paletteCommands() -> [PaletteCommand] {
        [
            .init(title: "New card", keys: "c") { [self] in spawnDefaultColumn = .plan; showSpawn = true },
            .init(title: "Search cards", keys: "/") { [self] in searchQuery = "" },
            .init(title: "Cycle Agent / Diff / Docs", keys: "d") { [self] in inspectorMode = inspectorMode.next },
            .init(title: "Archive card", keys: "a") { [self] in archiveSelected() },
            .init(title: "View changes in Zed", keys: "o") { [self] in openZedSelected() },
            .init(title: "Open inbox editor", keys: "I") { [self] in requestInboxOpen = true },
            .init(title: "New shell tab", keys: "t") { [self] in if let id = selectedId { _Concurrency.Task { await newShell(id) } } },
            .init(title: "Copy chat link", keys: "y c") { [self] in copySelected(.chatLink) },
            .init(title: "Copy tmux target", keys: "y t") { [self] in copySelected(.tmux) },
            .init(title: "Copy path", keys: "y p") { [self] in copySelected(.path) },
            .init(title: "Copy card reference", keys: "y i") { [self] in copySelected(.id) },
            .init(title: "Go to Plan", keys: "g p") { [self] in goTo(.plan) },
            .init(title: "Go to Implementation", keys: "g i") { [self] in goTo(.impl) },
            .init(title: "Go to Review", keys: "g r") { [self] in goTo(.review) },
            .init(title: "Go to Freeform", keys: "g f") { [self] in goTo(.freeform) },
            .init(title: "Open Activity", keys: "g a") { [self] in showActivity = true },
            .init(title: "Open Done", keys: "g d") { [self] in showDone = true },
            .init(title: "Open Settings", keys: "g s") { [self] in goTo(.settings) },
            .init(title: "Keyboard shortcuts", keys: "?") { [self] in showHelp = true },
        ]
    }

    /// Commands whose title fuzzily matches the query (case-insensitive subsequence).
    public var filteredPaletteCommands: [PaletteCommand] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return paletteCommands() }
        return paletteCommands().filter { fuzzySubsequence(q, $0.title.lowercased()) }
    }

    public func paletteMove(_ delta: Int) {
        let n = filteredPaletteCommands.count
        guard n > 0 else { paletteIndex = 0; return }
        paletteIndex = (paletteIndex + delta + n) % n
    }
    public func runPaletteSelection() {
        let cmds = filteredPaletteCommands
        guard paletteIndex >= 0, paletteIndex < cmds.count else { showPalette = false; return }
        let cmd = cmds[paletteIndex]
        showPalette = false
        cmd.run()
    }

    private func fuzzySubsequence(_ needle: String, _ haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() { if h == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
#endif
