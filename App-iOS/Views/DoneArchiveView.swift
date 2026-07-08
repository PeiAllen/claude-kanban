import SwiftUI
import OrchestraKit
import OrchestraUI

/// Done archive (design §2b) — a pushed screen listing finished/archived agents, each with **Reopen**
/// (the daemon recreates the worktree + resumes). Deliberately *not* a pager column: Done is an archive,
/// matching the desktop. Reached from the Board nav bar's Done button (`‹ Board` back is automatic).
struct DoneArchiveView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.dismiss) private var dismiss
    // The reopened card to open once this screen has popped. Set on a successful reopen and consumed in
    // `onDisappear`, so the board → card-detail push happens AFTER the Done pop rather than racing it
    // (a push fired in the same navigation frame as the pop blanks the whole screen — the original bug).
    @State private var pendingOpen: UUID?

    var body: some View {
        Group {
            if model.archived.isEmpty {
                ContentUnavailableView("Nothing archived",
                                       systemImage: "archivebox",
                                       description: Text("Finished agents you archive appear here."))
            } else {
                List {
                    ForEach(model.archived) { task in
                        DoneRow(task: task) { reopen(task) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(theme.winBg.ignoresSafeArea())
        .navigationTitle("Done")
        .navigationBarTitleDisplayMode(.inline)
        // Once Done has popped, open the reopened card's detail. Deferred one runloop turn (the `Task` hop)
        // so the selection lands in a fresh navigation transaction, not the pop's — the board is already
        // the top of the stack, so this is a clean single board → detail push.
        .onDisappear {
            guard let id = pendingOpen else { return }
            pendingOpen = nil
            _Concurrency.Task { @MainActor in model.selectedId = id }
        }
    }

    private func reopen(_ task: Task) {
        _Concurrency.Task {
            // On failure `reopen` returns nil (and shows a toast) — stay on the Done list, open nothing.
            guard let reopened = await model.reopen(task.id) else { return }
            pendingOpen = reopened.id
            dismiss()   // pop back to the board; `onDisappear` then opens the reopened card's detail
        }
    }
}

private struct DoneRow: View {
    let task: Task
    let onReopen: () -> Void
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.headline).foregroundStyle(theme.text).lineLimit(1)
                Text(pathLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onReopen) {
                Label("Reopen", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var pathLabel: String {
        task.origin == .worktree
            ? "\((task.repo as NSString).lastPathComponent)/\(task.branch)"
            : (task.cwd as NSString).lastPathComponent
    }
}
