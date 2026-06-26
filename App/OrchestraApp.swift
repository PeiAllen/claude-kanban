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

    /// Inspector width, persisted across launches. During a live drag we don't touch this (a
    /// per-frame UserDefaults write + KVO fan-out makes the drag stutter); `dragWidth` holds the
    /// in-flight value and we commit it back here only when the drag ends.
    @AppStorage("inspectorWidth") private var savedInspectorWidth: Double = 392
    /// Non-nil only while the divider is being dragged — the live width that drives layout.
    @State private var dragWidth: Double? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.winBg.ignoresSafeArea()
            WindowConfigurator()

            VStack(spacing: 0) {
                ToolbarView()
                Divider().overlay(theme.hair)
                if !model.connected {
                    OfflineBanner()
                    Divider().overlay(theme.hair)
                }
                GeometryReader { geo in
                    // The board fills the area to the left of the inspector. While the split can
                    // give up room the board just shrinks. Once the inspector is dragged wider than
                    // that — the board has hit its ~690pt minimum (3 columns) — the board stops
                    // shrinking and the inspector slides *over* it instead of shoving the whole row
                    // off-screen.
                    let w = Double(geo.size.width)
                    let h = Double(geo.size.height)
                    let boardMin = 690.0
                    let hasInspector = model.selected != nil
                    let inspectorWidth = dragWidth ?? savedInspectorWidth
                    let split = w - inspectorWidth
                    let boardW = hasInspector ? max(boardMin, split) : w
                    ZStack(alignment: .topLeading) {
                        BoardView()
                            .frame(width: boardW, height: h)
                        if hasInspector {
                            HStack(spacing: 0) {
                                // Allow dragging the inspector out nearly all the way — leave only a
                                // thin board sliver so the divider stays grabbable to pull it back.
                                InspectorResizer(width: inspectorWidth,
                                                 maxWidth: max(360, geo.size.width - 56),
                                                 onChange: { dragWidth = $0 },
                                                 onEnd: { savedInspectorWidth = $0; dragWidth = nil })
                                InspectorView()
                                    .frame(width: inspectorWidth)
                            }
                            .frame(width: w, height: h, alignment: .trailing)
                        }
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                    .clipped()
                }
                .frame(maxHeight: .infinity)
            }
            // Pull the toolbar up under the (hidden) titlebar so it shares the band with the traffic
            // lights. Without this, the title-bar safe-area inset pushes the toolbar down, leaving an
            // empty strip above it that looks like the old native bar.
            .ignoresSafeArea(.container, edges: .top)

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
/// drag to resize the inspector (clamped). Persisted width lives on ContentView. The strip is backed
/// by a non-window-draggable AppKit view so the drag resizes instead of moving the whole window.
struct InspectorResizer: View {
    /// Current (live) inspector width — read-only; changes are reported via the closures below.
    var width: Double
    /// Upper bound for the drag — supplied by the parent from the live window width so the inspector
    /// can be pulled out nearly the whole way.
    var maxWidth: Double = 760
    /// Called every drag frame with the new width (parent keeps this in cheap @State).
    var onChange: (Double) -> Void
    /// Called once when the drag ends with the final width (parent persists it).
    var onEnd: (Double) -> Void
    @Environment(\.theme) var theme
    @State private var startWidth: Double?

    private func resolve(_ translation: CGFloat, base: Double) -> Double {
        // Dragging left (negative translation) widens the inspector.
        min(maxWidth, max(320, base - Double(translation)))
    }

    var body: some View {
        theme.hair.frame(width: 0.5)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(NonWindowDraggable())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                // Measure in GLOBAL space: the handle re-lays-out to a new x on every width change,
                // so a .local translation would be measured against a moving origin and jitter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startWidth == nil { startWidth = width }
                        onChange(resolve(v.translation.width, base: startWidth ?? width))
                    }
                    .onEnded { v in
                        let base = startWidth ?? width
                        startWidth = nil
                        onEnd(resolve(v.translation.width, base: base))
                    }
            )
    }
}

/// An AppKit view whose region never initiates a window drag, so a SwiftUI gesture on top of it
/// (the resize handle) works even under a full-size-content / movable window.
struct NonWindowDraggable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// Static, one-time window setup: pull the SwiftUI content under a transparent full-size titlebar so
/// our toolbar occupies the same band as the traffic lights (the toolbar then lays itself out to line
/// up — no runtime querying or moving of the OS buttons). Also disables move-by-background so the
/// inspector resize handle works. Done from `viewDidMoveToWindow`, where the window already exists.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
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
