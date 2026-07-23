import Foundation

/// The droppable elements of a board card's **L1 status strip** — the status pill on the left, the
/// quiet cluster (diffstat · treeStat glyph · model) on the right.
///
/// Two things are deliberately absent, because they never drop at any width: the pill's breathing
/// **dot** and its **time-in-state**, and the card **ref** (which lives on its own line entirely).
/// Identity isn't on this line at all — it has its own, so it is never squeezed by a quiet fact.
public enum L1Element: String, CaseIterable, Sendable {
    /// The model, rendered as a dim pill — the least actionable fact, so the first to go.
    case model
    /// The one treeStat slot: `↓N` behind-parent, restack, merge-requested, or merge-stalled.
    case treeGlyph
    /// The status pill's state word ("Running"), leaving the dot and the time-in-state behind.
    case stateWord
    /// The branch diffstat (`Nf +A −D`) — the last quiet fact standing.
    case diffstat
}

/// One rung of the L1 squish ladder: exactly which elements the strip still renders.
///
/// `CardView` walks the ladder through `ViewThatFits(in: .horizontal)`, which picks the first
/// candidate whose *ideal* width fits — so this type owns the ORDER of loss and SwiftUI owns only
/// the measuring. That arrangement holds only while the strip is proposed a concrete width: a
/// `.fixedSize(horizontal: true, …)` anywhere above it makes the proposal nil, every rung then
/// "fits", and the ladder silently pins itself to rung 0 forever.
public struct L1Rung: Equatable, Sendable {
    public let showsDiffstat: Bool
    public let showsStateWord: Bool
    public let showsTreeGlyph: Bool
    public let showsModel: Bool

    public init(showsDiffstat: Bool, showsStateWord: Bool, showsTreeGlyph: Bool, showsModel: Bool) {
        self.showsDiffstat = showsDiffstat
        self.showsStateWord = showsStateWord
        self.showsTreeGlyph = showsTreeGlyph
        self.showsModel = showsModel
    }

    /// The elements this rung still renders — the set form the ladder's monotonicity is stated in.
    public var visible: Set<L1Element> {
        var out: Set<L1Element> = []
        if showsModel { out.insert(.model) }
        if showsTreeGlyph { out.insert(.treeGlyph) }
        if showsStateWord { out.insert(.stateWord) }
        if showsDiffstat { out.insert(.diffstat) }
        return out
    }
}

/// The deterministic squish ladder for a card's L1 strip.
///
/// Width pressure on a card is resolved by an ORDERED DROP, not by whichever text happens to
/// truncate first: the model goes, then the treeStat glyph, then the pill's state word (dot + time
/// remain), and the diffstat is the last quiet fact to leave. The size of a change is what you act
/// on from the board, so it outlives the label that says which agent produced it.
public enum CardL1Layout {
    /// The order of loss. Index 0 is dropped first.
    public static let dropOrder: [L1Element] = [.model, .treeGlyph, .stateWord, .diffstat]

    /// The rung that has dropped the first `n` elements of `dropOrder`. Clamped at both ends, so a
    /// caller can index the ladder without bounds-checking.
    public static func rung(dropping n: Int) -> L1Rung {
        let dropped = Set(dropOrder.prefix(max(0, min(n, dropOrder.count))))
        return L1Rung(
            showsDiffstat: !dropped.contains(.diffstat),
            showsStateWord: !dropped.contains(.stateWord),
            showsTreeGlyph: !dropped.contains(.treeGlyph),
            showsModel: !dropped.contains(.model)
        )
    }

    /// Every rung, widest first — the candidate order `ViewThatFits` walks.
    public static let ladder: [L1Rung] = (0...dropOrder.count).map { rung(dropping: $0) }
}
