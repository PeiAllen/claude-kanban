import SwiftUI
import OrchestraUI   // BoardModel + Theme + the platform-protocol Environment keys

@main
struct OrchestraiOSApp: App {
    // The SHARED OrchestraUI.BoardModel (reconcile #3), constructed with the iOS platform bundle.
    // Its #if os(iOS) activate() drives the dev-transport connect path.
    @StateObject private var model = BoardModel(platform: .ios)
    @State private var tab: Int

    init() {
        // DEBUG harness can launch straight onto the terminal tab (ORCH_T1_AUTOATTACH) so a simctl
        // screenshot lands on the live attach without UI driving.
        #if DEBUG
        _tab = State(initialValue: ProcessInfo.processInfo.environment["ORCH_T1_AUTOATTACH"] == "1" ? 3 : 0)
        #else
        _tab = State(initialValue: 0)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                BoardTab()
                    .tabItem { Label("Board", systemImage: "square.stack.3d.up") }.tag(0)
                NeedsYouTab()
                    .tabItem { Label("Needs You", systemImage: "bell") }.tag(1)
                SettingsTab()
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
                #if DEBUG
                // T1 dev harness to exercise the terminal seam before T2/T3/T4 mount it. DEBUG-only.
                DebugTerminalTab()
                    .tabItem { Label("Terminal", systemImage: "terminal") }.tag(3)
                #endif
            }
            .environmentObject(model)
            // Inject the iOS platform conformers so the shared UI resolves its per-OS bits. TerminalHost
            // rides the Environment only (it is produced by a view, not called by BoardModel).
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
