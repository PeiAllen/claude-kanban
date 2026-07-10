import SwiftUI
import OrchestraUI
import AppKit
import OrchestraCore

/// The "Session lost" recovery panel shown in place of the terminal when a card is `dead`.
/// ui-spec §4.6 (forward-looking proposal, implemented here).
struct RecoveryView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    @State private var resuming = false
    @State private var promptCopied = false

    private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }

    private var whyLine: String {
        switch task.deadReason {
        case .agentExited:     return "The agent exited."
        case .sessionVanished: return "The session stopped unexpectedly (crashed or was killed)."
        case .rebootUnrevived: return "Lost on reboot and couldn't be auto-resumed."
        case .resumeFailed:    return "Resume failed — \(task.deadDetail ?? "")."
        case .completed:       return "The agent completed its work."
        case .spawnFailed:     return "Creating the workspace failed" + (task.deadDetail.map { " — \($0)" } ?? "") + "."
        case .none:            return "The session is no longer running."
        }
    }

    private var repoName: String { (task.repo as NSString).lastPathComponent }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(theme.red.dot).frame(width: 8, height: 8)
                        Text("Session lost").font(F.ui(15, .bold)).foregroundColor(theme.text)
                    }

                    Text(whyLine).font(F.ui(12.5)).foregroundColor(theme.text2)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your work is preserved in the worktree.")
                            .font(F.ui(11.5)).foregroundColor(theme.text2)
                        Text("\(repoName) · \(task.branch)")
                            .font(F.mono(11)).foregroundColor(theme.text2)
                        Text(task.cwd)
                            .font(F.mono(10.5)).foregroundColor(theme.text3).lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 6) {
                            Button {
                                _Concurrency.Task { await model.openInZed(task.id) }
                            } label: {
                                miniLabel(text: "View changes") { ZedBadge(size: 13, corner: 3, glyph: 8) }
                            }
                            .buttonStyle(.plain)
                            miniButton("Reveal in Finder", "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: task.cwd)])
                            }
                            miniButton("Copy path", "doc.on.doc") { copy(task.cwd) }
                        }
                        .padding(.top, 2)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Originally asked:").font(F.ui(11, .semibold)).foregroundColor(theme.text3)
                            Spacer(minLength: 0)
                            Button { copyPrompt() } label: {
                                miniLabel(text: promptCopied ? "Copied" : "Copy prompt") {
                                    Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                                        .font(F.ui(9.5))
                                        .foregroundColor(promptCopied ? theme.green.dot : theme.text2)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(promptCopied ? "Copied!" : "Copy prompt")
                        }
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
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ds.validActions.contains(.restart))

                        Button {
                            _Concurrency.Task { await model.archive(task.id) }
                        } label: {
                            Text("Archive").font(F.ui(12, .medium)).foregroundColor(theme.text2)
                                .padding(.horizontal, 12).frame(height: 29)
                                .surface(theme.card, corner: 8, hair: theme.hair)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ds.validActions.contains(.archive))

                        if task.agentSessionId != nil && ds.validActions.contains(.resume) {
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
                                .contentShape(Rectangle())
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

            // Close button, top-right of the panel (the recovery view owns the whole sidebar now).
            Button { model.selectedId = nil } label: {
                Image(systemName: "xmark").font(F.ui(11, .semibold))
                    .foregroundColor(theme.text2)
                    .frame(width: 29, height: 29)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12).padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.inspector)
    }

    private func miniButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            miniLabel(text: label) { Image(systemName: icon).font(F.ui(9.5)) }
        }
        .buttonStyle(.plain)
    }

    /// Shared chrome for the compact worktree-action buttons (leading glyph + label in a chip).
    private func miniLabel<Leading: View>(text: String, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 4) {
            leading()
            Text(text).font(F.ui(11, .medium))
        }
        .foregroundColor(theme.text2)
        .padding(.horizontal, 9).frame(height: 24)
        .surface(theme.chip, corner: 7, hair: theme.hair)
        .contentShape(Rectangle())
    }

    private func copyPrompt() {
        copy(task.initialPrompt)
        promptCopied = true
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: 1_200_000_000)
            promptCopied = false
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
