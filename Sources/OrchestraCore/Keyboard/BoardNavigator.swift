import Foundation

/// Pure board-selection movement — no UI, no daemon, fully unit-testable. Operates on the same set
/// of cards the board draws (non-archived worktree cards), grouped into the Plan → Impl → Review
/// columns. Bare `hjkl` selection stays *within* the board; crossing into freeform is a pane focus
/// move handled App-side, so it's deliberately absent here.
public enum BoardNavigator {
    private static let order: [Column] = [.plan, .impl, .review]

    /// The board cards in a column, in display order (matches `BoardModel.cards(in:)`).
    public static func columnCards(_ tasks: [Task], _ col: Column) -> [Task] {
        tasks.filter { $0.column == col && !$0.archived && $0.origin == .worktree }
             .sorted { $0.order < $1.order }
    }

    /// The column of a board card, or nil if it isn't a board card (archived / freeform / unknown).
    public static func columnOf(_ tasks: [Task], _ id: UUID) -> Column? {
        tasks.first { $0.id == id && !$0.archived && $0.origin == .worktree }?.column
    }

    /// New selection after a directional move. `.up`/`.down` move within the column; `.left`/`.right`
    /// move to the same-or-clamped row of the adjacent column. Staying put (returns the same id) when
    /// there's nowhere to go. With no current selection, any move selects the first Plan card.
    public static func move(_ tasks: [Task], selected: UUID?, _ dir: Direction) -> UUID? {
        guard let selected, let col = columnOf(tasks, selected) else {
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

    /// First (`first: true`) or last card of the selected card's column.
    public static func end(_ tasks: [Task], selected: UUID?, first: Bool) -> UUID? {
        guard let selected, let col = columnOf(tasks, selected) else { return selected }
        let cards = columnCards(tasks, col)
        return first ? cards.first?.id : cards.last?.id
    }
}
