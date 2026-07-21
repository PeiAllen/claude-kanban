import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **Inbox** tab (design §3): the durable inbox editor — list / reorder / edit / append / remove the
/// card's queued messages, delivered at the agent's next turn-end. Native-iOS reinterpretation of the
/// desktop `InboxEditorView`: swipe-to-delete, drag-to-reorder (Edit mode), tap-to-edit, and a pinned
/// append bar. Every op round-trips to the daemon (`inbox` / `send` / `inbox-edit` / `inbox-remove` /
/// `inbox-reorder`) then reloads — the inbox isn't on the event stream, so the tab owns its own refresh.
struct InboxTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var loaded = false
    @State private var editMode: EditMode = .inactive
    @State private var editing: InboxMessage?
    @State private var editText = ""

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
                Text("\(messages.count) queued").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Text("Delivered at the agent's next turn-end.").font(.caption).foregroundStyle(theme.text2)
            }
            Spacer()
            if !messages.isEmpty {
                Button(editMode == .active ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.subheadline).tint(theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var listBody: some View {
        if messages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.title2).foregroundStyle(theme.text3)
                Text("No queued messages").font(.footnote).foregroundStyle(theme.text3)
                Text("Append one below — it's delivered at the agent's next turn-end.")
                    .font(.caption).foregroundStyle(theme.text3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else {
            List {
                ForEach(messages, id: \.id) { m in
                    row(m)
                        .listRowBackground(theme.card)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { _Concurrency.Task { await remove(m) } } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                .onMove(perform: moveRows)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
    }

    private func row(_ m: InboxMessage) -> some View {
        Button {
            guard editMode != .active else { return }
            editText = m.text; editing = m
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.caption).foregroundStyle(theme.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(m.sourceLabel)").font(.caption2.weight(.medium)).foregroundStyle(theme.text2)
                    Text(m.text).font(.callout).foregroundStyle(theme.text).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Button {
                _Concurrency.Task { await append() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
                    .foregroundStyle(appendTrimmed.isEmpty ? theme.text3 : theme.accent)
            }
            .disabled(appendTrimmed.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.card)
        .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .top)
    }

    private var appendTrimmed: String { appendText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    // MARK: ops — each round-trips then reloads

    private func reload() async { messages = await model.inboxPeek(task.id) }

    private func append() async {
        let text = appendTrimmed; guard !text.isEmpty else { return }
        appendText = ""
        await model.send(task.id, text)
        await reload()
    }

    private func remove(_ m: InboxMessage) async {
        await model.inboxRemove(task.id, messageId: m.id)
        await reload()
    }

    private func commitEdit() async {
        guard let m = editing else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        if !text.isEmpty && text != m.text {
            await model.inboxEdit(task.id, messageId: m.id, text: text)
            await reload()
        }
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        var reordered = messages
        reordered.move(fromOffsets: source, toOffset: destination)
        messages = reordered   // optimistic; the daemon confirms on reload
        let ids = reordered.map(\.id)
        _Concurrency.Task { await model.inboxReorder(task.id, orderedIds: ids); await reload() }
    }
}
