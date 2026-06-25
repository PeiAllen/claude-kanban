import SwiftUI
import OrchestraCore

@main
struct OrchestraApp: App {
    @StateObject private var model = BoardModel()

    var body: some Scene {
        Window("Orchestra · Personal", id: "board") {
            ContentView()
                .environmentObject(model)
                .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
                .preferredColorScheme(model.darkMode ? .dark : .light)
                .frame(minWidth: 940, minHeight: 580)
                .task { await model.bootstrap() }
                .onOpenURL { url in model.select(ref: url.absoluteString) }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
        }
    }
}

/// Top-level composition: toolbar over a board + optional inspector, with sheet/popover/toast overlays.
struct ContentView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme

    /// Inspector width, drag-resizable via the divider and persisted across launches.
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 392

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.winBg.ignoresSafeArea()
            WindowConfigurator(toolbarHeight: ToolbarView.height)

            VStack(spacing: 0) {
                ToolbarView()
                Divider().overlay(theme.hair)
                if !model.connected {
                    OfflineBanner()
                    Divider().overlay(theme.hair)
                }
                HStack(spacing: 0) {
                    BoardView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.selected != nil {
                        InspectorResizer(width: $inspectorWidth)
                        InspectorView()
                            .frame(width: inspectorWidth)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            // Spawn sheet overlay
            if model.showSpawn {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { model.showSpawn = false }
                SpawnSheet()
                    .frame(width: 470)
                    .padding(.top, 62)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Popovers
            if model.showDone {
                PopoverScrim { model.showDone = false }
                DonePopover().frame(width: 460).padding(.top, 48).padding(.trailing, 268)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            if model.showActivity {
                PopoverScrim { model.showActivity = false }
                ActivityPopover().frame(width: 312).padding(.top, 48).padding(.trailing, 120)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }

            // Toasts (bottom-right)
            VStack(alignment: .trailing, spacing: 9) {
                ForEach(model.toasts) { ToastView(toast: $0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // First-run welcome / daemon install — covers the whole window.
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showOnboarding)
        .animation(.easeOut(duration: 0.18), value: model.showSpawn)
        .animation(.easeOut(duration: 0.16), value: model.showDone)
        .animation(.easeOut(duration: 0.16), value: model.showActivity)
        .modifier(DebugLaunchHook())
    }
}

/// DEBUG-only automation hook for headless screenshotting: set `ORCH_SHOW=spawn|settings` on launch
/// to auto-open that surface. Compiled out of Release builds entirely.
private struct DebugLaunchHook: ViewModifier {
    #if DEBUG
    @EnvironmentObject var model: BoardModel
    @Environment(\.openSettings) private var openSettings
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            switch ProcessInfo.processInfo.environment["ORCH_SHOW"] {
            case "spawn": model.showSpawn = true
            case "settings": openSettings()
            default: break
            }
        }
        #else
        content
        #endif
    }
}

/// Shown below the toolbar whenever the control daemon isn't connected, with a one-click start.
struct OfflineBanner: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.connecting ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.amber.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.connecting ? "Starting the Orchestra daemon…" : "Daemon offline")
                    .font(F.ui(12.5, .semibold)).foregroundStyle(theme.text)
                Text("Agents run in a background service. Starting it installs a login-time LaunchAgent so your agents keep running when the app is closed.")
                    .font(F.ui(11)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                _Concurrency.Task { await model.ensureDaemonAndStart() }
            } label: {
                Text(model.connecting ? "Starting…" : "Start daemon")
                    .font(F.ui(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.connecting)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(theme.amber.tint)
    }
}

struct PopoverScrim: View {
    let onTap: () -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture(perform: onTap)
    }
}

/// Draggable divider between the board and the inspector — grab anywhere in the 8px hit strip and
/// drag to resize the inspector (clamped). Persisted width lives on ContentView.
struct InspectorResizer: View {
    @Binding var width: Double
    @Environment(\.theme) var theme
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(theme.hair)
            .frame(width: 0.5)
            .overlay(Color.clear.frame(width: 9).contentShape(Rectangle()))
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        // Dragging left (negative translation) widens the inspector.
                        width = min(760, max(320, base - Double(v.translation.width)))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// Pulls the SwiftUI content under a transparent, full-size titlebar and vertically centers the
/// traffic lights within the app toolbar band, so the window chrome reads as one unified bar.
struct WindowConfigurator: NSViewRepresentable {
    let toolbarHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(toolbarHeight: toolbarHeight) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.reposition() }
    }

    final class Coordinator: NSObject {
        let toolbarHeight: CGFloat
        weak var window: NSWindow?
        init(toolbarHeight: CGFloat) { self.toolbarHeight = toolbarHeight }

        func attach(_ window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            NotificationCenter.default.addObserver(self, selector: #selector(repositionNote),
                                                   name: NSWindow.didResizeNotification, object: window)
            reposition()
        }

        @objc private func repositionNote() { reposition() }

        /// Center the three standard window buttons in the top `toolbarHeight` band. AppKit lays them
        /// out near the very top by default; we nudge them down so they line up with the toolbar.
        func reposition() {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard let container = buttons.first?.superview else { return }
            for b in buttons {
                let targetY = container.bounds.height - toolbarHeight / 2 - b.frame.height / 2
                if abs(b.frame.origin.y - targetY) > 0.5 {
                    b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: targetY))
                }
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(\.theme) var theme
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(F.ui(12.5, .semibold)).foregroundStyle(theme.text)
                if let sub = toast.sub { Text(sub).font(F.mono(11)).foregroundStyle(theme.text2) }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(minWidth: 236, maxWidth: 320, alignment: .leading)
        .surface(theme.panelOpaque, corner: 11, hair: theme.hair)
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.26), radius: 20, y: 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    var dotColor: Color {
        switch toast.color { case .green: return theme.green.dot; case .blue: return theme.blue.dot; case .red: return theme.red.dot }
    }
}
