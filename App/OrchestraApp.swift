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
                .task { await ensureDaemonAndStart() }
                .onOpenURL { url in model.select(ref: url.absoluteString) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
        }
    }

    private func ensureDaemonAndStart() async {
        // Ensure the background daemon is installed/running, then connect.
        let life = DaemonLifecycle()
        if !life.isRunning() {
            try? life.ensureRunning(orchestradBin: siblingBinary("orchestrad"))
        }
        await model.start()   // start() retries the connect while the socket comes up
    }
}

/// Top-level composition: toolbar over a board + optional inspector, with sheet/popover/toast overlays.
struct ContentView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.winBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ToolbarView()
                Divider().overlay(theme.hair)
                HStack(spacing: 0) {
                    BoardView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.selected != nil {
                        Divider().overlay(theme.hair)
                        InspectorView()
                            .frame(width: 392)
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
        }
        .animation(.easeOut(duration: 0.18), value: model.showSpawn)
        .animation(.easeOut(duration: 0.16), value: model.showDone)
        .animation(.easeOut(duration: 0.16), value: model.showActivity)
    }
}

struct PopoverScrim: View {
    let onTap: () -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture(perform: onTap)
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
        .background(theme.panelOpaque)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.hair, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.26), radius: 20, y: 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    var dotColor: Color {
        switch toast.color { case .green: return theme.green.dot; case .blue: return theme.blue.dot; case .red: return theme.red.dot }
    }
}
