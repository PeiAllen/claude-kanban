import SwiftUI
import OrchestraKit
import OrchestraUI

/// The card-detail **pinned header** (design §3): title, status pill, model chip, context-window gauge,
/// and the worktree breadcrumb (`repo/branch → path`). Stays pinned above the tab bar while the tab body
/// scrolls. Reads a live `Task` (the detail view resolves it from `BoardModel` by id), so the pill/gauge
/// tick as the daemon streams events.
struct CardDetailHeader: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    private var sem: SemColor { theme.statusColor(task.status.rawValue) }
    private var isLive: Bool { task.status == .running || task.status == .waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                DetailStatusPill(status: task.status, sem: sem, updatedAt: task.updatedAt, live: isLive)
            }

            HStack(spacing: 8) {
                if task.origin != .worktree { ModeAccessChips(origin: task.origin, access: task.access) }
                ModelChip(model: task.model)
                Spacer(minLength: 6)
                if task.ctxPct > 0 { CtxGauge(pct: task.ctxPct, theme: theme) }
            }

            Text(breadcrumb)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
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
    let status: AgentStatus
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
    private var label: String { theme.statusLabel(status) }
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
/// mode/access instead — §2a language, reused in the detail header).
private struct ModeAccessChips: View {
    let origin: CardOrigin
    let access: CardAccess
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        HStack(spacing: 6) {
            let scratch = origin == .scratch
            HStack(spacing: 4) {
                Image(systemName: scratch ? "sparkles" : "folder")
                Text(scratch ? "Scratch" : "Freeform")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle((scratch ? theme.gray : theme.indigo).text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((scratch ? theme.gray : theme.indigo).tint))
            if access == .readOnly {
                HStack(spacing: 3) { Image(systemName: "lock"); Text("Read-only") }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(theme.chip))
            }
        }
    }
}

/// The header's context-window gauge — a wider take on the board cell's mini-gauge, with the percent
/// spelled out (greening → ambering → reddening as the window fills).
private struct CtxGauge: View {
    let pct: Double
    let theme: Theme
    private var color: Color {
        if pct >= 90 { return theme.red.dot }
        if pct >= 70 { return theme.amber.dot }
        return theme.green.dot
    }
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chip).frame(width: 54, height: 6)
                Capsule().fill(color)
                    .frame(width: max(3, 54 * CGFloat(min(100, max(0, pct)) / 100)), height: 6)
            }
            Text("\(Int(pct))%")
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.text2)
        }
        .accessibilityLabel("Context \(Int(pct)) percent full")
    }
}
