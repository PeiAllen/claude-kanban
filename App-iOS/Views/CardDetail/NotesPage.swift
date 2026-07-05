import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **Notes page** (design §3): a pushed, full-screen renderer of the markdown notes this branch
/// changed — the phone-native equivalent of the desktop's "Open notes" (which opens the worktree's
/// changed/new `notes/*.md` as Obsidian tabs; there's no Obsidian on the phone, so it renders in-app).
/// A **file switcher** lists the changed/new `.md` files each with an `M`/`A` badge; the selected file
/// renders as styled markdown via `MarkdownView`. Sourced from M6a's `changedNotes` RPC (`[NoteFile]`).
struct NotesPage: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var notes: [NoteFile] = []
    @State private var selected: String?   // NoteFile.path
    @State private var loading = true

    private var current: NoteFile? {
        notes.first { $0.path == selected } ?? notes.first
    }

    var body: some View {
        content
            .background(theme.winBg)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: task.id) { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            centered { ProgressView() }
        } else if notes.isEmpty {
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
        } else {
            VStack(spacing: 0) {
                if notes.count > 1 { fileSwitcher }
                Divider().overlay(theme.hair)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let file = current { fileHeader(file) }
                        MarkdownView(markdown: current?.content ?? "")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Horizontal chip bar over the changed files — each chip is a filename + M/A badge; the selected
    /// chip is highlighted. Only shown when there's more than one file.
    private var fileSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(notes, id: \.path) { note in
                    let isSel = note.path == (selected ?? notes.first?.path)
                    Button {
                        selected = note.path
                    } label: {
                        HStack(spacing: 6) {
                            statusBadge(note.status)
                            Text(filename(note.path))
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

    /// Full relative path (dimmed dir + bold filename) plus the M/A badge, above the rendered content.
    private func fileHeader(_ file: NoteFile) -> some View {
        HStack(spacing: 8) {
            statusBadge(file.status)
            filePath(file.path)
            Spacer(minLength: 0)
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

    private func filePath(_ path: String) -> Text {
        guard let slash = path.lastIndex(of: "/") else {
            return Text(path).font(.footnote.weight(.semibold)).foregroundColor(theme.text)
        }
        let dir = String(path[...slash]); let name = String(path[path.index(after: slash)...])
        return Text(dir).font(.footnote).foregroundColor(theme.text3)
             + Text(name).font(.footnote.weight(.semibold)).foregroundColor(theme.text)
    }

    private func filename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func load() async {
        loading = true
        let fetched = await model.changedNotes(task.id)
        notes = fetched
        if selected == nil || !fetched.contains(where: { $0.path == selected }) {
            selected = fetched.first?.path
        }
        loading = false
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
