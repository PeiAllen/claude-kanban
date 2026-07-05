import SwiftUI
import OrchestraKit
import OrchestraUI

// M2 shipped the Agent + Terminal tabs as clearly-marked stubs (design §3's three-tier
// Agent/Terminal/Takeover model). The **Terminal** tab is now built — see `TerminalTab.swift` (T2). The
// **Agent** tab remains a stub here until T3. This file also holds the other deferred hooks the detail
// leaves open: **Recovery** (dead card → M7), **Takeover** (live TUI → T4), and the **Notes page** (M6).

// MARK: - Agent tab (STUB → T3; also hosts the Recovery hook → M7)

/// STUB for the primary **Agent** tab (T3): design §3's non-attaching read/steer surface (capture render
/// + "Message the agent" steer bar; gates surface as Needs You; an explicit **Take Over** is the only path
/// to the live TUI → T4). A `dead` card shows the **Recovery** hook (M7) here instead of agent chrome.
struct AgentTabStub: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        if task.status == .dead {
            RecoveryHook(task: task)
        } else {
            StubScaffold(
                icon: "brain",
                title: "Agent",
                deferredTo: "T3",
                blurb: "The non-attaching read/steer surface: a capture/structured render of the session plus a “Message the agent” bar. Approvals surface in Needs You — never raw keystrokes.",
                livePreview: AnyView(livePreview)
            ) {
                // Take Over hook (T4): the only path that attaches the real TUI, under the daemon's
                // ownership lease. Disabled placeholder in M2 so the seam is visible.
                StubActionRow(icon: "arrow.up.forward.app", label: "Take Over Agent Terminal",
                              note: "Live TUI — built in T4", theme: theme)
            }
        }
    }

    @ViewBuilder private var livePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current activity").font(.caption2.weight(.semibold)).foregroundStyle(theme.text3)
            Text(task.desc.isEmpty ? "—" : task.desc)
                .font(.system(.footnote, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The Terminal tab (T2) is now built — see `TerminalTab.swift`. Its stub lived here in M2.

// MARK: - Recovery hook (→ M7, built)

/// HOOK for the dead-card **Recovery** view: design §3's recovery panel (why it died · preserved work ·
/// original prompt + Copy prompt · Start new / Try resume / Archive). Built in M7 — the real panel lives in
/// `RecoveryView.swift`; this hook just points the dead-card path at it (the stable call site T3 renders).
struct RecoveryHook: View {
    let task: Task
    var body: some View { RecoveryView(task: task) }
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
