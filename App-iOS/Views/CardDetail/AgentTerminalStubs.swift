import SwiftUI
import OrchestraKit
import OrchestraUI

// M2 shipped the tabbed shell. The **Agent** tab now lives in `AgentTab.swift` (T3) and the **Terminal**
// tab in `TerminalTab.swift` (T2) — both real (design §3's three-tier Agent/Terminal/Takeover model). The
// **Notes page** (M6) is now built too — see `NotesPage.swift`. The one remaining hook this file holds is
// **Recovery** (dead card → M7; consumed by the Agent tab).

// The Terminal tab (T2) is now built — see `TerminalTab.swift`. Its stub lived here in M2.

// MARK: - Recovery hook (→ M7, built)

/// HOOK for the dead-card **Recovery** view: design §3's recovery panel (why it died · preserved work ·
/// original prompt + Copy prompt · Start new / Try resume / Archive). Built in M7 — the real panel lives in
/// `RecoveryView.swift`; this hook just points the dead-card path at it (the stable call site T3 renders).
struct RecoveryHook: View {
    let task: Task
    var body: some View { RecoveryView(task: task) }
}

// The Notes page (M6) is now built — see `NotesPage.swift` (rendered in-app; Info's "Open notes" pushes
// it). Its hook lived here in M2.

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
