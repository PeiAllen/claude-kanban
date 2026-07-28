import SwiftUI
import OrchestraUI
import AppKit
import OrchestraCore

/// The horizontally scrolling board of three columns (ui-spec §3.3, §4.2).
struct BoardView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    private static let columns: [(Column, String)] = [
        (.plan, "Plan"),
        (.impl, "Implementation"),
        (.review, "Review"),
    ]

    var body: some View {
        // Three fixed columns share the width equally and fill the height. Each column scrolls its
        // own cards vertically, so the board itself doesn't need to scroll. Below them, a freeform
        // region docks at the BOTTOM of the board (full board width) for non-worktree cards — like a
        // terminal panel. It lives inside the board, so the inspector overlay renders on top of it.
        VStack(spacing: 0) {
            // Drill chrome (slice 2b): when scoped to a root's subtree, a breadcrumb + banner sit above
            // the columns. Absent at the top level, so the default board is unchanged.
            if model.drillScope != nil {
                DrillHeader()
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.columns, id: \.0) { col, label in
                    ColumnView(column: col, label: label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only present when there are freeform cards — it's a card category, not a workflow stage,
            // so it doesn't take up permanent space the way the lifecycle columns do.
            if !model.freeformTasks.isEmpty {
                FreeformRegionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg)
    }
}

// MARK: - Column

private struct ColumnView: View {
    let column: Column
    let label: String

    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    @State private var isTargeted = false

    private var cards: [OrchestraCore.Task] { model.cards(in: column) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isTargeted ? theme.overTint : theme.colBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isTargeted ? theme.accent : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first, let id = UUID(uuidString: dropped) else { return false }
            guard model.tasks.first(where: { $0.id == id })?.origin == .worktree else {
                return false
            }
            _Concurrency.Task { await model.move(id, to: column) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    // MARK: Header

    /// Zoom-level subtitle (slice 2b) — the macro-phase reading of the column at PROJECT scale, shown
    /// only at the top level (`drillScope == nil`). Inside a drill the columns are card-scale again
    /// (a root's children), so the subtitle drops.
    private var subtitle: String? {
        guard model.drillScope == nil else { return nil }
        switch column {
        case .plan:   return "being designed"
        case .impl:   return "orchestration running"
        case .review: return "awaiting your approval"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(F.ui(12.5, .semibold))
                    .tracking(-0.0625)
                    .foregroundStyle(theme.text)
                countBadge
                Spacer(minLength: 4)
                addButton
            }
            if let subtitle {
                Text(subtitle).font(F.ui(10)).foregroundStyle(theme.text3)
            }
        }
        .padding(.top, 13)
        .padding(.horizontal, 13)
        .padding(.bottom, 9)
    }

    private var countBadge: some View {
        Text("\(cards.count)")
            .font(F.ui(10.5, .semibold))
            .foregroundStyle(theme.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule(style: .continuous).fill(theme.chip))
    }

    private var addButton: some View {
        Button {
            model.spawnDefaultColumn = (column == .plan ? .plan : .impl)
            model.showSpawn = true
        } label: {
            Text("+")
                .font(F.ui(15))
                .foregroundStyle(theme.text2)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if cards.isEmpty {
            emptyPlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Lazy so a card scrolled out of the column unrealizes — its `onDisappear` parks the
                    // card's pulse/shimmer and age clock, so only on-screen cards animate or tick.
                    LazyVStack(spacing: model.density.cardGap) {
                        ForEach(cards) { task in
                            CardView(task: task)
                                .id(task.id)
                                .padding(.leading, CGFloat(model.treeDepth(of: task)) * 14)
                                .draggable(task.id.uuidString)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)
                // Keep the keyboard-selected card visible as hjkl moves the selection through the column.
                .onChange(of: model.selectedId) { _, id in
                    // A selected attached ROW isn't a top-level card — scroll its visible target (the
                    // card whose inline rows contain it) into view, via the card-level anchor.
                    guard let anchor = model.cardLevelAnchor(id),
                          cards.contains(where: { $0.id == anchor }) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(anchor, anchor: .center) }
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.text3)
            Text("No agents here")
                .font(F.ui(12, .medium))
                .foregroundStyle(theme.text2)
            Text("Drag a card in, or click + to spawn one")
                .font(F.ui(11))
                .foregroundStyle(theme.text3)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .opacity(isTargeted ? 0.35 : 1)
    }
}

// MARK: - Freeform region

/// Bottom-docked region for non-worktree cards (`.borrowed`/`.scratch`), styled like the terminal
/// panel: a ribbon header over a card grid. The ribbon doubles as a drag handle — drag it up to grow
/// the dock (the columns above shrink) — and the cards wrap into an adaptive grid that scrolls
/// vertically when they overflow. It's a card *category*, not a workflow stage (cards aren't draggable
/// between stages, not a drop target). Docked inside the board, so the inspector overlay sits on top
/// of it (never the reverse).
private struct FreeformRegionView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    // Persisted so the `z` keyboard verb (which writes this key) can collapse/expand the dock too.
    @AppStorage("freeformCollapsed") private var collapsed = false

    // Dock height, persisted across launches; clamped 140–620. During a live drag we hold the
    // in-flight value in `dragHeight` and commit to @AppStorage only on release (a per-frame
    // UserDefaults write would stutter the drag — same pattern as ShellTabsView / InspectorResizer).
    @AppStorage("freeformPanelHeight") private var savedHeight: Double = 208
    @State private var dragHeight: Double? = nil
    @State private var startHeight: Double? = nil

    private var panelHeight: CGFloat { CGFloat(dragHeight ?? savedHeight) }
    // The ribbon doubles as a drag handle, but only while the panel is actually showing below it.
    private var resizable: Bool { !collapsed }
    private var cards: [OrchestraCore.Task] { model.freeformTasks }

    // Cards wrap into as many ~290pt columns as the board width allows, then scroll vertically.
    private let grid = [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            if !collapsed {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: grid, alignment: .leading, spacing: 12) {
                        ForEach(cards) { task in
                            CardView(task: task)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .frame(height: panelHeight)
            }
        }
        .background(theme.colBg)
        .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 0.5) }
    }

    private var ribbon: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(F.ui(11)).foregroundStyle(theme.text2)
            Text("Freeform")
                .font(F.ui(12.5, .semibold))
                .tracking(-0.0625)
                .foregroundStyle(theme.text)
            Text("\(cards.count)")
                .font(F.ui(10.5, .semibold))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule(style: .continuous).fill(theme.chip))
            Spacer(minLength: 4)
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(F.ui(10)).foregroundColor(theme.text2)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show freeform cards" : "Hide freeform cards")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(theme.chip)
        .contentShape(Rectangle())
        // ns-resize cursor + drag-to-resize, but only while the panel is open below. `including:
        // .subviews` parks the gesture when collapsed so the chevron button keeps its tap; the same
        // works while expanded because a tap (no drag) still resolves to the button (cf. ShellTabsView).
        .onHover { hovering in
            guard resizable else { return }
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(resizeDrag, including: resizable ? .all : .subviews)
    }

    // Dragging the ribbon up grows the dock (and shrinks the flexible columns above).
    private var resizeDrag: some Gesture {
        // Measure in GLOBAL space: the ribbon shifts up/down as the dock grows, so a .local
        // translation would be read against a moving origin and jitter (cf. ShellTabsView).
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if startHeight == nil { startHeight = savedHeight }
                dragHeight = resolve(v.translation.height, base: startHeight ?? savedHeight)
            }
            .onEnded { v in
                let base = startHeight ?? savedHeight
                savedHeight = resolve(v.translation.height, base: base)
                startHeight = nil
                dragHeight = nil
            }
    }

    private func resolve(_ translation: CGFloat, base: Double) -> Double {
        // Up (negative translation) → taller dock. Clamp 140–620.
        min(620, max(140, base - Double(translation)))
    }
}
