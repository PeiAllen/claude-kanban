import SwiftUI
import OrchestraKit
import OrchestraUI

/// The card-detail **pinned header** (design §3): title, status pill, model chip, context-window gauge,
/// and the worktree breadcrumb (`repo/branch → path`). Stays pinned above the tab bar while the tab body
/// scrolls. Reads a live `Task` (the detail view resolves it from `BoardModel` by id), so the pill/gauge
/// tick as the daemon streams events.
struct CardDetailHeader: View {
    let task: Task
    let connection: ConnectionState
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private var ds: DisplayState { displayState(phase: task.phase, connection: connection) }
    private var sem: SemColor { theme.statusColor(ds.statusKey) }
    private var isLive: Bool { if case .live = task.phase { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                DetailStatusPill(status: ds.statusKey, label: ds.label, sem: sem, updatedAt: task.updatedAt, live: isLive)
            }

            HStack(spacing: 8) {
                if task.origin != .worktree { ModeAccessChips(origin: task.origin, access: task.access) }
                ModelChip(model: task.model)
                // The attached-agents affordance in the detail (parity with the board accordion): the
                // `👁 N`/chevron expands the same read-only agents as inline rows below (self-hides unless
                // this card is a target). Same tap-expand state as the board, so it stays consistent.
                AttachedExpandToggle(task: task)
                Spacer(minLength: 6)
                if task.ctxPct > 0 { CtxGauge(pct: task.ctxPct, theme: theme) }
            }

            Text(breadcrumb)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)

            // The revealed attached agents (gated by `showsInlineRows` = the tap-expand state). Tapping a
            // row selects that agent → the detail navigates to it (`navigationDestination(item:)` replace).
            let rows = model.expandedRows(for: task)
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, agent in
                        if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5) }
                        AttachedAgentRow(agent: agent)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.winBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .bottom)
    }

    private var breadcrumb: String {
        cardBreadcrumb(repo: task.repo, branch: task.branch, cwd: task.cwd, origin: task.origin)
    }
}

// MARK: - Header pieces

/// Status pill matching the board cell's language, scaled up a touch for the header.
private struct DetailStatusPill: View {
    let status: PhaseDisplayKey
    let label: String
    let sem: SemColor
    let updatedAt: Date
    let live: Bool
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(sem.dot).frame(width: 7, height: 7)
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(label + " · " + relativeAge(updatedAt, now: ctx.date))
                }
            } else {
                Text(label)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(sem.tint))
        .fixedSize()
    }
}

/// The model handle as a display chip (family-accented). Model *switching* is not a shipped RPC, so this
/// is intentionally a read-only chip, not a faked interactive selector — see the M2 handoff.
private struct ModelChip: View {
    let model: AgentModel
    @Environment(\.theme) private var theme: Theme
    private var sem: SemColor {
        switch model.family {
        case "claude": return theme.amber
        case "gpt":    return theme.green
        case "gemini": return theme.blue
        default:       return theme.gray
        }
    }
    var body: some View {
        if !model.id.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.caption2)
                Text(model.displayName).lineLimit(1)
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(sem.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(sem.tint))
        }
    }
}

/// Freeform mode + read-only chips (a freeform card has no `repo/branch`, so the header surfaces its
/// mode/access instead — §2a language). Composed from the shared `ModeChip` / `ReadOnlyBadge`
/// (OrchestraUI); the wider percent gauge is the shared `CtxGauge`'s default configuration.
private struct ModeAccessChips: View {
    let origin: CardOrigin
    let access: CardAccess
    var body: some View {
        HStack(spacing: 6) {
            ModeChip(origin: origin)
            if access == .readOnly { ReadOnlyBadge() }
        }
    }
}
