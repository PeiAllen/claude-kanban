import SwiftUI
import OrchestraUI
import OrchestraCore

/// The "Done" / Archive popover listing archived tasks. ui-spec §3.8 / §4.9.
struct DonePopover: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("DONE").font(F.ui(11, .semibold)).tracking(0.8).foregroundColor(theme.text2)
                Spacer(minLength: 0)
                Text("\(model.archived.count) tasks").font(F.ui(11)).foregroundColor(theme.text2)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if model.archived.isEmpty {
                Text("No archived tasks yet")
                    .font(F.ui(11.5)).foregroundColor(theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    // A long-lived board can have hundreds of archived cards. Keep the native popover's
                    // opening and in-row interactions proportional to its viewport, not archive history.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.archived.enumerated()), id: \.element.id) { idx, t in
                            ArchiveRow(task: t)
                            if idx < model.archived.count - 1 {
                                Rectangle().fill(theme.hair).frame(height: 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 460)
        // Hosted in a native `.popover` (anchored to the Done button), which supplies the bubble,
        // arrow, and shadow — so the content only needs to fill itself with the panel color.
        .background(theme.panelOpaque)
    }
}

struct ArchiveRow: View {
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var initials: String {
        let words = task.title.split(separator: " ").prefix(2)
        let s = words.map { String($0.prefix(1)) }.joined()
        return s.isEmpty ? "·" : s.uppercased()
    }
    private var repoName: String { (task.repo as NSString).lastPathComponent }
    private var age: String {
        let secs = Int(Date().timeIntervalSince(task.updatedAt))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(initials)
                    .font(F.mono(9, .heavy)).foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(theme.gray.dot)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(F.ui(12.5, .semibold)).foregroundColor(theme.text).lineLimit(1)
                    Text("\(repoName) · \(age)").font(F.mono(10.5)).foregroundColor(theme.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Action row (ui-spec §4.9): chat-link (agent/session id) + branch, both copyable, plus
            // Reopen — the daemon recreates the worktree + resumes the agent, bringing the card back live.
            HStack(spacing: 6) {
                CopyChip(icon: "link", label: "\(task.agentId)/\(task.shortId)", value: task.ref())
                CopyChip(icon: "doc.on.doc", label: task.branch, value: task.branch)
                Spacer(minLength: 0)
                ReopenButton(task: task)
            }
            .padding(.leading, 32)
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
    }
}

/// The "Reopen" action on an archived row: brings the Done card back onto the board (the daemon
/// recreates its worktree + resumes the agent). Styled as an accent pill so it reads as the row's
/// primary action next to the muted copy chips.
private struct ReopenButton: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    var body: some View {
        Button {
            _Concurrency.Task { await model.reopen(task.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.left").font(F.ui(8.5, .semibold))
                Text("Reopen").font(F.ui(10.5, .semibold))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 9).frame(height: 22)
            .surface(theme.chip, corner: 6, hair: theme.hair)
        }
        .buttonStyle(.plain)
        .help("Reopen “\(task.title)” — recreate its worktree and resume the agent")
    }
}

/// A small pill that copies `value` to the pasteboard and flashes a checkmark. Used for the
/// archive row's chat-link + branch buttons (ui-spec §4.9).
private struct CopyChip: View {
    @Environment(\.theme) var theme: Theme
    let icon: String
    let label: String
    let value: String

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            _Concurrency.Task {
                try? await _Concurrency.Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : icon)
                    .font(F.ui(8.5))
                    .foregroundColor(copied ? theme.green.dot : theme.text3)
                Text(label).font(F.mono(10)).foregroundColor(theme.text2).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 22)
            .surface(theme.chip, corner: 6, hair: theme.hair)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : "Copy \(value)")
    }
}
