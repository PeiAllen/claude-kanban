import SwiftUI
import OrchestraUI

/// The SOLID amber "needs you" chip — the one saturated element on a board card.
///
/// Used at every attention surface so they are visually identical: the L1 own chip (which replaces the
/// quiet cluster), the L4 descendants-only rollup, and the drill banner's root chip. Its text is
/// composed by the pure `Attention.chipText` / `Attention.subtreeChipText`, so what it says is decided
/// (and tested) in the model, not here.
///
/// It never truncates and never wraps: an attention chip that got squeezed into "stall…" would be
/// worse than useless, so it is the one thing on the strip that holds its width at every rung.
struct AttentionChip: View {
    @Environment(\.theme) var theme: Theme
    let text: String
    /// Spoken form. The own chip reads "Needs you: permission"; the subtree chip's text is already a
    /// sentence ("2 need you"), so prefixing it would say "Needs you: 2 need you".
    var accessibilityText: String? = nil

    var body: some View {
        Text(text)
            .font(F.ui(9.5, .semibold))
            .tracking(0.2)
            .foregroundColor(theme.attentionChipText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(theme.attentionChipFill))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(accessibilityText ?? "Needs you: \(text)")
    }
}
