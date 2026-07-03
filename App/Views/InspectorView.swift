import SwiftUI
import OrchestraCore
import AppKit

/// The right-hand inspector panel: header actions + the live agent terminal chrome (or the
/// Recovery panel when the card is `dead`). ui-spec §3.5 / §4.5.
/// Inspector content mode: the live agent terminal, or the read-only in-app diff (axis 7).
enum InspectorMode { case agent, diff }

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
                        // Mode lives on the model so the `d` keyboard verb can toggle it from the board.
                        HeaderBar(task: t, mode: $model.inspectorMode)
                        if model.inspectorMode == .diff {
                            DiffInspectorView(task: t)
                        } else {
                            AgentChrome(task: t)
                        }
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
    @Binding var mode: InspectorMode

    // Inbox editor popover state.
    @State private var showInbox = false

    var body: some View {
        HStack(spacing: 6) {
            // Agent terminal vs the read-only in-app diff (axis 7).
            Picker("", selection: $mode) {
                Text("Agent").tag(InspectorMode.agent)
                Text("Diff").tag(InspectorMode.diff)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

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

            // Open the project's notes/ folder as an Obsidian vault (mirrors the `/open-notes` command).
            Button {
                _Concurrency.Task { await model.openNotes(task.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text").font(F.ui(13, .semibold)).foregroundColor(theme.text)
                    Text("Open notes").font(F.ui(12, .semibold)).foregroundColor(theme.text)
                }
                .padding(.horizontal, 11)
                .frame(height: 29)
                .surface(theme.card, corner: 8, hair: theme.hair)
            }
            .buttonStyle(.plain)
            .help("Open this project's notes folder as an Obsidian vault")

            // Live-delivery card actions — hidden for a dead card (recovery owns that state).
            if task.status != .dead {
                inboxAction

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
        // The `I` keyboard verb pulses this to open the Inbox popover.
        .onChange(of: model.requestInboxOpen) { _, open in
            if open { showInbox = true; model.requestInboxOpen = false }
        }
    }

    // MARK: - Card actions

    /// Inbox (F3): view/reorder/edit/remove/append the card's durable queued messages.
    private var inboxAction: some View {
        actionButton("Inbox", systemImage: "tray.full", isOn: $showInbox) {
            InboxEditorView(task: task)
                .environmentObject(model)
                .environment(\.theme, theme)
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
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Inbox editor

/// The inbox editor popover: list the card's durable queued messages with per-row reorder
/// (up/down), inline edit, and delete, plus an append field. All ops round-trip to the daemon
/// and reload. Loaded fresh each time the popover opens.
struct InboxEditorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task
    /// Non-nil only for the DEBUG headless snapshot: seeds `messages` and skips the daemon load +
    /// the ScrollView (which ImageRenderer can't lay out). Nil in the real app.
    private let preview: [InboxMessage]?

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var editingId: UUID?
    @State private var editText = ""

    init(task: Task, preview: [InboxMessage]? = nil) {
        self.task = task
        self.preview = preview
        if let preview { _messages = State(initialValue: preview) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inbox — \(messages.count) queued").font(F.ui(12, .semibold)).foregroundColor(theme.text)
            Text("Delivered at the agent's next turn-end (F3).").font(F.ui(11)).foregroundColor(theme.text2)

            if messages.isEmpty {
                Text("No queued messages.").font(F.ui(11.5)).foregroundColor(theme.text3)
                    .padding(.vertical, 6)
            } else if preview != nil {
                VStack(spacing: 4) { ForEach(messages, id: \.id) { row($0) } }
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(messages, id: \.id) { row($0) } }
                }
                .frame(maxHeight: 220)
            }

            HStack(spacing: 6) {
                TextField("Append a message…", text: $appendText)
                    .textFieldStyle(.plain)
                    .font(F.ui(12.5)).foregroundColor(theme.text)
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Button {
                    let text = appendText.trimmed; guard !text.isEmpty else { return }
                    appendText = ""
                    _Concurrency.Task { await model.send(task.id, text); await reload() }
                } label: {
                    Text("Add").font(F.ui(12, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(theme.accent.opacity(appendText.trimmed.isEmpty ? 0.4 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(appendText.trimmed.isEmpty)
            }
        }
        .padding(12).frame(width: 360)
        .task { if preview == nil { await reload() } }
    }

    private func row(_ m: InboxMessage) -> some View {
        HStack(spacing: 6) {
            VStack(spacing: 1) {
                chevron("chevron.up") { _Concurrency.Task { await move(m, by: -1) } }
                chevron("chevron.down") { _Concurrency.Task { await move(m, by: 1) } }
            }
            if editingId == m.id {
                TextField("", text: $editText, onCommit: { _Concurrency.Task { await commitEdit(m) } })
                    .textFieldStyle(.plain)
                    .font(F.ui(12)).foregroundColor(theme.text)
            } else {
                Text(m.text).font(F.ui(12)).foregroundColor(theme.text).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingId = m.id; editText = m.text }
            }
            Button { _Concurrency.Task { await remove(m) } } label: {
                Image(systemName: "trash").font(F.ui(10)).foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func chevron(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(F.ui(8, .semibold)).foregroundColor(theme.text2)
        }
        .buttonStyle(.plain)
    }

    private func reload() async { messages = await model.inboxPeek(task.id) }

    private func remove(_ m: InboxMessage) async {
        await model.inboxRemove(task.id, messageId: m.id); await reload()
    }

    private func commitEdit(_ m: InboxMessage) async {
        let text = editText.trimmed
        editingId = nil
        if !text.isEmpty && text != m.text { await model.inboxEdit(task.id, messageId: m.id, text: text) }
        await reload()
    }

    private func move(_ m: InboxMessage, by delta: Int) async {
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let j = i + delta
        guard j >= 0, j < messages.count else { return }
        var ids = messages.map(\.id); ids.swapAt(i, j)
        await model.inboxReorder(task.id, orderedIds: ids); await reload()
    }
}

// MARK: - Agent chrome (terminal)

private struct AgentChrome: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    /// Panel corner radius (shared by the outline, the region clips, and the focus rings).
    private let cr: CGFloat = 10

    /// Which pane owns the keyboard. The accent focus ring hugs whichever one is active — the agent
    /// terminal (top block) or the shell panel (bottom block) — so *where* the glow sits tells you
    /// where your keys go, the "your keys go here now" cue the board's card highlight can't give.
    private var agentFocused: Bool { model.focusZone == .terminal }
    private var shellFocused: Bool { model.focusZone == .shell }

    private var ctxColor: Color {
        if task.ctxPct >= 80 { return theme.red.dot }
        if task.ctxPct >= 50 { return theme.amber.dot }
        return theme.green.dot
    }

    var body: some View {
        // ui-spec §3.5: the bottom strip is *either* the full-width "New terminal" button (no shells)
        // *or* the shell tab ribbon + resizable panel. When shells are open the panel splits into two
        // stacked regions — the agent terminal on top, the shells below — and the focus ring hugs
        // whichever one owns the keyboard. With no shells open the agent region *is* the whole panel.
        let shellsOpen = model.shellOpen.contains(task.id)
        // Agent region rounds the top; its bottom rounds too only when it fills the panel (no shells).
        let agentShape = UnevenRoundedRectangle(topLeadingRadius: cr,
                                                bottomLeadingRadius: shellsOpen ? 0 : cr,
                                                bottomTrailingRadius: shellsOpen ? 0 : cr,
                                                topTrailingRadius: cr, style: .continuous)
        // Shell region butts up square against the agent above and rounds only the panel's bottom.
        let shellShape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: cr,
                                                bottomTrailingRadius: cr, topTrailingRadius: 0,
                                                style: .continuous)

        VStack(spacing: 0) {
            // AGENT region — context bar + header + breadcrumb + agent terminal (+ the "New terminal"
            // strip when there are no shells, so the region is the full panel).
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

                AgentTerminalView(socket: model.terminalTmuxSocket, session: task.tmuxSession, window: "agent",
                                  host: model.terminalHost,
                                  background: theme.termBg, foreground: theme.term,
                                  // Only grab the keyboard when the user has actually descended into the
                                  // terminal (Enter / i / Ctrl-l) — NOT on every card change. Otherwise
                                  // hjkl-ing between cards would remount this view and steal focus, so the
                                  // next nav key would type into the agent instead of moving the selection.
                                  autofocus: model.focusZone == .terminal,
                                  // A mouse click into the terminal also counts as descending: keep the
                                  // zone (and the focus ring / chip) honest.
                                  onFocused: { if model.focusZone != .terminal { model.focusZone = .terminal } })
                    // Key by session AND active connection so switching cards OR connections tears down the
                    // old terminal and attaches a fresh one against the right host — without this, SwiftUI
                    // reuses the same NSView and every card shows card #1's tmux.
                    .id("\(model.connections.activeId)-\(task.tmuxSession)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.termBg)

                if !shellsOpen { BottomStrip(task: task) }
            }
            .background(theme.termBg)
            .clipShape(agentShape)
            .overlay(agentShape.strokeBorder(agentFocused ? theme.accent.opacity(0.55) : .clear,
                                             lineWidth: agentFocused ? 1.5 : 0))
            .shadow(color: agentFocused ? theme.accent.opacity(0.1) : .clear, radius: agentFocused ? 3 : 0)
            .zIndex(agentFocused ? 1 : 0)

            // SHELL region — the tab ribbon + resizable shell panel, with its own focus ring.
            if shellsOpen {
                ShellTabsView(task: task)
                    .background(theme.termBg)
                    .clipShape(shellShape)
                    .overlay(shellShape.strokeBorder(shellFocused ? theme.accent.opacity(0.55) : .clear,
                                                     lineWidth: shellFocused ? 1.5 : 0))
                    .shadow(color: shellFocused ? theme.accent.opacity(0.1) : .clear, radius: shellFocused ? 3 : 0)
                    .zIndex(shellFocused ? 1 : 0)
            }
        }
        // A single always-on hairline traces the whole panel; the region rings above supply the focus tell.
        .overlay(RoundedRectangle(cornerRadius: cr, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.12), value: model.focusZone)
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
