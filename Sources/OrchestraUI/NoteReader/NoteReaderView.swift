import SwiftUI
import OrchestraKit

/// The note reader, shared by the desktop inspector tab and the phone's Notes tab.
///
/// One surface for the whole loop: read a note, pick a passage, write a comment, send it to this
/// card's agent — and watch the note refresh itself as the agent edits it.
@MainActor
public struct NoteReaderView: View {
    public let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @StateObject private var reader = NoteReaderModel()
    @FocusState private var composeFocused: Bool

    public init(task: Task) { self.task = task }

    public var body: some View {
        content
            .task(id: task.id) { await reader.load(fetch: fetchNotes) }
            // A live change for THIS card. The model holds it while composing so text cannot move
            // under the user mid-sentence.
            .onChange(of: model.noteChanges[task.id]) { _, change in
                guard change != nil else { return }
                _Concurrency.Task { await reader.noteChanged(fetch: fetchNotes) }
            }
            // Events broadcast while the link was down are not replayed, so coming back online
            // reloads once. That is the whole reconnect story — the daemon watches on its own
            // account, so there is no watch to re-register.
            .onChange(of: model.connected) { _, online in
                guard online else { return }
                _Concurrency.Task { await reader.load(fetch: fetchNotes) }
            }
    }

    private func fetchNotes() async -> [NoteFile] { await model.changedNotes(task.id) }

    @ViewBuilder private var content: some View {
        if reader.loading {
            centered { ProgressView() }
        } else if reader.notes.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if reader.notes.count > 1 { fileSwitcher }
                Divider().overlay(theme.hair)
                if let note = reader.current {
                    NoteWebView(markdown: note.content,
                                notePath: note.path,
                                theme: theme,
                                assetProvider: { asset in
                                    await model.noteAsset(task.id, note: note.path, asset: asset)
                                },
                                onSelect: { reader.select($0); composeFocused = true })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if reader.comment != nil { composeBar }
            }
        }
    }

    // MARK: - pieces

    /// Horizontal chip bar over the changed files; each chip is a filename plus its M/A badge.
    private var fileSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(reader.notes, id: \.path) { note in
                    let isSel = note.path == (reader.selectedPath ?? reader.notes.first?.path)
                    Button {
                        // Switching notes drops a half-written comment's anchor: it belongs to the
                        // note it was captured from, and carrying it across files would quote one
                        // note's lines under another note's path.
                        reader.cancelComment()
                        reader.selectedPath = note.path
                    } label: {
                        HStack(spacing: 6) {
                            statusBadge(note.status)
                            Text((note.path as NSString).lastPathComponent)
                                .font(.footnote.weight(isSel ? .semibold : .regular))
                                .foregroundStyle(isSel ? theme.text : theme.text2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(isSel ? theme.chipHover : theme.chip)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    /// A NATIVE compose field. There is deliberately no quote preview: the selected block is already
    /// highlighted in the page, so a preview would only duplicate it.
    private var composeBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.hair)
            HStack(spacing: 8) {
                TextField("Comment on this passage…", text: $reader.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($composeFocused)
                    .font(.callout)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Cancel") { reader.cancelComment(); applyDeferred() }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(theme.text2)

                Button {
                    _Concurrency.Task {
                        await reader.send { message in
                            await model.send(task.id, message)
                            return true
                        }
                        applyDeferred()
                    }
                } label: {
                    Text(reader.sending ? "Sending…" : "Send")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(theme.accent.opacity(reader.canSend ? 1 : 0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                // The ONLY double-send guard. A comment carries no dedup key on purpose: a deliberate
                // re-send is meaningful and must never be silently swallowed.
                .disabled(!reader.canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(theme.card)
        }
    }

    /// Closing the compose field releases any refresh that arrived while it was open.
    private func applyDeferred() {
        _Concurrency.Task { await reader.applyPendingRefresh(fetch: fetchNotes) }
    }

    private var emptyState: some View {
        centered {
            VStack(spacing: 8) {
                Image(systemName: "note.text").font(.system(size: 40)).foregroundStyle(theme.text3)
                Text("No changed notes")
                    .font(.callout.weight(.medium)).foregroundStyle(theme.text2)
                Text(task.origin == .worktree
                     ? "This branch hasn’t added or modified any `.md` notes."
                     : "Notes render for worktree cards only.")
                    .font(.footnote).foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
            }
        }
    }

    private func statusBadge(_ status: NoteStatus) -> some View {
        let c: SemColor = status == .added ? theme.green : theme.amber
        return Text(status.rawValue)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(c.text)
            .frame(width: 18, height: 18)
            .background(c.tint)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func centered<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        body().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
