import SwiftUI
import OrchestraCore

/// A tab ribbon of opened shell windows + a resizable shell terminal panel below the agent
/// terminal. ui-spec §3.5 (bottom strip / shell panel) / §4.5.
struct ShellTabsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    // Shell windows + selection live on BoardModel (keyed by task id) so they survive deselect/
    // reselect; only the minimize toggle is transient view state.
    @State private var minimized = false
    private let panelHeight: CGFloat = 220

    private var windows: [String] { model.shellWindows[task.id] ?? [] }
    private var selectedWindow: String { model.selectedShell[task.id] ?? windows.first ?? "shell-1" }

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            if !minimized && !windows.isEmpty {
                AgentTerminalView(session: task.tmuxSession, window: selectedWindow,
                                  background: theme.termBg, foreground: theme.term)
                    // Re-create the terminal per shell tab so each attaches to its own tmux window.
                    .id("\(task.tmuxSession):\(selectedWindow)")
                    .frame(height: panelHeight)
                    .background(theme.termBg)
                    .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 0.5) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var ribbon: some View {
        HStack(spacing: 4) {
            ForEach(windows, id: \.self) { w in
                let active = w == selectedWindow
                HStack(spacing: 3) {
                    Button { model.selectedShell[task.id] = w } label: {
                        HStack(spacing: 4) {
                            Text("›_").font(F.mono(10))
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
    }
}
