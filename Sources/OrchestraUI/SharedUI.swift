// Shared cross-surface UI helpers — one source of truth for the small formatters and
// view snippets that the macOS desktop (App/) and the iOS phone client (App-iOS/) both need.
// Consolidated here (D9) from per-view copies that had begun to drift; keep new copies out.

import SwiftUI

/// Relative age like the board's `3s`/`4m`/`2h`/`1d` — the compact "time since" stamp shown on cards,
/// the activity feed, and the agent capture line. One implementation for every surface (was copied
/// five ways: desktop `CardView`, iOS `BoardCardCell`/`NeedsYouTab`/`ActivityFeedView`, and
/// `CardDetailHeader.relativeDetailAge`).
public func relativeAge(_ date: Date, now: Date = Date()) -> String {
    let s = Int(max(0, now.timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
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

public extension String {
    /// Whitespace-and-newline trim used for all text-input validation across both surfaces.
    /// (Standardized on `.whitespacesAndNewlines`: the phone's `SettingsConnection` copy used
    /// `.whitespaces` alone and had already diverged — a latent bug where a trailing newline
    /// pasted into a field would slip past `isEmpty` guards.)
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
