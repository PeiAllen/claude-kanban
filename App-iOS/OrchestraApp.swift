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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(snooze)
                // Inject the iOS platform conformers so the shared UI resolves its per-OS bits.
                // TerminalHost rides the Environment only (produced by a view, not called by BoardModel).
                .environment(\.clipboard, IOSClipboard())
                .environment(\.systemOpener, IOSSystemOpener())
                .environment(\.windowConfig, IOSWindowConfig())
                .environment(\.terminalHost, IOSTerminalHost())
                .task { await model.bootstrap() }
                #if DEBUG
                .task { DebugSupport.exportPubkey() }
                #endif
        }
    }
}

/// The tab shell + M5 appearance wiring + M3 Needs-You badge. A view (not the `App`) so
/// `@Environment(\.colorScheme)` resolves against the live UI appearance — needed to pick the accent's
/// light/dark variant when Theme is *System*.
private struct RootView: View {
    enum Tab: String { case board, needsYou, settings, terminal }

    @EnvironmentObject var model: BoardModel
    @EnvironmentObject var snooze: NeedsYouSnooze
    @AppStorage("orch_theme_mode") private var themeRaw = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    // Initial tab is Board; `ORCH_INITIAL_TAB` / `ORCH_DEV_TAB` (board|needs|settings) can seed a
    // different one so a headless screenshot gate lands deterministically. In DEBUG, `ORCH_T1_AUTOATTACH=1`
    // lands on the terminal harness. Absent env ⇒ Board (no behavior change).
    @State private var tab: Tab = RootView.initialTab()

    private static func initialTab() -> Tab {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["ORCH_T1_AUTOATTACH"] == "1" { return .terminal }
        #endif
        switch (env["ORCH_INITIAL_TAB"] ?? env["ORCH_DEV_TAB"] ?? "").lowercased() {
        case "needs", "needsyou", "needs-you": return .needsYou
        case "settings":                       return .settings
        default:                               return .board
        }
    }

    /// The Needs You tab badge: the attention count with snoozed rows removed (0 renders no badge).
    private var needsYouBadge: Int { snooze.visible(model.needsYouItems).count }

    private var themeMode: ThemeMode { ThemeMode(rawValue: themeRaw) ?? .system }
    private var accentDark: Bool {
        switch themeMode.colorScheme {
        case .some(.dark):  return true
        case .some(.light): return false
        default:            return systemScheme == .dark
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            BoardTab()
                .tabItem { Label("Board", systemImage: "square.stack.3d.up") }
                .tag(Tab.board)
            NeedsYouTab()
                .tabItem { Label("Needs You", systemImage: "bell") }
                .badge(needsYouBadge)
                .tag(Tab.needsYou)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            #if DEBUG
            // T1 dev harness to exercise the terminal seam before T2/T3/T4 mount it. DEBUG-only.
            DebugTerminalTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)
            #endif
        }
        .tint(model.accent.color(dark: accentDark))
        .preferredColorScheme(themeMode.colorScheme)
    }
}
