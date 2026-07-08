import SwiftUI
import OrchestraKit
import OrchestraUI

/// Activity feed (design §5) — the Live/CLI feed as a chronological list with a Live/CLI filter, off the
/// shared `BoardModel.activity`. A pushed screen within the Board tab (`‹ Board` back), not its own tab.
/// (Tapping an entry → its card is wired in M2 once card detail exists; rows are read-only here.)
struct ActivityFeedView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @State private var filter: ActivityFilter = .live

    private var items: [ActivityItem] { model.activity.filter { filter.matches($0) } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ActivityFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            if items.isEmpty {
                Spacer()
                ContentUnavailableView("No \(filter.title.lowercased()) activity",
                                       systemImage: "waveform",
                                       description: Text("Recent \(filter.title) events appear here."))
                Spacer()
            } else {
                List {
                    ForEach(items) { ActivityRow(item: $0) }
                }
                .listStyle(.plain)
            }
        }
        .background(theme.winBg.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(sem.text)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.subheadline).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(item.source.rawValue.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(sem.text)
                    Text(relativeAge(item.at)).font(.caption2).foregroundStyle(theme.text3)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var sem: SemColor {
        switch item.kind {
        case .dead, .warning:  return theme.red
        case .spawned, .recovered: return theme.green
        case .statusChanged:   return theme.amber
        default:               return theme.gray
        }
    }
    private var glyph: String {
        switch item.kind {
        case .spawned:       return "plus.circle"
        case .moved:         return "arrow.left.arrow.right"
        case .archived:      return "archivebox"
        case .statusChanged: return "circle.dotted"
        case .dead:          return "xmark.octagon"
        case .recovered:     return "arrow.uturn.backward"
        case .command:       return "terminal"
        case .warning:       return "exclamationmark.triangle"
        }
    }
}
