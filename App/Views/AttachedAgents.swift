import SwiftUI
import OrchestraUI
import OrchestraCore

/// The target-side surface for **attached agents** — the read-only sub-cards (reviewers / fork
/// inspectors / browse-only borrows) embedded behind the card they hang off of. Shown on the target's
/// CardView footer and in its inspector: an eye badge `👁 N`, coloured by the roll-up liveness of its
/// attached agents (green = all running/being-born, amber = one needs the human or died), opening a
/// popover that lists them and selects one on click — the only way those hidden cards are reached from
/// the board, so it mirrors the `SharedWorktreeBadge`/`SharedWorktreeList` pattern exactly.
struct AttachedAgentsBadge: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: OrchestraCore.Task
    @State private var showList = false

    var body: some View {
        // Hidden unless this card actually has attached agents (nil liveness ⇒ none).
        if let liveness = model.attachedLiveness(of: task) {
            let agents = model.attachedAgents(of: task)
            let tint = liveness == .allRunning ? theme.green.text : theme.amber.text
            Button { showList.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye").font(F.ui(8.5))
                    Text("\(agents.count)").font(F.mono(10, .medium))
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help(agents.count == 1 ? "1 attached agent" : "\(agents.count) attached agents")
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                AttachedAgentsList(agents: agents) { id in
                    model.selectedId = id
                    showList = false
                }
                .environment(\.theme, theme)
            }
        }
    }
}

/// Popover body: one selectable row per attached agent (status dot · shortId · title), matching
/// `SharedWorktreeList`. Picking a row selects that card (opening its full inspector / terminal).
struct AttachedAgentsList: View {
    @Environment(\.theme) var theme: Theme
    let agents: [OrchestraCore.Task]
    let onPick: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Attached agents")
                .font(F.ui(10.5, .semibold)).foregroundColor(theme.text2)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ForEach(agents) { agent in
                Button { onPick(agent.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(theme.statusColor(agent.phaseDisplay).dot).frame(width: 6, height: 6)
                        Text(agent.shortId).font(F.mono(10)).foregroundColor(theme.text3)
                        Text(agent.title).font(F.ui(11.5)).foregroundColor(theme.text).lineLimit(1)
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 248)
        .padding(.bottom, 8)
        .background(theme.inspector)
    }
}
