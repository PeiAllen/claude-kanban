import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **Info** tab (design §3): card metadata + the phone-native actions. Grouped inset lists, iOS-idiom.
///
/// Metadata: **Mode** (`CardOrigin`: worktree / borrowed / scratch) + **Access** (`CardAccess`), the
/// session id, repo/branch/path. Actions: **Restart session** (`restart`), **Copy branch name** (via the
/// injected `Clipboard`), **Archive** (confirm → `archive`), and **Open notes** — pushes the in-app
/// **Notes page** (M6), which renders the markdown notes this branch changed. Deliberately **no** "View
/// changes in Zed" / "Reveal in Finder" (host-only, dropped — the Diff tab is the phone's view-changes path).
struct InfoTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.clipboard) private var clipboard: any Clipboard
    @Environment(\.dismiss) private var dismiss

    @State private var confirmArchive = false
    @State private var copied: String?   // transient "Copied ✓" feedback keyed by which row
    @State private var showNotes = false  // pushes the Notes page (also driven by ORCH_DEV_OPEN_NOTES)

    var body: some View {
        List {
            metadataSection
            sessionSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.winBg)
        .navigationDestination(isPresented: $showNotes) { NotesPage(task: task) }
        .onAppear {
            // Dev-only headless deep-link into the pushed Notes page (mirrors ORCH_DEV_OPEN_CARD/_SPAWN).
            if ProcessInfo.processInfo.environment["ORCH_DEV_OPEN_NOTES"] == "1" { showNotes = true }
        }
        .confirmationDialog("Archive this card?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                _Concurrency.Task { await model.archive(task.id); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the board for Done. The worktree is preserved; Reopen recreates it.")
        }
    }

    // MARK: metadata — Mode + Access

    private var metadataSection: some View {
        Section("Card") {
            infoRow("Mode", value: modeLabel, systemImage: modeSymbol)
            infoRow("Access", value: task.access == .readOnly ? "Read-only" : "Read-write",
                    systemImage: task.access == .readOnly ? "lock" : "lock.open")
            if task.origin == .worktree {
                infoRow("Repo", value: (task.repo as NSString).lastPathComponent, systemImage: "shippingbox")
                copyableRow("Branch", value: task.branch, systemImage: "arrow.branch")
            }
            copyableRow("Path", value: task.cwd, systemImage: "folder", mono: true)
        }
    }

    private var modeLabel: String {
        switch task.origin {
        case .worktree: return "Worktree"
        case .borrowed: return "Freeform"   // "borrowed" is never surfaced (§2a)
        case .scratch:  return "Scratch"
        }
    }
    private var modeSymbol: String {
        switch task.origin {
        case .worktree: return "point.3.connected.trianglepath.dotted"
        case .borrowed: return "folder"
        case .scratch:  return "sparkles"
        }
    }

    // MARK: session

    private var sessionSection: some View {
        Section("Session") {
            if let sid = task.agentSessionId, !sid.isEmpty {
                copyableRow("Session id", value: sid, systemImage: "number", mono: true)
            } else {
                infoRow("Session id", value: "—", systemImage: "number")
            }
            infoRow("Agent", value: task.agentId, systemImage: "cpu")
        }
    }

    // MARK: actions

    private var actionsSection: some View {
        Section {
            // Restart session — a fresh agent session (clears context). Direct, with feedback.
            Button {
                _Concurrency.Task { await model.restart(task.id) }
                flash("restart")
            } label: {
                actionLabel(copied == "restart" ? "Started a new session" : "Restart session",
                            systemImage: "arrow.clockwise", tint: theme.text)
            }

            // Copy branch name — the injected iOS clipboard.
            if task.origin == .worktree {
                Button {
                    clipboard.copy(task.branch)
                    flash("branch")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    actionLabel(copied == "branch" ? "Copied ✓" : "Copy branch name",
                                systemImage: "doc.on.doc", tint: theme.text)
                }
            }

            // Copy chat link — the desktop's "Copy chat link": the card ref (`orchestra://task/<shortId>-<slug>`).
            // Identical string to the Mac app so the two are interchangeable.
            Button {
                clipboard.copy(task.ref())
                flash("chatLink")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                actionLabel(copied == "chatLink" ? "Copied ✓" : "Copy chat link",
                            systemImage: "link", tint: theme.text)
            }

            // Copy tmux target — the desktop's "Copy tmux target": `orchestra-<uuid>:agent`, the exact
            // `tmux attach -t` target for the agent window.
            Button {
                clipboard.copy("\(task.tmuxSession):agent")
                flash("tmux")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                actionLabel(copied == "tmux" ? "Copied ✓" : "Copy tmux target",
                            systemImage: "terminal", tint: theme.text)
            }

            // Open notes — the in-app Notes page (M6): renders the markdown notes this branch changed.
            Button {
                showNotes = true
            } label: {
                actionLabel("Open notes", systemImage: "note.text", tint: theme.text, chevron: false)
            }

            // Archive — confirmed, destructive.
            Button(role: .destructive) {
                confirmArchive = true
            } label: {
                actionLabel("Archive", systemImage: "archivebox", tint: theme.red.text)
            }
        } footer: {
            Text("Hand off · Fork · Fan-out are agent/CLI moves, not surfaced here. Viewing changes is the Diff tab.")
        }
    }

    // MARK: row builders

    private func infoRow(_ label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: systemImage).labelStyle(.titleAndIcon)
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
        }
    }

    /// A metadata row that copies its value on tap (branch, path, session id).
    private func copyableRow(_ label: String, value: String, systemImage: String, mono: Bool = false) -> some View {
        Button {
            clipboard.copy(value)
            flash(label)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 10) {
                Label(label, systemImage: systemImage).labelStyle(.titleAndIcon).foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Text(copied == label ? "Copied ✓" : value)
                    .font(mono ? .system(.callout, design: .monospaced) : .callout)
                    .foregroundStyle(copied == label ? theme.green.text : theme.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, systemImage: String, tint: Color, chevron: Bool = false) -> some View {
        Label(title, systemImage: systemImage).foregroundStyle(tint)
    }

    /// Briefly show "Copied ✓" / confirmation text on a row, then clear it.
    private func flash(_ key: String) {
        copied = key
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(1.6))
            if copied == key { copied = nil }
        }
    }
}
