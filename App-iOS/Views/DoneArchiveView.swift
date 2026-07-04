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
    }

    private func reopen(_ task: Task) {
        _Concurrency.Task {
            await model.reopen(task.id)
            dismiss()   // pop back to the board so the reopened card is visible in its column
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
