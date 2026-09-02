import SwiftUI
import OrchestraKit
import OrchestraUI

/// An advisory projection of a card's durable inbox. The daemon owns the three row states; this view only
/// partitions the one snapshot into unresolved work and provider-accepted history, then reloads after RPCs.
struct InboxEditorView: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task
    /// Rows for a DEBUG screenshot harness, standing in for the daemon. Nil in the real app.
    private let debugMessages: [InboxMessage]?
    /// Renders the list as a plain stack instead of a scroll view, because `ImageRenderer` cannot lay
    /// a `ScrollView` out. Set ONLY by the headless snapshot. A harness driving the REAL window leaves
    /// it false and gets the real scroll view, arriving on the real (async) schedule — the shipped
    /// path, and the only one in which this panel's sizing can be judged.
    private let flattenForRenderer: Bool

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var isAppending = false
    @State private var editingId: UUID?
    @State private var editText = ""
    @FocusState private var editorFocused: Bool
    /// The measured height of the message list, which drives the viewport — see `listViewport`.
    @State private var contentHeight: CGFloat = 0

    init(task: Task, debugMessages: [InboxMessage]? = nil, flattenForRenderer: Bool = false) {
        self.task = task
        self.debugMessages = debugMessages
        self.flattenForRenderer = flattenForRenderer
        // ImageRenderer draws in one pass, so the headless snapshot cannot wait for a load.
        if flattenForRenderer, let debugMessages { _messages = State(initialValue: debugMessages) }
    }

    private var unresolved: [InboxMessage] { messages.filter { $0.state != .handedOff } }
    private var history: [InboxMessage] { messages.filter { $0.state == .handedOff } }
    private var hasFailed: Bool { unresolved.contains { $0.state == .failed } }

    /// The popover's fixed width, and the cap on the message list's height. A queued message is a
    /// PROMPT — a paragraph, not a label — so this panel is sized like the app's other reading
    /// surfaces (the Done popover is 460 x 380) instead of the chip-sized panel it started as.
    private static let panelWidth: CGFloat = 480
    private static let listMaxHeight: CGFloat = 420
    /// The viewport floor, so a list that is measured late (or not at all) still shows a row.
    private static let listMinHeight: CGFloat = 76
    /// How many wrapped lines a row shows before it truncates. Unresolved work is what you have to
    /// read to act on it, so it gets the room; handed-off history only has to be recognisable.
    private static let unresolvedLines = 6
    private static let historyLines = 3
    private static let editorLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inbox — \(unresolved.count) unresolved")
                .font(F.ui(14, .semibold)).foregroundColor(theme.text)
            Text("Handed off means the native harness accepted the message.")
                .font(F.ui(12)).foregroundColor(theme.text2)

            if hasFailed {
                Text("Retry, edit, or remove failed messages before reordering.")
                    .font(F.ui(11.5)).foregroundColor(theme.amber.text)
            }

            if messages.isEmpty {
                Text("No inbox messages.").font(F.ui(12.5)).foregroundColor(theme.text3)
                    .padding(.vertical, 8)
            } else if flattenForRenderer {
                // The snapshot clips at the same cap the real viewport scrolls at, so the shot still
                // shows the popover's true full size.
                messageList.frame(maxHeight: Self.listMaxHeight, alignment: .top).clipped()
            } else {
                ScrollView { messageList.background(heightReader) }
                    // A ScrollView reports no content-driven ideal height, so a popover sizes itself
                    // from everything AROUND the list — and the inbox arrives one daemon round trip
                    // AFTER the popover opens, i.e. while the list is still the empty state. The
                    // popover kept that opening height and squeezed every message into the leftover
                    // sliver. Measuring the rows and pinning the viewport to them (capped) gives the
                    // popover a real height to grow into when the messages land.
                    .frame(height: min(max(contentHeight, Self.listMinHeight), Self.listMaxHeight))
            }

            appendBar
        }
        .padding(14).frame(width: Self.panelWidth)
        .task { if !flattenForRenderer { await reload() } }
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 6) { messageSections }
    }

    /// Reports the list's laid-out height back into `contentHeight`. It sits in a `.background`, so it
    /// measures the rows without ever influencing their layout.
    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { contentHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, height in contentHeight = height }
        }
    }

    @ViewBuilder private var messageSections: some View {
        if !unresolved.isEmpty {
            sectionTitle("Unresolved")
            ForEach(unresolved, id: \.id) { row($0) }
        }
        if !history.isEmpty {
            sectionTitle("Handed off")
            ForEach(history, id: \.id) { row($0) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(F.ui(10.5, .semibold)).tracking(0.5).foregroundColor(theme.text3)
            .padding(.top, 5)
    }

    private func row(_ message: InboxMessage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            reorderControls(for: message)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("From \(message.sourceLabel)")
                        .font(F.ui(11.5, .medium)).foregroundColor(theme.text2)
                    statusBadge(message.state)
                }
                messageText(message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if message.state == .failed {
                Button { _Concurrency.Task { await retry(message) } } label: {
                    Text("Retry").font(F.ui(12, .semibold)).foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
                .help("Retry this failed message")
            }

            Button { _Concurrency.Task { await remove(message) } } label: {
                Image(systemName: "trash").font(F.ui(12)).foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
            .help("Remove this message")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func messageText(_ message: InboxMessage) -> some View {
        if editingId == message.id {
            // Editing a prompt needs the same room reading one does — the field grows with the text.
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...Self.editorLines)
                .font(F.ui(13)).foregroundColor(theme.text)
                .focused($editorFocused)
                .onAppear { editorFocused = true }
                .onSubmit { _Concurrency.Task { await commitEdit(message) } }
                // What Return does in a multi-line field is platform-defined, so losing focus commits
                // too — clicking away can never leave an edit stranded in an open field.
                .onChange(of: editorFocused) { _, focused in
                    guard !focused, editingId == message.id else { return }
                    _Concurrency.Task { await commitEdit(message) }
                }
        } else if message.state == .handedOff {
            Text(message.text).font(F.ui(13)).foregroundColor(theme.text2)
                .lineLimit(Self.historyLines).fixedSize(horizontal: false, vertical: true)
        } else {
            Button { editingId = message.id; editText = message.text } label: {
                Text(message.text).font(F.ui(13)).foregroundColor(theme.text)
                    .lineLimit(Self.unresolvedLines).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Edit this message")
        }
    }

    @ViewBuilder private func reorderControls(for message: InboxMessage) -> some View {
        if message.state == .queued {
            VStack(spacing: 1) {
                chevron("chevron.up", enabled: canMove(message, by: -1)) {
                    _Concurrency.Task { await move(message, by: -1) }
                }
                chevron("chevron.down", enabled: canMove(message, by: 1)) {
                    _Concurrency.Task { await move(message, by: 1) }
                }
            }
            .frame(width: 18)
        } else {
            Color.clear.frame(width: 18, height: 26)
        }
    }

    private func chevron(_ name: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(F.ui(10, .semibold))
                .foregroundColor(enabled ? theme.text2 : theme.text3)
                .frame(width: 18, height: 13)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func statusBadge(_ state: InboxMessageState) -> some View {
        let (label, color): (String, SemColor) = switch state {
        case .queued: ("Queued", theme.blue)
        case .failed: ("Failed", theme.red)
        case .handedOff: ("Handed off", theme.gray)
        }
        return Text(label)
            .font(F.ui(10.5, .semibold)).foregroundColor(color.text)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.tint).clipShape(Capsule())
            .fixedSize()
    }

    private var appendBar: some View {
        HStack(spacing: 8) {
            TextField("Append a message…", text: $appendText)
                .textFieldStyle(.plain)
                .font(F.ui(13.5)).foregroundColor(theme.text)
                .padding(.horizontal, 11).frame(height: 34)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(isAppending)
            Button {
                _Concurrency.Task { await append() }
            } label: {
                Text("Add").font(F.ui(13, .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(theme.accent.opacity(appendText.trimmed.isEmpty || isAppending ? 0.4 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(appendText.trimmed.isEmpty || isAppending)
        }
    }

    // MARK: - Debug harness rows

    #if DEBUG
    /// Rows for the inbox harnesses. Real queued messages are PROMPTS, not labels — paragraph-length
    /// ones, or a shot cannot show whether the panel is big enough to read what it holds.
    static func debugRows(cardId: UUID) -> [InboxMessage] {
        let card = cardId
        return [
            InboxMessage(cardId: card,
                         text: "Review the auth refactor before merging. The token refresh path now "
                             + "runs through the shared session actor, so check that no call site "
                             + "still holds the old lock while it awaits.",
                         state: .queued),
            InboxMessage(cardId: card, text: "Rebase onto main once the status PR lands.",
                         state: .queued),
            InboxMessage(cardId: card,
                         text: "Retry the unavailable provider — the app server was still starting "
                             + "when this message went out.",
                         state: .failed),
            InboxMessage(cardId: card,
                         text: "Branch context for the harness: this card owns feat/inbox-size and "
                             + "its parent is feat/status-rework, so restack before you ship.",
                         state: .handedOff),
        ]
    }

    /// The same rows behind the REAL popover in a live window, when `ORCH_INBOX_MOCK=1`. The headless
    /// snapshot cannot see how the panel sizes itself inside a popover, so the windowed harness drives
    /// the shipped path — scroll view, async arrival and all — instead. `ORCH_INBOX_MOCK=many` stacks
    /// enough rows to overrun the cap, which is the other half of the sizing: the panel must stop
    /// growing and scroll.
    static func debugRowsForWindow(cardId: UUID) -> [InboxMessage]? {
        switch ProcessInfo.processInfo.environment["ORCH_INBOX_MOCK"] {
        case "1": return debugRows(cardId: cardId)
        case "many": return (0..<4).flatMap { _ in debugRows(cardId: cardId) }
        default: return nil
        }
    }
    #endif

    private func canMove(_ message: InboxMessage, by delta: Int) -> Bool {
        guard !hasFailed,
              let index = unresolved.firstIndex(where: { $0.id == message.id })
        else { return false }
        let destination = index + delta
        return unresolved.indices.contains(destination)
    }

    private func reload() async {
        if let debugMessages {
            // Stand in for the daemon, INCLUDING its latency: the rows must land after the popover
            // opens, because that ordering is what the panel has to survive.
            try? await _Concurrency.Task.sleep(for: .milliseconds(300))
            messages = debugMessages
            return
        }
        messages = await model.inboxPeek(task.id, includeHistory: true)
    }

    private func append() async {
        let text = appendText.trimmed
        guard !text.isEmpty, !isAppending else { return }
        isAppending = true
        let accepted = await model.send(task.id, text)
        if accepted { appendText = "" }
        await reload()
        isAppending = false
    }

    private func remove(_ message: InboxMessage) async {
        await model.inboxRemove(task.id, messageId: message.id)
        await reload()
    }

    private func retry(_ message: InboxMessage) async {
        await model.inboxRetry(task.id, messageId: message.id)
        await reload()
    }

    private func commitEdit(_ message: InboxMessage) async {
        let text = editText.trimmed
        editingId = nil
        if !text.isEmpty && text != message.text {
            await model.inboxEdit(task.id, messageId: message.id, text: text)
        }
        await reload()
    }

    private func move(_ message: InboxMessage, by delta: Int) async {
        guard !hasFailed,
              let index = unresolved.firstIndex(where: { $0.id == message.id })
        else { return }
        let destination = index + delta
        guard unresolved.indices.contains(destination) else { return }
        var ids = unresolved.map(\.id)
        ids.swapAt(index, destination)
        await model.inboxReorder(task.id, orderedIds: ids)
        await reload()
    }
}
