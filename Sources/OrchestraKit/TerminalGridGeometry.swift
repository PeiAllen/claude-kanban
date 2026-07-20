import Foundation

/// Maps a tap in an iOS SwiftTerm terminal to the on-screen character cell under the finger.
///
/// SwiftTerm's `TerminalView` is a `UIScrollView`, so a gesture's `location(in:)` is in *content* space
/// (y = 0 is the top of the scrollback, not the top of the viewport). `Terminal.getCharData(col:row:)`
/// wants a *screen* row (0 = the first visible line), so the scroll offset is subtracted first. The
/// visible grid fills the viewport, so a cell is the viewport size over the visible column/row count —
/// the very ratio `IOSTerminalView.sendWheel` already trusts to place forwarded mouse events, so a link
/// hit-test and a mouse click agree on which cell a point falls in.
///
/// This lives in OrchestraKit, apart from any UIKit type, so the coordinate arithmetic — the part most
/// likely to be wrong by an off-by-one — is covered by the fast unit tier instead of only the simulator.
public enum TerminalGridGeometry {
    /// Returns the visible `(col, row)` under `contentPoint`, or `nil` when the point falls outside the
    /// grid (scrolled above the top, below the last row, or a degenerate viewport/grid). All values are in
    /// points except `cols`/`rows`, which are the terminal's visible column and row counts.
    public static func screenCell(
        contentX: Double, contentY: Double,
        scrollOffsetX: Double, scrollOffsetY: Double,
        viewportWidth: Double, viewportHeight: Double,
        cols: Int, rows: Int
    ) -> (col: Int, row: Int)? {
        guard cols > 0, rows > 0, viewportWidth > 0, viewportHeight > 0 else { return nil }
        let cellWidth = viewportWidth / Double(cols)
        let cellHeight = viewportHeight / Double(rows)
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        let x = contentX - scrollOffsetX
        let y = contentY - scrollOffsetY
        guard x >= 0, y >= 0 else { return nil }

        let col = Int(x / cellWidth)
        let row = Int(y / cellHeight)
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }
        return (col, row)
    }
}
