import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// The Board home (design §2): a swipeable full-width column pager **Freeform · Plan · Impl · Review**
/// with a segmented per-page-count indicator up top, off the shared `BoardModel`. Replaces F3's flat
/// list. The nav bar carries **Activity** + **Done**, each a pushed screen within the Board tab.
struct BoardTab: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.colorScheme) private var scheme
    // Land on Plan — the start of the lifecycle; Freeform is one swipe left, Review two right.
    // (A dev/test `ORCH_DEV_BOARD_PAGE` env can override the initial page for headless screenshots.)
    @State private var page: BoardPage = .initial
    @State private var showDone = false
    @State private var showActivity = false
    /// Guards the one-shot dev auto-open (below) so it fires once, not on every card-list change.
    @State private var autoOpened = false

    private var theme: Theme { Theme(scheme: scheme, accent: model.accent) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner(state: model.connectionState)
                PagerHeader(page: $page, counts: counts)
                TabView(selection: $page) {
                    ForEach(BoardPage.allCases) { p in
                        BoardPageView(page: p).tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(theme.winBg.ignoresSafeArea())
            .navigationTitle("Orchestra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showActivity = true } label: { Image(systemName: "waveform") }
                        .accessibilityLabel("Activity")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDone = true } label: { Image(systemName: "archivebox") }
                        .accessibilityLabel("Done")
                }
                // The Spawn (+) — M1 deliberately left this out; M4 adds it. Seeds the sheet's Start-in
                // from the current lifecycle page and defaults to Freeform mode when launched from the
                // Freeform page, then presents the spawn sheet (design §1 / §4).
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.spawnDefaultColumn = page.column ?? .plan
                        model.showSpawn = true
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Spawn")
                }
            }
            .navigationDestination(isPresented: $showActivity) { ActivityFeedView() }
            .navigationDestination(isPresented: $showDone) { DoneArchiveView() }
            // Card tap → push the tabbed card detail (design §3). Driven off `selectedId` (reachable from
            // any nested card, and auto-cleared on back), so no binding is threaded down the pager.
            .navigationDestination(item: selectedCardBinding) { id in
                CardDetailView(taskId: id)
            }
            // The nav-bar + presents the spawn sheet (design §4), off the shared `showSpawn` flag so the
            // sheet stays the single source of truth. Default mode follows the page it was launched from.
            .sheet(isPresented: $model.showSpawn) {
                SpawnSheet(startFreeform: page.isFreeform)
            }
        }
        .environment(\.theme, theme)
        // Dev/headless hook (mirrors ORCH_DEV_BOARD_PAGE): auto-open a card's detail once the board has
        // loaded, so a Simulator screenshot can capture the detail/Diff/Inbox deterministically. Absent
        // the env, this returns immediately (production no-op). Fires once via `autoOpened`.
        .task { await autoOpenCardIfDev() }
        #if DEBUG
        // Headless-screenshot hook: `ORCH_DEV_OPEN_SPAWN=1` presents the spawn sheet on launch so a
        // Simulator shot can capture it (mode + freeform cwd come from ORCH_SPAWN_MODE/ORCH_SPAWN_CWD,
        // read inside SpawnSheet). Production no-op without the env.
        .onAppear {
            if ProcessInfo.processInfo.environment["ORCH_DEV_OPEN_SPAWN"] == "1" { model.showSpawn = true }
        }
        #endif
    }

    /// A `UUID?` binding over `model.selectedId` — the card whose detail is pushed. `navigationDestination`
    /// sets it to `nil` on back, so re-tapping the same card re-pushes.
    private var selectedCardBinding: Binding<UUID?> {
        Binding(get: { model.selectedId }, set: { model.selectedId = $0 })
    }

    /// One-shot dev auto-open: if `ORCH_DEV_OPEN_CARD` is set (`"1"`/`"first"` ⇒ the initial page's first
    /// card; otherwise a shortId to match), select it so the detail pushes. Waits briefly for the board to
    /// load so it's not racy on a warm reconnect. Deterministic headless screenshots only — returns
    /// immediately (no effect) when the env is unset.
    private func autoOpenCardIfDev() async {
        guard let want = ProcessInfo.processInfo.environment["ORCH_DEV_OPEN_CARD"], !want.isEmpty else { return }
        for _ in 0..<40 {   // up to ~6s for the first board list to arrive
            if !autoOpened, !model.tasks.isEmpty {
                let onPage = page.isFreeform ? model.freeformTasks : model.cards(in: page.column ?? .plan)
                let pool = onPage.isEmpty ? model.tasks : onPage
                let card = (want == "1" || want == "first") ? pool.first
                         : pool.first { $0.shortId == want } ?? model.tasks.first { $0.shortId == want }
                if let card { model.selectedId = card.id; autoOpened = true }
                return
            }
            try? await _Concurrency.Task.sleep(for: .milliseconds(150))
        }
    }

    /// Live per-page card counts for the segmented indicator.
    private var counts: [BoardPage: Int] {
        [.freeform: model.freeformTasks.count,
         .plan:   model.cards(in: .plan).count,
         .impl:   model.cards(in: .impl).count,
         .review: model.cards(in: .review).count]
    }
}

// MARK: - Segmented per-page-count indicator

private struct PagerHeader: View {
    @Binding var page: BoardPage
    let counts: [BoardPage: Int]
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BoardPage.allCases) { p in
                let active = p == page
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { page = p }
                } label: {
                    HStack(spacing: 5) {
                        Text(p.title).font(.footnote.weight(active ? .semibold : .regular))
                        Text("\(counts[p] ?? 0)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(active ? theme.accent.opacity(0.20) : theme.chip))
                    }
                    .foregroundStyle(active ? theme.text : theme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(active ? theme.chip : .clear,
                               in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - One pager page

private struct BoardPageView: View {
    let page: BoardPage
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private var cards: [Task] {
        page.isFreeform ? model.freeformTasks : model.cards(in: page.column!)
    }

    var body: some View {
        Group {
            if cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(cards) { MovableCard(task: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(page.isFreeform ? "No freeform agents" : "Nothing in \(page.title)",
                  systemImage: page.isFreeform ? "folder" : "square.stack.3d.up.slash")
        } description: {
            Text(page.isFreeform
                 ? "Agents running in an existing directory appear here."
                 : "Cards in the \(page.title) column appear here.")
        }
    }
}

// MARK: - A card with its move affordances (swipe-to-adjacent + "Move to…" menu)

/// Wraps `BoardCardCell` with the two move gestures (design §2). Only **worktree** cards move —
/// freeform cards have no lifecycle column and the daemon's `move` guards `origin == .worktree`, so
/// they render without either affordance. A user move drives the shipped `move` RPC, which queues the
/// agent an inbox message about its new column.
private struct MovableCard: View {
    let task: Task
    @EnvironmentObject var model: BoardModel
    @State private var dragX: CGFloat = 0

    var body: some View {
        if task.origin == .worktree {
            BoardCardCell(task: task)
                .offset(x: dragX)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedId = task.id }   // tap → open detail (§3)
                .gesture(moveDrag)                             // tap-and-hold → move (§2)
                .contextMenu { moveMenu }
        } else {
            BoardCardCell(task: task)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedId = task.id }
        }
    }

    /// The "Move to…" context menu — every lifecycle column except this card's current one.
    @ViewBuilder private var moveMenu: some View {
        ForEach(moveTargets(from: task.column), id: \.self) { col in
            Button {
                move(to: col)
            } label: {
                Label("Move to \(col.displayName)", systemImage: symbol(for: col))
            }
        }
    }

    /// Tap-and-hold → swipe to an adjacent column. The long press disambiguates from the pager's own
    /// horizontal swipe; a drag past the threshold commits the move to the neighbouring column.
    private var moveDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 12))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    dragX = min(130, max(-130, drag.translation.width))
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { snapBack(); return }
                let movingRight = drag.translation.width > 0
                if abs(drag.translation.width) > 64,
                   let target = adjacentColumn(from: task.column, movingRight: movingRight) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    move(to: target)
                }
                snapBack()
            }
    }

    private func snapBack() { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragX = 0 } }

    private func move(to col: Column) {
        _Concurrency.Task { await model.move(task.id, to: col) }
    }

    private func symbol(for col: Column) -> String {
        switch col {
        case .plan:   return "list.bullet.clipboard"
        case .impl:   return "hammer"
        case .review: return "checkmark.seal"
        }
    }
}

// MARK: - Connection banner (from F3; hidden while live)

/// Thin bar reflecting `ConnectionState`; hidden while live so the board is chrome-free when connected.
private struct ConnectionBanner: View {
    let state: ConnectionState
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        if state != .live {
            HStack(spacing: 8) {
                Image(systemName: state == .retrying || state == .connecting
                      ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                Text(label).font(.footnote.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(theme.amber.tint)
            .foregroundStyle(theme.amber.text)
        }
    }
    private var label: String {
        switch state {
        case .connecting: return "Connecting…"
        case .retrying:   return "Reconnecting…"
        case .down:       return "Offline"
        case .live:       return ""
        }
    }
}
