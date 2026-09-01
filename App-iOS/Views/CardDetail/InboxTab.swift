import SwiftUI
import OrchestraKit
import OrchestraUI

/// The Inbox tab is an advisory projection of durable inbox rows. It fetches one snapshot, partitions it
/// locally into unresolved work and provider-accepted history, and sends mutations back to the daemon.
struct InboxTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var isAppending = false
    @State private var loaded = false
    @State private var editMode: EditMode = .inactive
    @State private var editing: InboxMessage?
    @State private var editText = ""

    private var unresolved: [InboxMessage] { messages.filter { $0.state != .handedOff } }
    private var history: [InboxMessage] { messages.filter { $0.state == .handedOff } }
    private var hasFailed: Bool { unresolved.contains { $0.state == .failed } }

    var body: some View {
        VStack(spacing: 0) {
            header
            listBody
            appendBar
        }
        .background(theme.winBg)
        .task { if !loaded { await reload(); loaded = true } }
        .alert("Edit message", isPresented: editingBinding) {
            TextField("Message", text: $editText)
            Button("Save") { _Concurrency.Task { await commitEdit() } }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unresolved.count) unresolved")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Text("Handed off means the native harness accepted the message.")
                    .font(.caption).foregroundStyle(theme.text2)
                if hasFailed {
                    Text("Retry, edit, or remove failed messages before reordering.")
                        .font(.caption).foregroundStyle(theme.amber.text)
                }
            }
            Spacer()
            if !unresolved.isEmpty {
                Button(editMode == .active ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.subheadline).tint(theme.accent)
                .disabled(hasFailed)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var listBody: some View {
        if messages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.title2).foregroundStyle(theme.text3)
                Text("No inbox messages").font(.footnote).foregroundStyle(theme.text3)
                Text("Append one below to queue it for the live harness.")
                    .font(.caption).foregroundStyle(theme.text3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else {
            List {
                if !unresolved.isEmpty {
                    Section("Unresolved") {
                        ForEach(unresolved, id: \.id) { message in
                            row(message)
                                .listRowBackground(theme.card)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        _Concurrency.Task { await remove(message) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                    if message.state == .failed {
                                        Button {
                                            _Concurrency.Task { await retry(message) }
                                        } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                        }
                                        .tint(theme.accent)
                                    }
                                }
                        }
                        .onMove(perform: moveRows)
                    }
                }
                if !history.isEmpty {
                    Section("Handed off") {
                        ForEach(history, id: \.id) { message in
                            row(message)
                                .listRowBackground(theme.card)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        _Concurrency.Task { await remove(message) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
    }

    @ViewBuilder private func row(_ message: InboxMessage) -> some View {
        if message.state == .handedOff {
            rowContent(message)
        } else {
            Button {
                guard editMode != .active else { return }
                editText = message.text
                editing = message
            } label: {
                rowContent(message)
            }
            .buttonStyle(.plain)
        }
    }

    private func rowContent(_ message: InboxMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble").font(.caption).foregroundStyle(theme.text3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("From \(message.sourceLabel)")
                        .font(.caption2.weight(.medium)).foregroundStyle(theme.text2)
                    statusBadge(message.state)
                }
                Text(message.text).font(.callout).foregroundStyle(theme.text).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func statusBadge(_ state: InboxMessageState) -> some View {
        let (label, color): (String, SemColor) = switch state {
        case .queued: ("Queued", theme.blue)
        case .failed: ("Failed", theme.red)
        case .handedOff: ("Handed off", theme.gray)
        }
        return Text(label)
            .font(.caption2.weight(.semibold)).foregroundStyle(color.text)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.tint, in: Capsule())
            .fixedSize()
    }

    private var appendBar: some View {
        HStack(spacing: 8) {
            TextField("Append a message…", text: $appendText, axis: .vertical)
                .lineLimit(1...4)
                .font(.callout).foregroundStyle(theme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .disabled(isAppending)
            Button {
                _Concurrency.Task { await append() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
                    .foregroundStyle(appendTrimmed.isEmpty || isAppending ? theme.text3 : theme.accent)
            }
            .disabled(appendTrimmed.isEmpty || isAppending)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.card)
        .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .top)
    }

    private var appendTrimmed: String { appendText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    private func reload() async {
        messages = await model.inboxPeek(task.id, includeHistory: true)
        if hasFailed { editMode = .inactive }
    }

    private func append() async {
        let text = appendTrimmed
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

    private func commitEdit() async {
        guard let message = editing else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        if !text.isEmpty && text != message.text {
            await model.inboxEdit(task.id, messageId: message.id, text: text)
        }
        await reload()
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        guard !hasFailed else { return }
        var reordered = unresolved
        reordered.move(fromOffsets: source, toOffset: destination)
        let ids = reordered.map(\.id)
        _Concurrency.Task {
            await model.inboxReorder(task.id, orderedIds: ids)
            await reload()
        }
    }
}
