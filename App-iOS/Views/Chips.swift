import SwiftUI
import OrchestraKit
import OrchestraUI

// The phone's chip vocabulary, and the ONE rule every chip obeys.
//
// **The bug this file exists to prevent.** A chip is a `Text` inside a padded `Capsule`. Left alone,
// that `Text` is *flexible*: when the row runs out of width, SwiftUI shrinks the chip toward zero and
// wraps its label character-by-character — "Implementation" becomes a five-line "Im/ple/men/tat/ion"
// tower, and because the row is as tall as its tallest child, ONE starved chip inflates the whole row.
// The row does not overflow, it grows, which is why the symptom reads as "the icons are heightened"
// rather than as clipping. The desktop peek row hit this first and fixed it the same way.
//
// **The rule:** a chip is intrinsically sized — `.lineLimit(1)` so it can never take a second line, and
// `.fixedSize()` so the layout must give it its natural width instead of squeezing it. The squeeze then
// lands on the genuinely flexible zones (title, desc/note), which absorb it by truncating with "…" —
// the correct loss. Every chip below routes through `chipText()`, so the rule is applied in one place
// rather than remembered at each call site.

extension View {
    /// Make a chip label intrinsically sized: one line, natural width, never squeezed into a tall
    /// tower. Apply to the label BEFORE its padding/background so the capsule wraps the real text box.
    func chipText() -> some View { self.lineLimit(1).fixedSize() }
}

/// A solid-amber attention chip — the phone's `AttentionChip`. Colour means state and only state:
/// SATURATED amber is exclusively "needs you", so scanning for solid amber is the rule. Shared by the
/// L1 own-attention chip, the L4 subtree rollup chip, the peek row's action slot, and the drill banner.
struct AttentionChipIOS: View {
    @Environment(\.theme) private var theme: Theme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(theme.attentionChipText)
            .chipText()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(theme.attentionChipFill))
    }
}

/// The stage chip for a lineage child: a stage-tinted pill carrying the column. Two forms, chosen by
/// the caller from its MEASURED width — the word (`IMPL`) when the row has room, else the single letter
/// (`I`), which frees ~30pt so the row's title keeps its first words instead of collapsing to "…".
/// Both spellings come from `Column` (OrchestraKit), shared with the desktop row so they can't drift.
///
/// The stage hue matches the L4 subtree segments (`theme.stageColor`), so a card's chip and its parent's
/// segment for it are one colour.
struct StagePillIOS: View {
    @Environment(\.theme) private var theme: Theme
    let column: Column
    /// `true` ⇒ the word form; `false` ⇒ the single letter. Decided by measured row width, NOT by
    /// `ViewThatFits` — a greedy `layoutPriority` title starves that into always picking the letter.
    var word: Bool = true

    var body: some View {
        let sem = theme.stageColor(column)
        Text(word ? column.shortName : column.letter)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(sem.text)
            .chipText()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(sem.tint))
            .accessibilityLabel(column.displayName)
    }
}

/// A neutral chip for a card with no workflow column (a freeform/borrowed card). Same discipline.
struct FreeformChipIOS: View {
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        Text("freeform")
            .font(.caption2)
            .foregroundStyle(theme.text3)
            .chipText()
    }
}
