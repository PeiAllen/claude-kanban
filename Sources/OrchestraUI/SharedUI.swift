// Shared cross-surface UI helpers — one source of truth for the small formatters and
// view snippets that the macOS desktop (App/) and the iOS phone client (App-iOS/) both need.
// Consolidated here (D9) from per-view copies that had begun to drift; keep new copies out.

import SwiftUI
import OrchestraKit

/// The board's compact `3s`/`4m`/`2h`/`1d` duration ladder — one rung per unit, rolling up at
/// 60s → 60m → 24h. Takes a raw interval so a caller that already holds a duration (the stall
/// timer) renders it in the SAME units as the `Date`-based "time since" stamps, instead of a flat
/// minute count that reads `130m` where every other stamp would say `2h`.
public func compactDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}

/// Relative age like the board's `3s`/`4m`/`2h`/`1d` — the compact "time since" stamp shown on cards,
/// the activity feed, and the agent capture line. One implementation for every surface (was copied
/// five ways: desktop `CardView`, iOS `BoardCardCell`/`NeedsYouTab`/`ActivityFeedView`, and
/// `CardDetailHeader.relativeDetailAge`).
public func relativeAge(_ date: Date, now: Date = Date()) -> String {
    compactDuration(now.timeIntervalSince(date))
}

/// How often a live `relativeAge` stamp needs re-rendering: every second while it still reads in
/// seconds (the first minute), once a minute after that. `relativeAge` never shows a unit finer than
/// minutes past 60s, so a faster tick beyond the first minute is wasted board-wide re-layout, and a
/// slower tick *during* it freezes a card at "· 0s" until the next minute boundary. Phase-independent
/// on purpose: a being-born or dead card ages in seconds exactly like a running one, so keying the
/// cadence off the phase (rather than the age) is what left non-live cards stale for their first minute.
public func ageRefreshInterval(_ date: Date, now: Date = Date()) -> TimeInterval {
    now.timeIntervalSince(date) < 60 ? 1 : 60
}

/// Center content in the available space — `VStack { Spacer; content; Spacer }` filling the frame.
/// The empty/loading-state centering helper that four card panes had each copied verbatim
/// (desktop `DiffInspectorView`, iOS `NotesPage`/`DiffTab`/`TerminalTab`).
@ViewBuilder public func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// A file path rendered as dimmed directory + emphasized filename (split at the last `/`). The two
/// surfaces size it differently (desktop's fixed `F.ui(12)` vs the phone's Dynamic-Type `.footnote`),
/// so the fonts are parameters — the split logic is the shared part. Consolidates the copies in
/// `DiffInspectorView` / `NotesPage` / `DiffTab`.
public func filePath(_ path: String, dir dirFont: Font, name nameFont: Font, theme: Theme) -> Text {
    guard let slash = path.lastIndex(of: "/") else {
        return Text(path).font(nameFont).foregroundColor(theme.text)
    }
    let dir = String(path[...slash])
    let name = String(path[path.index(after: slash)...])
    return Text(dir).font(dirFont).foregroundColor(theme.text3)
         + Text(name).font(nameFont).foregroundColor(theme.text)
}

// MARK: - Shared chips & gauges

/// The card's origin chip — `sparkles`/Scratch (gray) or `folder`/Freeform (indigo). One view for the
/// board cell and the detail header (their capsules were byte-identical). `.worktree` reads as Freeform,
/// matching the pre-consolidation behavior; call sites decide whether to show it at all.
public struct ModeChip: View {
    let origin: CardOrigin
    @Environment(\.theme) private var theme: Theme
    public init(origin: CardOrigin) { self.origin = origin }
    private var label: String { origin == .scratch ? "Scratch" : "Freeform" }
    private var sem: SemColor { origin == .scratch ? theme.gray : theme.indigo }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: origin == .scratch ? "sparkles" : "folder")
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(sem.tint))
    }
}

/// The orthogonal read-only badge (`lock` + "Read-only"), separate from the mode chip. Shared by the
/// board cell and detail header.
public struct ReadOnlyBadge: View {
    @Environment(\.theme) private var theme: Theme
    public init() {}
    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock")
            Text("Read-only")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.chip))
    }
}

/// The context-window gauge — a fill bar greening → ambering → reddening as the window fills, optionally
/// with the percent spelled out. One parameterized view collapsing the board cell's mini-gauge
/// (`width: 30, showPercent: false`) and the detail header's wider gauge (the defaults). The default
/// dimensions match the header so its call site reads `CtxGauge(pct:theme:)` unchanged.
public struct CtxGauge: View {
    let pct: Double
    let theme: Theme
    var width: CGFloat
    var height: CGFloat
    var minFill: CGFloat
    var showPercent: Bool
    public init(pct: Double, theme: Theme, width: CGFloat = 54, height: CGFloat = 6,
                minFill: CGFloat = 3, showPercent: Bool = true) {
        self.pct = pct; self.theme = theme; self.width = width
        self.height = height; self.minFill = minFill; self.showPercent = showPercent
    }
    private var color: Color {
        if pct >= 90 { return theme.red.dot }
        if pct >= 70 { return theme.amber.dot }
        return theme.green.dot
    }
    public var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chip).frame(width: width, height: height)
                Capsule().fill(color)
                    .frame(width: max(minFill, width * CGFloat(min(100, max(0, pct)) / 100)), height: height)
            }
            if showPercent {
                Text("\(Int(pct))%")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(theme.text2)
            }
        }
        .accessibilityLabel("Context \(Int(pct)) percent" + (showPercent ? " full" : ""))
    }
}

public extension String {
    /// Whitespace-and-newline trim used for all text-input validation across both surfaces.
    /// (Standardized on `.whitespacesAndNewlines`: the phone's `SettingsConnection` copy used
    /// `.whitespaces` alone and had already diverged — a latent bug where a trailing newline
    /// pasted into a field would slip past `isEmpty` guards.)
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
