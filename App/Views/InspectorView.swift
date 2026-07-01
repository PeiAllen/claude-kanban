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

    // Live-delivery card actions (D3). Each opens a small popover with a text field + confirm.
    @State private var showSend = false
    @State private var showHandoff = false
    @State private var showFork = false
    @State private var sendText = ""
    @State private var handoffText = ""
    @State private var forkPrompt = ""
    @State private var forkContext = ""
    @State private var forkBranch = ""

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

            // Live-delivery card actions — hidden for a dead card (recovery owns that state).
            if task.status != .dead {
                sendAction
                handoffAction
                forkAction

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

    // MARK: - Card actions

    /// Send (F3): queue a message to the card's inbox (drained at its next turn-end).
    private var sendAction: some View {
        actionButton("Send", systemImage: "paperplane", isOn: $showSend) {
            actionPopover(title: "Send to inbox",
                          hint: "Queued (F3) — delivered at the agent's next turn-end.",
                          text: $sendText, confirm: "Send", canConfirm: !sendText.trimmed.isEmpty) {
                let msg = sendText; sendText = ""; showSend = false
                _Concurrency.Task { await model.send(task.id, msg) }
            }
        }
    }

    /// Handoff (F1): clean-context resume of THIS card, seeded with the given context.
    private var handoffAction: some View {
        actionButton("Handoff", systemImage: "arrow.uturn.forward", isOn: $showHandoff) {
            actionPopover(title: "Handoff — clean context",
                          hint: "Resume THIS card in a fresh process (same session), seeded with this context.",
                          text: $handoffText, confirm: "Hand off", canConfirm: !handoffText.trimmed.isEmpty) {
                let ctx = handoffText; handoffText = ""; showHandoff = false
                _Concurrency.Task { await model.handoff(task.id, context: ctx) }
            }
        }
    }

    /// Fork: spawn a NEW worktree card off this repo, seeded with the parent slice.
    private var forkAction: some View {
        actionButton("Fork", systemImage: "arrow.triangle.branch", isOn: $showFork) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fork — new card from this one").font(F.ui(12, .semibold)).foregroundColor(theme.text)
                Text("Spawns a new worktree off \((task.repo as NSString).lastPathComponent), seeded with the context below.")
                    .font(F.ui(11)).foregroundColor(theme.text2)
                popoverField("New branch", text: $forkBranch, mono: true)
                popoverField("Task prompt", text: $forkPrompt, mono: false)
                popoverEditor("Fork context (seed)", text: $forkContext)
                HStack {
                    Spacer()
                    confirmButton("Fork", enabled: !forkBranch.trimmed.isEmpty && !forkPrompt.trimmed.isEmpty) {
                        let parent = task, prompt = forkPrompt, branch = forkBranch, ctx = forkContext
                        forkPrompt = ""; forkContext = ""; forkBranch = ""; showFork = false
                        _Concurrency.Task { await model.fork(from: parent, prompt: prompt, branch: branch, context: ctx) }
                    }
                }
            }
            .padding(12).frame(width: 300)
            .onAppear { if forkBranch.isEmpty { forkBranch = "\(task.branch)-fork" } }
        }
    }

    private func actionButton<Content: View>(_ label: String, systemImage: String,
                                             isOn: Binding<Bool>,
                                             @ViewBuilder _ popover: @escaping () -> Content) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(F.ui(10, .semibold))
                Text(label).font(F.ui(12, .medium))
            }
            .foregroundColor(theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .surface(theme.card, corner: 8, hair: theme.hair)
        }
        .buttonStyle(.plain)
        .popover(isPresented: isOn, arrowEdge: .bottom) {
            popover().environment(\.theme, theme)
        }
    }

    private func actionPopover(title: String, hint: String, text: Binding<String>,
                               confirm: String, canConfirm: Bool,
                               action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(F.ui(12, .semibold)).foregroundColor(theme.text)
            Text(hint).font(F.ui(11)).foregroundColor(theme.text2)
            popoverEditor(nil, text: text)
            HStack {
                Spacer()
                confirmButton(confirm, enabled: canConfirm, action: action)
            }
        }
        .padding(12).frame(width: 300)
    }

    private func popoverField(_ label: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.ui(10.5, .semibold)).foregroundColor(theme.text2)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(mono ? F.mono(12) : F.ui(12.5)).foregroundColor(theme.text)
                .padding(.horizontal, 9).frame(height: 30)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func popoverEditor(_ label: String?, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(F.ui(10.5, .semibold)).foregroundColor(theme.text2) }
            TextEditor(text: text)
                .font(F.ui(12.5)).foregroundColor(theme.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5).padding(.vertical, 6).frame(height: 84)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func confirmButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(F.ui(12, .semibold)).foregroundColor(.white)
                .padding(.horizontal, 14).frame(height: 28)
                .background(theme.accent.opacity(enabled ? 1 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
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
                              background: theme.termBg, foreground: theme.term, autofocus: true)
                // Key by session so switching cards tears down the old terminal and attaches a fresh
                // one — without this, SwiftUI reuses the same NSView and every card shows card #1's tmux.
                .id(task.tmuxSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.termBg)

            // ui-spec §3.5: the bottom strip is *either* the full-width "New terminal" button (no
            // shells) *or* the shell tab ribbon (which carries its own "+" to add more). They never
            // stack — closing the last shell drops `shellOpen` and the button comes back.
            if model.shellOpen.contains(task.id) {
                ShellTabsView(task: task)
            } else {
                BottomStrip(task: task)
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
    @EnvironmentObject var model: BoardModel
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

            if task.origin == .worktree {
                Text(repoName)
                    .font(F.mono(10, .semibold))
                    .foregroundColor(theme.text2)
                    .lineLimit(1)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .frame(maxWidth: 140, alignment: .leading)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(task.branch).font(F.mono(11)).foregroundColor(theme.text2).lineLimit(1)
            } else {
                // Freeform (borrowed/scratch) card: no repo/branch — show the borrowed dir instead.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc").font(F.mono(9))
                    Text((task.cwd as NSString).lastPathComponent).font(F.mono(10, .semibold)).lineLimit(1)
                }
                .foregroundColor(theme.text2)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .frame(maxWidth: 200, alignment: .leading)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help(task.cwd)
            }

            if task.access == .readOnly {
                HStack(spacing: 4) {
                    Image(systemName: "eye").font(F.mono(9))
                    Text("read-only").font(F.mono(10, .semibold))
                }
                .foregroundColor(theme.text2)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help("This agent cannot edit, write, or commit.")
            }

            SharedWorktreeBadge(task: task)

            Spacer(minLength: 0)

            Button {
                _Concurrency.Task { await model.inspect(task.id) }
            } label: {
                Image(systemName: "eye")
                    .font(F.mono(10.5))
                    .foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
            .help("Open a read-only agent in this worktree (can read/search/git, cannot edit)")

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

// MARK: - Shared-worktree indicator

/// Small chip shown when other non-archived cards share this card's worktree. Hover lists their ids;
/// click opens a popover where picking a sibling selects it (opening that card's inspector). Multiple
/// agents per worktree is intentional — this is the passive signal + jump affordance, not coordination.
private struct SharedWorktreeBadge: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task
    @State private var showList = false

    var body: some View {
        let siblings = model.worktreeSiblings(of: task)
        if !siblings.isEmpty {
            Button { showList.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(F.ui(8.5))
                    Text("\(siblings.count)").font(F.mono(9.5, .semibold))
                }
                .foregroundColor(theme.text2)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(model.worktreeSiblingsHelp(of: task))
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                SharedWorktreeList(siblings: siblings) { id in
                    model.selectedId = id
                    showList = false
                }
                .environment(\.theme, theme)
            }
        }
    }
}

/// Popover body: one selectable row per co-located card (status dot · shortId · title).
private struct SharedWorktreeList: View {
    @Environment(\.theme) var theme: Theme
    let siblings: [Task]
    let onPick: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Other agents on this worktree")
                .font(F.ui(10.5, .semibold)).foregroundColor(theme.text2)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ForEach(siblings) { sib in
                Button { onPick(sib.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(theme.statusColor(sib.status.rawValue).dot).frame(width: 6, height: 6)
                        Text(sib.shortId).font(F.mono(10)).foregroundColor(theme.text3)
                        Text(sib.title).font(F.ui(11.5)).foregroundColor(theme.text).lineLimit(1)
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 248)
        .padding(.bottom, 8)
        .background(theme.inspector)
    }
}

private struct BreadcrumbStrip: View {
    @Environment(\.theme) var theme: Theme
    let task: Task

    @State private var copied = false
    @State private var hovering = false

    private var pathParts: [String] {
        task.cwd.split(separator: "/").map(String.init)
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

            // worktree path with › separators — click to copy the full absolute path
            Button { copyPath() } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(F.ui(8.5))
                        .foregroundColor(copied ? theme.green.dot : theme.text3)
                        .opacity(copied || hovering ? 1 : 0)
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
                .padding(.trailing, 10).padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied!" : "Copy path")
            .onHover { hovering = $0 }
        }
        .frame(height: 25)
        .background(theme.chip)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hair).frame(height: 0.5) }
    }

    private func copyPath() {
        copy(task.cwd)
        copied = true
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
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
