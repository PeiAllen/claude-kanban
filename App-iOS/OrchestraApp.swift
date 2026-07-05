import SwiftUI
import OrchestraUI   // BoardModel + Theme + the platform-protocol Environment keys

@main
struct OrchestraiOSApp: App {
    // The SHARED OrchestraUI.BoardModel (reconcile #3), constructed with the iOS platform bundle.
    // Its #if os(iOS) activate() drives the dev-transport connect path.
    @StateObject private var model = BoardModel(platform: .ios)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
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

/// The tab shell + M5 appearance wiring. A view (not the `App`) so `@Environment(\.colorScheme)` resolves
/// against the live UI appearance — needed to pick the accent's light/dark variant when Theme is *System*.
private struct RootView: View {
    enum Tab: String { case board, needsYou, settings, terminal }

    @EnvironmentObject var model: BoardModel
    @AppStorage("orch_theme_mode") private var themeRaw = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    // Initial tab is Board; an `ORCH_INITIAL_TAB` launch env can seed a different one so a screenshot
    // gate can land directly on Settings (absent in normal use → Board). In DEBUG, `ORCH_T1_AUTOATTACH=1`
    // lands on the terminal harness so a simctl screenshot captures a live attach without UI driving.
    @State private var tab: Tab = RootView.initialTab()

    private static func initialTab() -> Tab {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        // Land on the DEBUG Terminal harness for either the T1 auto-attach or the T4 auto-takeover, so a
        // headless simctl screenshot reaches the surface without UI driving (that tab hosts both).
        if env["ORCH_T1_AUTOATTACH"] == "1" || env["ORCH_T4_AUTOTAKEOVER"] == "1" { return .terminal }
        #endif
        return Tab(rawValue: env["ORCH_INITIAL_TAB"] ?? "") ?? .board
    }

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
