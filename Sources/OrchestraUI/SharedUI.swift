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

public extension String {
    /// Whitespace-and-newline trim used for all text-input validation across both surfaces.
    /// (Standardized on `.whitespacesAndNewlines`: the phone's `SettingsConnection` copy used
    /// `.whitespaces` alone and had already diverged — a latent bug where a trailing newline
    /// pasted into a field would slip past `isEmpty` guards.)
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
