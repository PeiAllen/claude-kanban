import SwiftUI
import OrchestraCore
import AppKit

/// The right-hand inspector panel: header actions + the live agent terminal chrome (or the
/// Recovery panel when the card is `dead`). ui-spec §3.5 / §4.5.
struct InspectorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        if let t = model.selected {
            Group {
                if t.status == .dead {
                    // Recovery fills the whole sidebar and owns its own close button + actions.
                    RecoveryView(task: t)
                } else {
                    VStack(spacing: 0) {
                        HeaderBar(task: t)
                        AgentChrome(task: t)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.inspector)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.hair).frame(width: 0.5)
            }
        }
    }
}

// MARK: - Header bar

private struct HeaderBar: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    var body: some View {
        HStack(spacing: 6) {
            Button {
                _Concurrency.Task { await model.openInZed(task.id) }
            } label: {
                HStack(spacing: 6) {
                    ZedBadge(size: 16, corner: 4, glyph: 9)
                    Text("View changes").font(F.ui(12, .semibold)).foregroundColor(theme.text)
                }
                .padding(.horizontal, 11)
                .frame(height: 29)
                .surface(theme.card, corner: 8, hair: theme.hair)
            }
            .buttonStyle(.plain)

            // The recovery panel owns Archive when the card is dead, so we don't duplicate it here.
            if task.status != .dead {
                Button {
                    _Concurrency.Task { await model.archive(task.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(F.ui(10, .semibold))
                        Text("Archive").font(F.ui(12, .medium))
                    }
                    .foregroundColor(theme.text2)
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .surface(theme.card, corner: 8, hair: theme.hair)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Button {
                model.selectedId = nil
            } label: {
                Image(systemName: "xmark").font(F.ui(11, .semibold))
                    .foregroundColor(theme.text2)
                    .frame(width: 29, height: 29)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Agent chrome (terminal)

private struct AgentChrome: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var ctxColor: Color {
        if task.ctxPct >= 80 { return theme.red.dot }
        if task.ctxPct >= 50 { return theme.amber.dot }
        return theme.green.dot
    }

    var body: some View {
        VStack(spacing: 0) {
            // Context bar (2px)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(ctxColor)
                        .frame(width: geo.size.width * CGFloat(min(94, task.ctxPct)) / 100)
                        .opacity(0.7)
                }
            }
            .frame(height: 2)

            TerminalHeader(task: task)
            BreadcrumbStrip(task: task)

            AgentTerminalView(session: task.tmuxSession, window: "agent",
                              background: theme.termBg, foreground: theme.term)
                // Key by session so switching cards tears down the old terminal and attaches a fresh
                // one — without this, SwiftUI reuses the same NSView and every card shows card #1's tmux.
                .id(task.tmuxSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.termBg)

            BottomStrip(task: task)

            if model.shellOpen.contains(task.id) {
                ShellTabsView(task: task)
            }
        }
        .background(theme.termBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .hairline(theme.hair, corner: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

private struct TerminalHeader: View {
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var family: String { task.model.family }
    private var modelColor: Color {
        switch family {
        case "claude": return theme.dark ? Color(hex: 0xE8896A) : Color(hex: 0xBF5836)
        case "gpt":    return theme.dark ? Color(hex: 0x3EC9A5) : Color(hex: 0x10A37F)
        case "gemini": return theme.dark ? Color(hex: 0x79B0FF) : Color(hex: 0x3B73DB)
        default:       return theme.text2
        }
    }
    private var repoName: String { (task.repo as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(modelColor).frame(width: 6, height: 6)
                Text(task.model.displayName).font(F.mono(9.5, .semibold)).foregroundColor(modelColor)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(theme.chip)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(repoName)
                .font(F.mono(10, .semibold))
                .foregroundColor(theme.text2)
                .lineLimit(1)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .frame(maxWidth: 140, alignment: .leading)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(task.branch).font(F.mono(11)).foregroundColor(theme.text2).lineLimit(1)

            Spacer(minLength: 0)

            StatusPill(status: task.status.rawValue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hair).frame(height: 0.5) }
    }
}

private struct StatusPill: View {
    @Environment(\.theme) var theme: Theme
    let status: String
    var body: some View {
        let sem = theme.statusColor(status)
        HStack(spacing: 6) {
            Circle().fill(sem.dot).frame(width: 6, height: 6)
            Text(theme.statusLabel(status)).font(F.ui(10.5, .semibold)).foregroundColor(sem.text)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 3)
        .background(sem.tint)
        .clipShape(Capsule())
    }
}

private struct BreadcrumbStrip: View {
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var pathParts: [String] {
        task.worktree.split(separator: "/").map(String.init)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                copy(task.ref())
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(F.ui(9))
                    Text("Copy chat link").font(F.mono(10))
                }
                .foregroundColor(theme.text2)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)

            Rectangle().fill(theme.hair).frame(width: 0.5, height: 14)

            Button {
                copy("\(task.tmuxSession):agent")
            } label: {
                Text("Copy tmux target").font(F.mono(10)).foregroundColor(theme.text2)
                    .padding(.horizontal, 10).frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // worktree path with › separators
            HStack(spacing: 4) {
                ForEach(Array(pathParts.enumerated()), id: \.offset) { idx, part in
                    if idx > 0 {
                        Text("›").font(F.ui(8.5)).foregroundColor(theme.text3)
                    }
                    Text(part)
                        .font(F.mono(10))
                        .foregroundColor(idx == pathParts.count - 1 ? theme.text2 : theme.text3)
                }
            }
            .lineLimit(1)
            .padding(.trailing, 10)
            .onTapGesture { copy(task.worktree) }
        }
        .frame(height: 25)
        .background(theme.chip)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hair).frame(height: 0.5) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct BottomStrip: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    var body: some View {
        Button {
            _Concurrency.Task { await model.newShell(task.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(F.ui(11))
                Text("New terminal").font(F.ui(12, .semibold))
            }
            .foregroundColor(theme.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .background(theme.chip)
        .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 0.5) }
    }
}

// MARK: - Zed badge

struct ZedBadge: View {
    var size: CGFloat
    var corner: CGFloat
    var glyph: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x4A90D9), Color(hex: 0x8E5BD9), Color(hex: 0xD96BA0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Text("Z").font(F.mono(glyph, .heavy)).foregroundColor(.white)
            )
    }
}
