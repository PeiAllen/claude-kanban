import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **card detail** (design §3): a tabbed full-screen surface pushed from a board card tap. A pinned
/// header (title · status · model · context gauge · breadcrumb) sits above a six-tab bar
/// **Agent · Terminal · Diff · Notes · Inbox · Info**. Agent is the primary read/steer surface (T3);
/// Terminal is a clearly-marked stub (T2); Diff, Inbox, and Info are built here; Notes (M6) renders the
/// `.md` notes this branch changed.
///
/// Keyed on the card **id**, not a snapshot: the live `Task` is resolved from `BoardModel` on every render
/// so the header pill/gauge and the tabs stay reactive as the daemon streams events. If the card leaves
/// the board (archived/removed elsewhere), the view shows a closed-state placeholder.
struct CardDetailView: View {
    let taskId: UUID
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    // Agent is the design-primary tab (§3); it ships as a stub in M2 but remains the honest landing tab.
    // `CardTab.initial` honors an ORCH_DEV_CARD_TAB override for deterministic headless screenshots.
    @State private var tab: CardTab = .initial
    /// A transient route anchored to a terminal/capture marker. It is intentionally owned by the card
    /// detail so every activation surface resolves the same card-scoped daemon media reference.
    @State private var imageRoute: TranscriptImageRoute?

    /// The live card, resolved fresh each render from the board (then the Done archive).
    private var task: Task? {
        model.tasks.first { $0.id == taskId } ?? model.archived.first { $0.id == taskId }
    }

    var body: some View {
        Group {
            if let task {
                VStack(spacing: 0) {
                    CardDetailHeader(task: task, connection: model.connectionState)
                    CardTabBar(selection: $tab)
                    Divider().overlay(theme.hair)
                    tabBody(task)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                closedPlaceholder
            }
        }
        .background(theme.winBg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)   // full-screen: hide the app's bottom tab bar while in a card
        .fullScreenCover(item: $imageRoute) { route in
            MobileTranscriptImagePreview(route: route)
                .environmentObject(model)
        }
    }

    @ViewBuilder private func tabBody(_ task: Task) -> some View {
        switch tab {
        case .agent:    AgentTab(task: task, onOpenImage: { openImage($0, for: task) })
        case .terminal: TerminalTab(task: task, onOpenImage: { openImage($0, for: task) })
        case .diff:     DiffTab(task: task)
        case .documents: DocumentsPage(task: task)
        case .inbox:    InboxTab(task: task)
        case .info:     InfoTab(task: task)
        }
    }

    private func openImage(_ referenceID: UUID, for task: Task) {
        imageRoute = TranscriptImageRoute(cardID: task.id, referenceID: referenceID)
    }

    private var closedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 40)).foregroundStyle(theme.text3)
            Text("Card closed").font(.headline).foregroundStyle(theme.text)
            Text("This card was archived or removed. Go back to the board.")
                .font(.footnote).foregroundStyle(theme.text2).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab bar

/// The six-tab segmented bar under the pinned header. Custom (not a native `Picker`) so it carries the
/// Orchestra chip language + SF-symbol-over-label and fits its segments at phone width.
private struct CardTabBar: View {
    @Binding var selection: CardTab
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CardTab.allCases) { t in
                let active = t == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 15, weight: active ? .semibold : .regular))
                        Text(t.title).font(.system(size: 10, weight: active ? .semibold : .regular))
                    }
                    .foregroundStyle(active ? theme.accent : theme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(active ? theme.accent.opacity(0.12) : .clear,
                               in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.card)
    }
}
