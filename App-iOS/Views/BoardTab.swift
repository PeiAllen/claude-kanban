import SwiftUI
import OrchestraKit
import OrchestraUI

/// Skeleton board: a connection banner + a flat live list of the daemon's cards, straight off the
/// shared `BoardModel`. The swipeable column pager is M1; this proves the shared core streams on-device.
struct BoardTab: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        NavigationStack {
            Group {
                if model.tasks.isEmpty {
                    ContentUnavailableView("No cards",
                                           systemImage: "square.stack.3d.up.slash",
                                           description: Text("Spawn agents on the desktop to see them here."))
                } else {
                    List(model.tasks) { task in CardRow(task: task) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Board")
            .safeAreaInset(edge: .top) { ConnectionBanner(state: model.connectionState) }
        }
    }
}

private struct CardRow: View {
    let task: Task
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title).font(.headline).lineLimit(1)
                Spacer()
                StatusPill(status: task.status)
            }
            Text("\(URL(fileURLWithPath: task.repo).lastPathComponent)/\(task.branch)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .waiting: return .orange
        case .dead:    return .red
        case .done:    return .secondary
        }
    }
}

/// Thin bar reflecting `ConnectionState`; hidden while live so the board is chrome-free when connected.
private struct ConnectionBanner: View {
    let state: ConnectionState
    var body: some View {
        if state != .live {
            HStack(spacing: 8) {
                Image(systemName: state == .retrying || state == .connecting
                      ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                Text(label).font(.footnote.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.orange.opacity(0.15))
        }
    }
    private var label: String {
        switch state {
        case .connecting: return "Connecting…"
        case .retrying:   return "Reconnecting…"
        case .down:       return "Offline"
        case .live:       return ""
        }
    }
}
