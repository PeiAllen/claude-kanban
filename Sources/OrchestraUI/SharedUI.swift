// Shared cross-surface UI helpers — one source of truth for the small formatters and
// view snippets that the macOS desktop (App/) and the iOS phone client (App-iOS/) both need.
// Consolidated here (D9) from per-view copies that had begun to drift; keep new copies out.

import SwiftUI

public extension String {
    /// Whitespace-and-newline trim used for all text-input validation across both surfaces.
    /// (Standardized on `.whitespacesAndNewlines`: the phone's `SettingsConnection` copy used
    /// `.whitespaces` alone and had already diverged — a latent bug where a trailing newline
    /// pasted into a field would slip past `isEmpty` guards.)
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
