import SwiftUI
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
        // own cards vertically, so the board itself doesn't need to scroll.
        HStack(alignment: .top, spacing: 14) {
            ForEach(Self.columns, id: \.0) { col, label in
                ColumnView(column: col, label: label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(16)
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
            _Concurrency.Task { await model.move(id, to: column) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(F.ui(12.5, .semibold))
                .tracking(-0.0625)
                .foregroundStyle(theme.text)
            countBadge
            Spacer(minLength: 4)
            addButton
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: model.density.cardGap) {
                    ForEach(cards) { task in
                        CardView(task: task)
                            .draggable(task.id.uuidString)
                    }
                }
                .padding(.top, 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
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
