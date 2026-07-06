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
    // Push (N1): remote-notification callbacks land on this delegate; UI-facing state flows through
    // PushCoordinator.shared (device token → daemon registration; tapped push → Needs You deep-link).
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @ObservedObject private var push = PushCoordinator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(snooze)
                .environmentObject(push)
                // Inject the iOS platform conformers so the shared UI resolves its per-OS bits.
                // TerminalHost rides the Environment only (produced by a view, not called by BoardModel).
                .environment(\.clipboard, IOSClipboard())
                .environment(\.systemOpener, IOSSystemOpener())
                .environment(\.windowConfig, IOSWindowConfig())
                .environment(\.terminalHost, IOSTerminalHost())
                .task { await model.bootstrap() }
                // Hand a freshly-registered APNs token to the daemon (and re-register on token rotation).
                .onChange(of: push.deviceToken) { _, token in
                    guard let token else { return }
                    _Concurrency.Task { await model.registerForPush(token: token) }
                }
                #if DEBUG
                .task { DebugSupport.exportPubkey(); DebugSupport.resetHostKeyPinsIfRequested() }
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
    @EnvironmentObject var push: PushCoordinator
    @AppStorage("orch_theme_mode") private var themeRaw = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    // Initial tab is Board; `ORCH_INITIAL_TAB` / `ORCH_DEV_TAB` (board|needs|settings) can seed a
    // different one so a headless screenshot gate lands deterministically. In DEBUG, `ORCH_T1_AUTOATTACH=1`
    // lands on the terminal harness. Absent env ⇒ Board (no behavior change).
    @State private var tab: Tab = RootView.initialTab()

    private static func initialTab() -> Tab {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        // Land on the DEBUG Terminal harness for either the T1 auto-attach or the T4 auto-takeover, so a
        // headless simctl screenshot reaches the surface without UI driving (that tab hosts both).
        if env["ORCH_T1_AUTOATTACH"] == "1" || env["ORCH_T4_AUTOTAKEOVER"] == "1" { return .terminal }
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
        // A tapped push deep-links to the card: switch to the Needs You tab, where NeedsYouTab consumes
        // `pendingCardId` to open the card (or Recovery, if dead). Design §6: the in-app queue is what
        // push notifications deep-link into.
        .onChange(of: push.pendingCardId) { _, id in
            if id != nil { tab = .needsYou }
        }
        // Auto-own on phone-spawn (Bug 3): a card spawned from the phone is the phone's to drive, so the
        // spawn sheet sets `phoneTakeoverRequest` and we drop straight into the live takeover surface —
        // no manual "Take Over" tap. Presented app-level so it covers whatever tab is showing; dismissing
        // (Return to Desktop / retake) clears the request. The environment (model, platform conformers)
        // is inherited by the presented view, as with the Agent tab's own takeover cover.
        .fullScreenCover(item: $model.phoneTakeoverRequest) { req in
            AgentTakeoverView(cardId: req.id, model: model) { model.phoneTakeoverRequest = nil }
        }
        #if DEBUG
        // Bug-3 verify hook: open the spawn sheet on launch so it can auto-submit (see SpawnSheet's
        // ORCH_SPAWN_AUTOSUBMIT). DEBUG-only; production never sets this env.
        .onAppear {
            if ProcessInfo.processInfo.environment["ORCH_SPAWN_AUTOSUBMIT"] == "1" { model.showSpawn = true }
        }
        #endif
    }
}
