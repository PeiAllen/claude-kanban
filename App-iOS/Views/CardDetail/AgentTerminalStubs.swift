import SwiftUI
import OrchestraKit
import OrchestraUI

// The Terminal tab is OUT OF SCOPE for M2 — T2 builds it (design §3's three-tier Agent/Terminal/Takeover
// model). M2 ships it as a clearly-marked stub so the tabbed shell is complete and the seam is obvious.
// The real **Agent** tab lives in `AgentTab.swift` (T3). This file also holds the deferred hooks the detail
// leaves open: **Recovery** (dead card → M7; consumed by the Agent tab) and the **Notes page** (M6).

// MARK: - Terminal tab (STUB → T2)

/// STUB for the secondary **Terminal** tab (T2): design §3's block REPL by default (a "Run a command…"
/// field → one-shot `exec` → a copyable output block) with an opt-in **Attach live shell** into a
/// phone-owned `shell` window. No PTY / tmux / key bar in the default view.
struct TerminalTabStub: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        StubScaffold(
            icon: "terminal",
            title: "Terminal",
            deferredTo: "T2",
            blurb: "A block REPL: run one-shot commands in the worktree and get a copyable output block — no PTY, no tmux, no sizing fight with the desktop.",
            livePreview: nil
        ) {
            StubActionRow(icon: "bolt.horizontal", label: "Attach live shell",
                          note: "Phone-owned PTY — built in T2", theme: theme)
        }
    }
}

// MARK: - Recovery hook (→ M7)

/// HOOK for the dead-card **Recovery** view (M7): design §3's recovery panel (why it died · preserved work
/// · original prompt + Copy prompt · Start new / Try resume / Archive). M2 leaves the hook — it surfaces
/// *why* the card died and marks where M7 builds — but does not implement the recovery actions.
struct RecoveryHook: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    private var reason: String {
        switch task.deadReason {
        case .agentExited:     return "The agent session exited."
        case .sessionVanished: return "The session vanished (crash or external kill)."
        case .rebootUnrevived: return "A reboot couldn't auto-revive the session."
        case .resumeFailed:    return "A resume attempt failed." + (task.deadDetail.map { " \($0)" } ?? "")
        case .none:            return "The session is no longer running."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.slash.circle").font(.system(size: 44)).foregroundStyle(theme.red.dot)
            Text("Card died").font(.title3.weight(.semibold)).foregroundStyle(theme.text)
            Text(reason).font(.callout).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Text("The worktree’s work is intact. The full Recovery view — preserved work, the original prompt with Copy, and Start new / Try resume / Archive — is built in M7.")
                .font(.footnote).foregroundStyle(theme.text3)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            deferredBadge("M7", theme: theme)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg)
    }
}

// MARK: - Notes page hook (→ M6)

/// HOOK for the **Notes page** (M6): design §3's in-app renderer of the markdown notes this branch
/// changed (file switcher + rendered markdown). M2 leaves the navigation hook — Info's "Open notes" pushes
/// here — and marks where M6 builds it.
struct NotesPageHook: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "note.text").font(.system(size: 44)).foregroundStyle(theme.text3)
            Text("Notes").font(.title3.weight(.semibold)).foregroundStyle(theme.text)
            Text("Renders the markdown notes this branch changed — a file switcher over the changed/new `.md` files, each rendered in-app (no Obsidian on the phone). Built in M6.")
                .font(.footnote).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            deferredBadge("M6", theme: theme)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg)
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared stub chrome

/// A consistent "this tab ships later" scaffold: an icon + title, a deferred badge, a blurb of what will
/// live here, an optional live preview, and the deferred action row(s) that mark the seam.
private struct StubScaffold<Actions: View>: View {
    let icon: String
    let title: String
    let deferredTo: String
    let blurb: String
    var livePreview: AnyView? = nil
    @ViewBuilder var actions: Actions
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 40)).foregroundStyle(theme.text3).padding(.top, 32)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(theme.text)
                deferredBadge(deferredTo, theme: theme)
                Text(blurb).font(.footnote).foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                if let livePreview {
                    livePreview
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hair, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                }
                VStack(spacing: 8) { actions }.padding(.horizontal, 20)
                Spacer(minLength: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg)
    }
}

/// A disabled affordance that names a deferred capability and where it's built (the visible seam).
private struct StubActionRow: View {
    let icon: String
    let label: String
    let note: String
    let theme: Theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium)).foregroundStyle(theme.text2)
                Text(note).font(.caption2).foregroundStyle(theme.text3)
            }
            Spacer()
            Image(systemName: "hammer").font(.caption).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hair, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(0.85)
    }
}

/// A small "Built in <PR>" capsule.
private func deferredBadge(_ pr: String, theme: Theme) -> some View {
    Text("Built in \(pr)")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(theme.text2)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(theme.chip))
}
