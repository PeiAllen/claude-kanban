import SwiftUI
import OrchestraKit
import OrchestraUI

/// An advisory projection of a card's durable inbox. The daemon owns the three row states; this view only
/// partitions the one snapshot into unresolved work and provider-accepted history, then reloads after RPCs.
struct InboxEditorView: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task
    /// Non-nil only for the DEBUG headless snapshot: seeds `messages` and skips the daemon load + the
    /// scroll view (which ImageRenderer cannot lay out). Nil in the real app.
    private let preview: [InboxMessage]?

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var isAppending = false
    @State private var editingId: UUID?
    @State private var editText = ""
    @FocusState private var editorFocused: Bool

    init(task: Task, preview: [InboxMessage]? = nil) {
        self.task = task
        self.preview = preview
        if let preview { _messages = State(initialValue: preview) }
    }

    private var unresolved: [InboxMessage] { messages.filter { $0.state != .handedOff } }
    private var history: [InboxMessage] { messages.filter { $0.state == .handedOff } }
    private var hasFailed: Bool { unresolved.contains { $0.state == .failed } }

    /// The popover's fixed width, and the cap on the message list's height. A queued message is a
    /// PROMPT — a paragraph, not a label — so this panel is sized like the app's other reading
    /// surfaces (the Done popover is 460 x 380) instead of the chip-sized panel it started as.
    private static let panelWidth: CGFloat = 480
    private static let listMaxHeight: CGFloat = 420
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
            } else if preview != nil {
                // ImageRenderer cannot lay out a ScrollView, so the snapshot clips at the same cap
                // the real viewport scrolls at — the shot then shows the popover's true full size.
                VStack(alignment: .leading, spacing: 6) { messageSections }
                    .frame(maxHeight: Self.listMaxHeight, alignment: .top).clipped()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { messageSections }
                }
                .frame(maxHeight: Self.listMaxHeight)
            }

            appendBar
        }
        .padding(14).frame(width: Self.panelWidth)
        .task { if preview == nil { await reload() } }
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

    private func canMove(_ message: InboxMessage, by delta: Int) -> Bool {
        guard !hasFailed,
              let index = unresolved.firstIndex(where: { $0.id == message.id })
        else { return false }
        let destination = index + delta
        return unresolved.indices.contains(destination)
    }

    private func reload() async { messages = await model.inboxPeek(task.id, includeHistory: true) }

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
