import SwiftUI
import OrchestraUI
import OrchestraCore

/// The Activity popover with Live feed + CLI reference tabs. ui-spec §3.8 / §4.10.
struct ActivityPopover: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    private enum Tab { case live, cli }
    @State private var tab: Tab = .live

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Circle().fill(theme.green.dot).frame(width: 7, height: 7)
                HStack(spacing: 2) {
                    tabButton("Live", .live)
                    tabButton("CLI", .cli)
                }
                .padding(2)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                Spacer(minLength: 0)
                Text("MCP").font(F.mono(10, .medium)).foregroundColor(theme.text3)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Rectangle().fill(theme.hair).frame(height: 0.5)

            if tab == .live { liveTab } else { cliTab }
        }
        .frame(width: 312)
        // Hosted in a native `.popover` (anchored to the Activity button), which supplies the bubble,
        // arrow, and shadow — so the content only needs to fill itself with the panel color.
        .background(theme.panelOpaque)
    }

    private func tabButton(_ label: String, _ value: Tab) -> some View {
        let active = tab == value
        return Button { tab = value } label: {
            Text(label).font(F.ui(11, .medium))
                .foregroundColor(active ? theme.text : theme.text2)
                .padding(.horizontal, 10).frame(height: 22)
                .background(active ? theme.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Live

    private var liveTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.activity.isEmpty {
                    Text("No activity yet")
                        .font(F.ui(11.5)).foregroundColor(theme.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(model.activity) { item in
                        ActivityRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let id = item.taskId { model.selectedId = id }
                            }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxHeight: 290)
    }

    // MARK: CLI

    private var cliTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("COMMANDS").font(F.ui(9.5, .semibold)).tracking(0.8).foregroundColor(theme.text3)
                ForEach(cliRefs, id: \.0) { cmd, args in
                    HStack(spacing: 6) {
                        Text("orchestra \(cmd)").font(F.mono(11)).foregroundColor(theme.text)
                        Text(args).font(F.mono(11)).foregroundColor(theme.text2)
                    }
                }
                Rectangle().fill(theme.hair).frame(height: 0.5).padding(.vertical, 4)
                Text("EXAMPLE — todo list → plan cards")
                    .font(F.ui(9.5, .semibold)).tracking(0.8).foregroundColor(theme.text3)
                Text("$ orchestra spawn --prompt \"Break the TODO into plan cards\" --col plan")
                    .font(F.mono(11)).foregroundColor(theme.text2).lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(maxHeight: 290)
    }

    private var cliRefs: [(String, String)] {
        [
            ("list", ""),
            ("spawn", "--prompt --repo --branch --col --model"),
            ("move", "<ref> --col"),
            ("send", "<ref> --message"),
            ("status", "<ref>"),
            ("archive", "<ref>"),
            ("restart", "<ref>"),
            ("resume", "<ref>"),
            ("shell", "<ref>"),
            ("exec", "<ref> -- <cmd>"),
            ("sessions", "<ref>"),
        ]
    }
}

private struct ActivityRow: View {
    @Environment(\.theme) var theme: Theme
    let item: ActivityItem

    private var avatarColor: Color {
        switch item.source {
        case .app:    return theme.gray.dot
        case .cli:    return theme.blue.dot
        case .mcp:    return theme.green.dot
        case .agent:  return theme.indigo.dot
        case .daemon: return theme.text3
        }
    }
    private var initial: String { String(item.source.rawValue.prefix(1)).uppercased() }

    private var rel: String {
        let secs = Int(Date().timeIntervalSince(item.at))
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(initial)
                .font(F.mono(9, .heavy)).foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(avatarColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(F.ui(12)).foregroundColor(theme.text).lineSpacing(1)
                Text(rel).font(F.mono(10.5)).foregroundColor(theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
