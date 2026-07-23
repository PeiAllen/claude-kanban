import SwiftUI
import OrchestraUI
import OrchestraCore

/// A glance indicator on a target card for its **attached agents** — the read-only sub-cards
/// (reviewers / fork inspectors / browse-only borrows) embedded behind it. `👁 N`, tinted by the
/// roll-up liveness of those agents (green = all running/being-born, amber = one needs the human or
/// died). It is purely informational: the attached agents are reached by **selecting the target**,
/// which expands them as inline rows inside the card (see `AttachedAgentRow`) — no popover. It is the
/// card's whole subtree line (L4), so the count is spelled out ("👁 2 attached"): alone on its own
/// line, a bare glyph and a digit would read as debris rather than a summary of what hangs off the card.
struct AttachedAgentsBadge: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: OrchestraCore.Task

    var body: some View {
        // Hidden unless this card actually has attached agents (nil liveness ⇒ none).
        if let liveness = model.attachedLiveness(of: task) {
            let count = model.attachedAgents(of: task).count
            let tint = liveness == .allRunning ? theme.green.text : theme.amber.text
            HStack(spacing: 3) {
                Image(systemName: "eye").font(F.ui(8.5))
                Text("\(count) attached").font(F.mono(10, .medium))
            }
            .foregroundStyle(tint)
            .help(count == 1 ? "1 attached agent — select this card to expand it"
                             : "\(count) attached agents — select this card to expand them")
        }
    }
}

/// One compact row for an attached read-only agent, rendered INSIDE its target card while the target
/// (or one of its rows) is selected: status dot · shortId · title. Clicking selects that agent —
/// opening its inspector / terminal like any card. Highlighted when it is the current selection, so
/// Esc out of its terminal lands back on the visible row rather than into the void.
struct AttachedAgentRow: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let agent: OrchestraCore.Task

    private var isSelected: Bool { model.selectedId == agent.id }

    var body: some View {
        Button { model.selectAndEnterTerminal(agent.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(theme.statusColor(agent.phaseDisplay).dot).frame(width: 6, height: 6)
                Text(agent.shortId).font(F.mono(10)).foregroundColor(theme.text3)
                Text(agent.title).font(F.ui(11.5)).foregroundColor(theme.text).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // During a `/` search this row is revealed in place; dim it unless it's one of the matches.
        .opacity(model.searchActive && !model.isSearchMatch(agent) ? 0.32 : 1)
    }
}
