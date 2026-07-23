import SwiftUI
import OrchestraUI
import OrchestraCore

/// The `Nf +A −D` diffstat numbers, in the one formatting every surface that shows them shares —
/// the board card's footer, the inspector's diffstat strip, and the recovery panel's "your work is
/// preserved" block. Callers own their own layout (line limits, truncation, help text, padding),
/// because the row a card footer has to survive is not the row a recovery panel has.
///
/// Colors are semantic tokens (`text3` / `green.text` / `red.text`), so light and dark both track the
/// theme rather than hard-coding a hex per surface.
struct DiffStatNumbers: View {
    @Environment(\.theme) var theme: Theme
    let stat: DiffStat
    /// Drop the file count where horizontal space is the binding constraint (the inspector header) —
    /// `+N −M` is the part that answers "how big is this", and the count stays in the tooltip.
    var showFiles: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if showFiles { Text("\(stat.filesChanged)f").foregroundStyle(theme.text3) }
            Text("+\(stat.insertions)").foregroundStyle(theme.green.text)
            Text("−\(stat.deletions)").foregroundStyle(theme.red.text)
        }
        .font(F.mono(10.5, .medium))
    }
}

/// The sentence form, for `.help(_:)` tooltips — kept beside the view so the two never drift.
func diffStatHelp(_ stat: DiffStat) -> String {
    "\(stat.filesChanged) files changed · +\(stat.insertions) −\(stat.deletions)"
}
