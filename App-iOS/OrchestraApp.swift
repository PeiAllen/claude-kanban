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
        }
    }
}

/// The tab shell + M5 appearance wiring. A view (not the `App`) so `@Environment(\.colorScheme)` resolves
/// against the live UI appearance — needed to pick the accent's light/dark variant when Theme is *System*.
private struct RootView: View {
    enum Tab: String { case board, needsYou, settings }

    @EnvironmentObject var model: BoardModel
    @AppStorage("orch_theme_mode") private var themeRaw = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    // Initial tab is Board; an `ORCH_INITIAL_TAB` launch env can seed a different one so a screenshot
    // gate can land directly on Settings (absent in normal use → Board).
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["ORCH_INITIAL_TAB"] ?? "") ?? .board

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
        }
        .tint(model.accent.color(dark: accentDark))
        .preferredColorScheme(themeMode.colorScheme)
    }
}
