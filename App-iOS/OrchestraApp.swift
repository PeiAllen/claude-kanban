import SwiftUI
import OrchestraUI   // BoardModel + Theme + the platform-protocol Environment keys

@main
struct OrchestraiOSApp: App {
    // The SHARED OrchestraUI.BoardModel (reconcile #3), constructed with the iOS platform bundle.
    // Its #if os(iOS) activate() drives the dev-transport connect path.
    @StateObject private var model = BoardModel(platform: .ios)

    var body: some Scene {
        WindowGroup {
            TabView {
                BoardTab()
                    .tabItem { Label("Board", systemImage: "square.stack.3d.up") }
                NeedsYouTab()
                    .tabItem { Label("Needs You", systemImage: "bell") }
                SettingsTab()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(model)
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
