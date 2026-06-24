import SwiftUI
import OrchestraCore

/// A tab ribbon of opened shell windows + a resizable shell terminal panel below the agent
/// terminal. ui-spec §3.5 (bottom strip / shell panel) / §4.5.
struct ShellTabsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    @State private var windows: [String] = []
    @State private var selected: String?
    @State private var minimized = false
    @State private var panelHeight: CGFloat = 220

    private var selectedWindow: String { selected ?? windows.first ?? "shell-1" }

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            if !minimized && !windows.isEmpty {
                AgentTerminalView(session: "orchestra-\(task.id.uuidString.lowercased())", window: selectedWindow)
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
                Button { selected = w } label: {
                    HStack(spacing: 4) {
                        Text("›_").font(F.mono(10))
                        Text(w).font(F.mono(10, .medium))
                    }
                    .foregroundColor(w == selectedWindow ? theme.text : theme.text2)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(w == selectedWindow ? theme.card : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }

            Button {
                _Concurrency.Task {
                    if let w = await model.openShell(task.id) {
                        windows.append(w)
                        selected = w
                    }
                }
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
        .onAppear {
            if windows.isEmpty {
                _Concurrency.Task {
                    if let w = await model.openShell(task.id) {
                        windows.append(w)
                        selected = w
                    }
                }
            }
        }
    }
}
