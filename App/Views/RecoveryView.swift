import SwiftUI
import OrchestraCore

/// The "Session lost" recovery panel shown in place of the terminal when a card is `dead`.
/// ui-spec §4.6 (forward-looking proposal, implemented here).
struct RecoveryView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    @State private var resuming = false

    private var whyLine: String {
        switch task.deadReason {
        case .agentExited:     return "The agent exited."
        case .sessionVanished: return "The session stopped unexpectedly (crashed or was killed)."
        case .rebootUnrevived: return "Lost on reboot and couldn't be auto-resumed."
        case .resumeFailed:    return "Resume failed — \(task.deadDetail ?? "")."
        case .none:            return "The session is no longer running."
        }
    }

    private var repoName: String { (task.repo as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(theme.red.dot).frame(width: 8, height: 8)
                    Text("Session lost").font(F.ui(15, .bold)).foregroundColor(theme.text)
                }

                Text(whyLine).font(F.ui(12.5)).foregroundColor(theme.text2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your work is preserved in the worktree.")
                        .font(F.ui(11.5)).foregroundColor(theme.text2)
                    Text("\(repoName) · \(task.branch)")
                        .font(F.mono(11)).foregroundColor(theme.text2)
                    Text(task.worktree)
                        .font(F.mono(10.5)).foregroundColor(theme.text3).lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Originally asked:").font(F.ui(11, .semibold)).foregroundColor(theme.text3)
                    Text(task.initialPrompt)
                        .font(F.ui(12)).foregroundColor(theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Button {
                        _Concurrency.Task { await model.restart(task.id) }
                    } label: {
                        Text("Start new session").font(F.ui(12, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 29)
                            .background(theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        _Concurrency.Task { await model.archive(task.id) }
                    } label: {
                        Text("Archive").font(F.ui(12, .medium)).foregroundColor(theme.text2)
                            .padding(.horizontal, 12).frame(height: 29)
                            .surface(theme.card, corner: 8, hair: theme.hair)
                    }
                    .buttonStyle(.plain)

                    if task.agentSessionId != nil {
                        Button {
                            resuming = true
                            _Concurrency.Task {
                                await model.resume(task.id)   // toasts on failure; card stays .dead
                                resuming = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if resuming { ProgressView().controlSize(.small) }
                                Text("Try resume").font(F.ui(12, .medium)).foregroundColor(theme.text2)
                            }
                            .padding(.horizontal, 12).frame(height: 29)
                            .surface(theme.card, corner: 8, hair: theme.hair)
                        }
                        .buttonStyle(.plain)
                        .disabled(resuming)
                    }
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.termBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .hairline(theme.hair, corner: 10)
    }
}
