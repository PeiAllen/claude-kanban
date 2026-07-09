import Foundation
import OrchestraKit

// Pure, view-free logic for the tabbed card detail (M2). Kept separate from the SwiftUI views so it is
// unit testable — the tab set + order, the diff baselines a card offers, and the header breadcrumb. The
// views (`CardDetailView`, `DiffTab`, …) render these decisions. Mirrors M1's `BoardPager.swift` split.

/// The six card-detail tabs, in bar order: **Agent · Terminal · Diff · Notes · Inbox · Info** (design §3).
/// Agent is the primary read/steer surface (built in T3); Terminal is the secondary escape hatch, still a
/// clearly-marked stub (T2). Diff · Inbox · Info are built in M2; Notes (M6) is promoted to a first-class
/// tab and sits beside Diff — both are "what this branch changed" surfaces (Diff = code, Notes = `.md`).
public enum CardTab: String, CaseIterable, Identifiable, Sendable {
    case agent, terminal, diff, notes, inbox, info

    public var id: String { rawValue }

    /// Tab-bar label.
    public var title: String {
        switch self {
        case .agent:    return "Agent"
        case .terminal: return "Terminal"
        case .diff:     return "Diff"
        case .notes:    return "Notes"
        case .inbox:    return "Inbox"
        case .info:     return "Info"
        }
    }

    /// SF Symbol for the segmented tab bar.
    public var symbol: String {
        switch self {
        case .agent:    return "brain"
        case .terminal: return "terminal"
        case .diff:     return "plusminus"
        case .notes:    return "note.text"
        case .inbox:    return "tray.full"
        case .info:     return "info.circle"
        }
    }

    /// The detail's initial tab — **Agent** (design §3's primary surface). A dev/test override via the
    /// `ORCH_DEV_CARD_TAB` env (`agent|terminal|diff|notes|inbox|info`) lets a headless Simulator screenshot
    /// a specific tab deterministically. Absent env ⇒ Agent (no behavior change).
    public static var initial: CardTab {
        (ProcessInfo.processInfo.environment["ORCH_DEV_CARD_TAB"]).flatMap(CardTab.init(rawValue:)) ?? .agent
    }
}

/// The baseline a card's Diff tab opens on (design §3 Diff, BT3): **Parent** for a stacked card so it
/// shows the card's OWN work vs its parent, else **Branch** (vs the default branch). Pure so the Diff
/// tab and its tests agree on the default.
public func diffDefaultBaseline(parentBranch: String?) -> DiffBase {
    parentBranch != nil ? .parent : .branch
}

/// The pinned-header worktree breadcrumb (design §3). A worktree card reads `repo/branch → …/dir`; a
/// freeform/scratch card has no branch, so it reads its directory path alone. Pure string shaping so the
/// header stays declarative and the format is testable.
public func cardBreadcrumb(repo: String, branch: String, cwd: String, origin: CardOrigin) -> String {
    guard origin == .worktree else { return abbreviatedCardPath(cwd) }
    let repoName = (repo as NSString).lastPathComponent
    return "\(repoName)/\(branch) → \(abbreviatedCardPath(cwd))"
}

/// Collapse a long path to `…/parent/dir` so a breadcrumb fits a phone width (matches the board cell's
/// footer abbreviation).
public func abbreviatedCardPath(_ path: String) -> String {
    let parts = (path as NSString).pathComponents.filter { $0 != "/" }
    guard parts.count > 2 else { return path }
    return "…/" + parts.suffix(2).joined(separator: "/")
}
