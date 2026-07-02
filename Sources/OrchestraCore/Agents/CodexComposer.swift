import Foundation

/// `CodexAdapter`'s TUI pane-gate — the Codex-specific half of the F2 send-keys detect-and-defer wake
/// (C4), reached ONLY via `CodexAdapter.canNudge(pane:)` so core's generic wake never names a Codex type.
/// Best-effort read of the captured agent pane: the nudge fires ONLY when the agent is idle AND its
/// composer is empty; anything else (a user draft, an in-flight turn, or a pane we cannot parse) DEFERS.
///
/// FRAGILE BY NATURE. This parses Codex's TUI text rendering, which drifts across versions — hence q10
/// keeps v1 on send-keys and watches upstream app-server #29922 / #28144 to eventually replace this
/// with a real control channel (`wakeTransport.controlChannel`). It is deliberately CONSERVATIVE: when
/// the composer can't be located it reports "not nudgeable" so we never fire a keystroke into an unknown
/// UI state. Focus is NOT consulted (per design: focus is not a gate). The marker/placeholder tables below
/// are the only Codex-specific knobs and are the documented place to tune when the TUI changes.
enum CodexComposer {

    /// Substrings Codex renders WHILE a turn is streaming; idle = none present. Lower-cased match.
    static let workingCues = ["esc to interrupt", "esc to stop", "working", "thinking", "generating"]

    /// Leading glyphs of the TUI composer input line (scanned bottom-up).
    static let promptMarkers: Set<Character> = ["›", "❯", "▌", "▶"]

    /// Greyed placeholder strings Codex shows in an EMPTY composer (they arrive as literal pane text).
    /// Normalized to `.empty` so a placeholder is not misread as a user draft. TUNE against the real TUI.
    static let emptyPlaceholders = ["send a message", "ask codex", "type a message"]

    /// The composer's content: confirmed empty, a user draft, or "couldn't find the composer line".
    enum Composer: Equatable { case empty, draft(String), unknown }

    /// Locate the composer input line (last line beginning with a prompt marker) and classify it.
    static func composer(_ pane: String) -> Composer {
        for raw in pane.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, promptMarkers.contains(first) else { continue }
            let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let restLc = rest.lowercased()
            if rest.isEmpty || emptyPlaceholders.contains(where: { restLc == $0 }) { return .empty }
            return .draft(rest)
        }
        return .unknown
    }

    /// Is a turn currently streaming? (heuristic; see caveat)
    static func isWorking(_ pane: String) -> Bool {
        let lc = pane.lowercased()
        return workingCues.contains { lc.contains($0) }
    }

    /// Safe to fire the wake nudge? ONLY when idle AND the composer is confirmed empty. A draft, an
    /// in-flight turn, or an unparseable pane all DEFER (false) — the inbox stays durable for a later wake.
    static func canNudge(_ pane: String) -> Bool {
        !isWorking(pane) && composer(pane) == .empty
    }
}
