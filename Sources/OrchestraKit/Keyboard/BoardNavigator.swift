import Foundation

/// Pure board-selection movement — no UI, no daemon, fully unit-testable. Operates on the same set
/// of cards the board draws, grouped into the Plan → Impl → Review columns plus the freeform dock.
/// Bare `hjkl` selection stays *within* a region: it moves among the three board columns, or — when a
/// freeform card is selected — among the freeform cards as a flat, clamped list (the dock is an
/// adaptive grid, so 2-D row/column geometry isn't known here). Crossing *between* the board and the
/// freeform dock is a pane-focus move handled App-side (`FocusBridge.movePane`).
public enum BoardNavigator {
    private static let order: [Column] = [.plan, .impl, .review]

    /// The board cards in a column, in display order (matches `BoardModel.cards(in:)`) — tree-grouped
    /// so keyboard `hjkl` walks the same order the board draws.
    public static func columnCards(_ tasks: [Task], _ col: Column) -> [Task] {
        BoardTree.ordered(
            tasks.filter { $0.column == col && !$0.archived && $0.origin == .worktree }
                 .sorted { $0.order < $1.order })
    }

    /// The freeform-dock cards (non-worktree, non-archived), in display order (matches
    /// `BoardModel.freeformTasks`). Oldest-first, so navigation order is stable.
    public static func freeformCards(_ tasks: [Task]) -> [Task] {
        tasks.filter { $0.origin != .worktree && !$0.archived }
             .sorted { $0.createdAt < $1.createdAt }
    }

    /// The first board card in reading order (Plan → Impl → Review), or nil if the board is empty.
    /// Used as the landing spot when climbing out of the freeform dock back onto the board.
    public static func firstBoardCard(_ tasks: [Task]) -> UUID? {
        order.lazy.compactMap { columnCards(tasks, $0).first?.id }.first
    }

    /// The column of a board card, or nil if it isn't a board card (archived / freeform / unknown).
    public static func columnOf(_ tasks: [Task], _ id: UUID) -> Column? {
        tasks.first { $0.id == id && !$0.archived && $0.origin == .worktree }?.column
    }

    /// New selection after a directional move. On the board, `.up`/`.down` move within the column and
    /// `.left`/`.right` move to the same-or-clamped row of the adjacent column. When a freeform card is
    /// selected, all four directions walk the flat freeform list (`.up`/`.left` back, `.down`/`.right`
    /// forward). Staying put (returns the same id) when there's nowhere to go — a move never clears the
    /// selection. With no current selection, any move selects the first Plan card.
    public static func move(_ tasks: [Task], selected: UUID?, _ dir: Direction) -> UUID? {
        guard let selected else { return columnCards(tasks, .plan).first?.id }
        // A freeform card is its own region: navigate the dock as a flat, clamped list.
        let freeform = freeformCards(tasks)
        if let i = freeform.firstIndex(where: { $0.id == selected }) {
            switch dir {
            case .up, .left:    return i > 0 ? freeform[i - 1].id : selected
            case .down, .right: return i < freeform.count - 1 ? freeform[i + 1].id : selected
            }
        }
        guard let col = columnOf(tasks, selected) else {
            return columnCards(tasks, .plan).first?.id
        }
        let cards = columnCards(tasks, col)
        guard let row = cards.firstIndex(where: { $0.id == selected }) else { return selected }
        switch dir {
        case .up:   return row > 0 ? cards[row - 1].id : selected
        case .down: return row < cards.count - 1 ? cards[row + 1].id : selected
        case .left, .right:
            guard let ci = order.firstIndex(of: col) else { return selected }
            let ti = dir == .left ? ci - 1 : ci + 1
            guard ti >= 0, ti < order.count else { return selected }
            let target = columnCards(tasks, order[ti])
            guard !target.isEmpty else { return selected }
            return target[min(row, target.count - 1)].id
        }
    }

    /// Step within a precomputed row-walk `sequence` (a card followed by its revealed attached rows) —
    /// the pure core of the `↑`/`↓` axis. `.up`/`.down` move to the previous/next id, clamped at the
    /// ends (never wraps, never clears). `.left`/`.right` are inert (arrows are a vertical axis). An
    /// EMPTY sequence returns `selected` unchanged, so a no-selection / no-rows group can never blank
    /// the selection. A `selected` absent from a non-empty sequence lands on its first element.
    public static func moveRow(_ sequence: [UUID], selected: UUID?, _ dir: Direction) -> UUID? {
        guard !sequence.isEmpty else { return selected }
        switch dir {
        case .left, .right: return selected
        case .up, .down:
            guard let selected, let i = sequence.firstIndex(of: selected) else { return sequence.first }
            let j = dir == .up ? i - 1 : i + 1
            return (j >= 0 && j < sequence.count) ? sequence[j] : selected
        }
    }

    /// First (`first: true`) or last card of the selected card's region — its column on the board, or
    /// the freeform dock when a freeform card is selected.
    public static func end(_ tasks: [Task], selected: UUID?, first: Bool) -> UUID? {
        guard let selected else { return selected }
        let freeform = freeformCards(tasks)
        if freeform.contains(where: { $0.id == selected }) {
            return first ? freeform.first?.id : freeform.last?.id
        }
        guard let col = columnOf(tasks, selected) else { return selected }
        let cards = columnCards(tasks, col)
        return first ? cards.first?.id : cards.last?.id
    }
}
