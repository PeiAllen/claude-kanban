import SwiftUI
import OrchestraKit
import OrchestraUI

/// The dead-card **Recovery view** (design §3 "Dead card → Recovery view"; mirrors the desktop
/// `App/Views/RecoveryView.swift`). A `dead` card replaces the Agent chrome with this panel:
///
/// - **Why it ended** — a human line per `DeadReason`.
/// - **Preserved work** — repo · branch and the worktree path, with **Copy path** (via the injected
///   `Clipboard`). Deliberately **no** "View changes" / "Reveal in Finder" — those act on the daemon
///   host's local filesystem, which a remote phone client isn't sitting at; viewing changes is the
///   in-app **Diff** tab instead.
/// - **Originally asked** — `task.initialPrompt` (persisted verbatim, survives a dead card) with a
///   **Copy prompt** affordance that grabs it exactly.
/// - **Actions** — **Start new session** (`restart`) · **Try resume** (`resume`, only when a session id
///   exists) · **Archive** (`archive`, then pop the detail).
///
/// Rendered by `AgentTab` for a dead card in the Agent tab.
struct RecoveryView: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.clipboard) private var clipboard: any Clipboard
    @Environment(\.dismiss) private var dismiss

    @State private var resuming = false
    @State private var promptCopied = false
    @State private var pathCopied = false

    private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }

    private var whyLine: String {
        switch task.deadReason {
        case .agentExited:     return "The agent session exited."
        case .sessionVanished: return "The session stopped unexpectedly (crashed or was killed)."
        case .spawnExitedImmediately:
            return "The agent exited right after launching." + (task.deadDetail.map { " \($0)" } ?? "")
        case .rebootUnrevived: return "Lost on reboot and couldn't be auto-resumed."
        case .resumeFailed:    return "A resume attempt failed." + (task.deadDetail.map { " \($0)" } ?? "")
        case .spawnFailed:     return "Creating the workspace failed" + (task.deadDetail.map { " — \($0)" } ?? "") + "."
        case .resourceExhausted:
            // The MACHINE ran out — nothing about this card is broken. Name the resource (with its live
            // numbers when the daemon could take a census) and what to do; the raw tmux/pane evidence goes
            // to `rawDetail` below, small + secondary, because leading with that evidence is how this death
            // used to read as an inscrutable Bun/ENOENT error instead of "your host is out of terminals".
            guard let r = task.deadResource else {
                return "The host ran out of a resource Orchestra needs to start a terminal."
            }
            return "\(r.headline) Orchestra can't start a terminal. \(r.resource.remedy)"
        case .none:            return "The session is no longer running."
        }
    }

    /// The raw evidence, shown small + secondary UNDER the plain-language cause — available for debugging
    /// without being the headline. Only for deaths whose `whyLine` doesn't already inline the detail.
    private var rawDetail: String? {
        guard task.deadReason == .resourceExhausted else { return nil }
        return task.deadDetail
    }

    private var repoName: String { (task.repo as NSString).lastPathComponent }

    private var hasSession: Bool {
        if let sid = task.agentSessionId, !sid.isEmpty { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                preservedWork
                originallyAsked
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg)
    }

    // MARK: why it ended

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(theme.red.dot).frame(width: 9, height: 9)
                Text("Session lost").font(.title3.weight(.semibold)).foregroundStyle(theme.text)
            }
            Text(whyLine).font(.callout).foregroundStyle(theme.text2)
            if let rawDetail {
                Text(rawDetail)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(theme.text3)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: preserved work — repo · branch · path + Copy path

    private var preservedWork: some View {
        panel {
            Text("Your work is preserved in the worktree.")
                .font(.footnote).foregroundStyle(theme.text2)
            Text("\(repoName) · \(task.branch)")
                .font(.system(.footnote, design: .monospaced)).foregroundStyle(theme.text2)
            Text(task.cwd)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(theme.text3)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                clipboard.copy(task.cwd)
                flashPath()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                chip(pathCopied ? "Copied ✓" : "Copy path",
                     systemImage: pathCopied ? "checkmark" : "doc.on.doc",
                     tint: pathCopied ? theme.green.text : theme.text2)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: originally asked — the original prompt + Copy prompt

    private var originallyAsked: some View {
        panel {
            HStack(spacing: 6) {
                Text("Originally asked").font(.footnote.weight(.semibold)).foregroundStyle(theme.text3)
                Spacer(minLength: 8)
                Button {
                    clipboard.copy(task.initialPrompt)
                    flashPrompt()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    chip(promptCopied ? "Copied ✓" : "Copy prompt",
                         systemImage: promptCopied ? "checkmark" : "doc.on.doc",
                         tint: promptCopied ? theme.green.text : theme.text2)
                }
                .buttonStyle(.plain)
            }
            Text(task.initialPrompt.isEmpty ? "—" : task.initialPrompt)
                .font(.callout).foregroundStyle(theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.chip, in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }

    // MARK: actions — Start new / Try resume (if session) / Archive

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                _Concurrency.Task { await model.restart(task.id) }   // toasts; card leaves .dead on success
            } label: {
                actionRow("Start new session", systemImage: "arrow.clockwise",
                          fg: .white, bg: theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(!ds.validActions.contains(.restart))

            if hasSession && ds.validActions.contains(.resume) {
                Button {
                    resuming = true
                    _Concurrency.Task {
                        await model.resume(task.id)   // toasts on failure; card stays .dead
                        resuming = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if resuming { ProgressView().controlSize(.mini) }
                        actionRow("Try resume", systemImage: "arrow.uturn.backward",
                                  fg: theme.text, bg: theme.card, hair: true)
                    }
                }
                .buttonStyle(.plain)
                .disabled(resuming)
            }

            Button {
                _Concurrency.Task { await model.archive(task.id); dismiss() }
            } label: {
                actionRow("Archive", systemImage: "archivebox", fg: theme.red.text,
                          bg: theme.card, hair: true)
            }
            .buttonStyle(.plain)
            .disabled(!ds.validActions.contains(.archive))
        }
        .padding(.top, 2)
    }

    // MARK: chrome

    /// A rounded card panel wrapping a leading-aligned column of content (matches the iOS detail idiom).
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hair, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A compact chip button label (leading glyph + text) for the Copy affordances.
    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(theme.chip, in: Capsule())
        .contentShape(Capsule())
    }

    /// A full-width primary/secondary action row.
    private func actionRow(_ title: String, systemImage: String, fg: Color, bg: Color,
                           hair: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if hair { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hair, lineWidth: 0.5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func flashPath() {
        pathCopied = true
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(1.4))
            pathCopied = false
        }
    }

    private func flashPrompt() {
        promptCopied = true
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(1.4))
            promptCopied = false
        }
    }
}
