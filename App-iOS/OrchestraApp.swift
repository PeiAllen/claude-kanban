import SwiftUI
import OrchestraUI   // BoardModel + Theme + the platform-protocol Environment keys

@main
struct OrchestraiOSApp: App {
    // The SHARED OrchestraUI.BoardModel (reconcile #3), constructed with the iOS platform bundle.
    // Its #if os(iOS) activate() drives the dev-transport connect path.
    @StateObject private var model = BoardModel(platform: .ios)
    // Client-local snooze/dismiss state for the Needs You queue (M3) — shared with the tab badge so both
    // agree on what's suppressed.
    @StateObject private var snooze = NeedsYouSnooze()
    @State private var tab: AppTab = .initial

    /// The Needs You tab badge: the attention count with snoozed rows removed (0 renders no badge).
    private var needsYouBadge: Int { snooze.visible(model.needsYouItems).count }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                BoardTab()
                    .tabItem { Label("Board", systemImage: "square.stack.3d.up") }
                    .tag(AppTab.board)
                NeedsYouTab()
                    .tabItem { Label("Needs You", systemImage: "bell") }
                    .badge(needsYouBadge)
                    .tag(AppTab.needs)
                SettingsTab()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .environmentObject(model)
            .environmentObject(snooze)
            // Inject the iOS platform conformers so the shared UI resolves its per-OS bits. TerminalHost
            // rides the Environment only (it is produced by a view, not called by BoardModel).
            .environment(\.clipboard, IOSClipboard())
            .environment(\.systemOpener, IOSSystemOpener())
            .environment(\.windowConfig, IOSWindowConfig())
            .environment(\.terminalHost, IOSTerminalHost())
            .task { await model.bootstrap() }
        }
    }
}

/// The three bottom-tab destinations. `initial` lets a headless Simulator screenshot land on a specific
/// tab deterministically via `ORCH_DEV_TAB` (`board|needs|settings`) — mirrors `BoardPage.initial`.
/// Absent env ⇒ Board (no behavior change).
enum AppTab: Hashable {
    case board, needs, settings

    static var initial: AppTab {
        switch ProcessInfo.processInfo.environment["ORCH_DEV_TAB"] {
        case "needs", "needsyou", "needs-you": return .needs
        case "settings":                       return .settings
        default:                               return .board
        }
    }
}
