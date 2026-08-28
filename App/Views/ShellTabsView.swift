import SwiftUI
import OrchestraUI
import AppKit
import OrchestraCore
import OrchestraKit

/// A tab ribbon of opened shell windows + a resizable shell terminal panel below the agent
/// terminal. ui-spec §3.5 (bottom strip / shell panel) / §4.5.
struct ShellTabsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    @Environment(\.interfaceScale) private var interfaceScale
    let task: Task

    // Shell windows + selection live on BoardModel (keyed by task id) so they survive deselect/
    // reselect. Minimize is persisted so the `z` keyboard verb (which writes this key) can toggle it.
    @AppStorage("shellMinimized") private var minimized = false

    // Shell-panel height, persisted across launches; clamped 80–500 (ui-spec §3.5). During a live
    // drag we hold the in-flight value in `dragHeight` and commit to @AppStorage only on release
    // (a per-frame UserDefaults write would stutter the drag — same pattern as InspectorResizer).
    @AppStorage("shellPanelHeight") private var savedHeight: Double = 220
    @State private var dragHeight: Double? = nil
    @State private var startHeight: Double? = nil
    @State private var startScale: Double? = nil

    private var panelHeight: CGFloat { CGFloat(dragHeight ?? savedHeight) }
    private var windows: [String] { model.shellWindows[task.id] ?? [] }
    private var selectedWindow: String { model.selectedShell[task.id] ?? windows.first ?? "shell-1" }
    // A `phone-<client>` window is owned by a phone: it's LISTED here (shell-sync) but the desktop must
    // not live-attach it — a second client on the same tmux window resize-fights the phone (the grouped
    // view session is keyed by window, not client). Selecting it shows an owned-elsewhere placeholder.
    private func isPhoneOwned(_ w: String) -> Bool { ShellOwner(window: w).isPhone }
    // The ribbon doubles as a drag handle, but only when a panel is actually showing below it.
    private var resizable: Bool { !minimized && !windows.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            if !minimized && !windows.isEmpty {
                Group {
                    if isPhoneOwned(selectedWindow) {
                        phonePanel(selectedWindow)
                    } else {
                        AgentTerminalView(socket: model.terminalTmuxSocket, session: task.tmuxSession,
                                          window: selectedWindow, host: model.terminalHost,
                                          background: theme.termBg, foreground: theme.term,
                                          loadTranscriptImage: { referenceID in
                                              try await model.transcriptImage(task.id, referenceID: referenceID)
                                          },
                                          // A click into a shell counts as descending: mark the zone so the
                                          // inspector focus ring / chip track it.
                                          onFocused: {
                                              model.focusZone = .shell
                                              model.selectedShell[task.id] = selectedWindow
                                          })
                            // Re-create the terminal per shell tab (and per active connection) so each
                            // attaches to its own tmux window against the right host.
                            .id("\(model.connections.activeId)-\(task.tmuxSession):\(selectedWindow)")
                    }
                }
                    .frame(height: panelHeight)
                    .background(theme.termBg)
                    .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 0.5) }
            }
        }
        // Round only the panel's bottom corners — the top edge butts up square against the agent
        // terminal region above (AgentChrome rounds the shared silhouette).
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                          bottomTrailingRadius: 10, topTrailingRadius: 0,
                                          style: .continuous))
    }

    /// Shown when a phone-owned shell tab is selected on the desktop. The desktop lists it (so the set
    /// is consistent) but can't live-attach without resize-fighting the phone, so it renders an
    /// owned-elsewhere note instead of an `AgentTerminalView`. Closing it from here is still fine.
    private func phonePanel(_ window: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 26)).foregroundColor(theme.text3)
            Text("Phone-owned shell").font(F.ui(12, .semibold)).foregroundColor(theme.text2)
            Text(window).font(F.mono(10)).foregroundColor(theme.text3)
            Text("This shell runs on a phone. It’s listed here so both surfaces stay in sync; open a new desktop shell with + to work here.")
                .font(F.ui(11)).foregroundColor(theme.text3)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.termBg)
    }

    private var ribbon: some View {
        HStack(spacing: 4) {
            ForEach(windows, id: \.self) { w in
                let active = w == selectedWindow
                HStack(spacing: 3) {
                    Button { model.selectedShell[task.id] = w } label: {
                        HStack(spacing: 4) {
                            if isPhoneOwned(w) {
                                Image(systemName: "iphone").font(F.ui(9))
                                    .help("Owned by a phone")
                            } else {
                                Text("›_").font(F.mono(10))
                            }
                            Text(w).font(F.mono(10, .medium))
                        }
                        .foregroundColor(active ? theme.text : theme.text2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { _Concurrency.Task { await model.closeShell(task.id, w) } } label: {
                        Image(systemName: "xmark").font(F.ui(8, .bold))
                            .foregroundColor(active ? theme.text2 : theme.text3)
                            .frame(width: 13, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close \(w)")
                }
                .padding(.leading, 7)
                .padding(.trailing, 4)
                .frame(height: 20)
                .background(active ? theme.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Button {
                _Concurrency.Task { await model.newShell(task.id) }
            } label: {
                Image(systemName: "plus").font(F.ui(11))
                    .foregroundColor(theme.text2)
                    .frame(width: 18, height: 18)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { minimized.toggle() } label: {
                Image(systemName: minimized ? "chevron.up" : "chevron.down")
                    .font(F.ui(10)).foregroundColor(theme.text2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(theme.chip)
        .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 0.5) }
        .contentShape(Rectangle())
        // ns-resize cursor + drag-to-resize, but only while a panel is open below. `including:
        // .subviews` parks this gesture when not resizable so the tab/+/minimize buttons still get
        // their taps; window move-by-background is already disabled (OrchestraApp) so no AppKit
        // backing is needed to keep the drag from dragging the whole window.
        .onHover { hovering in
            guard resizable else { return }
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(resizeDrag, including: resizable ? .all : .subviews)
    }

    // Dragging the ribbon up grows the shell panel (and shrinks the flexible agent terminal above).
    private var resizeDrag: some Gesture {
        // Measure in GLOBAL space: the ribbon shifts up/down as the panel grows, so a .local
        // translation would be read against a moving origin and jitter (cf. InspectorResizer).
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if startHeight == nil {
                    startHeight = savedHeight
                    startScale = interfaceScale
                }
                dragHeight = resolve(v.translation.height, base: startHeight ?? savedHeight,
                                     scale: startScale ?? interfaceScale)
            }
            .onEnded { v in
                let base = startHeight ?? savedHeight
                savedHeight = resolve(v.translation.height, base: base, scale: startScale ?? interfaceScale)
                startHeight = nil
                startScale = nil
                dragHeight = nil
            }
    }

    private func resolve(_ translation: CGFloat, base: Double, scale: Double) -> Double {
        // Up (negative translation) → taller panel. Clamp 80–500 per ui-spec §3.5.
        min(500, max(80, base - InterfaceScale.logicalDistance(fromPhysical: Double(translation), scale: scale)))
    }
}
