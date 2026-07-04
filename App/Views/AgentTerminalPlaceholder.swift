import SwiftUI
import OrchestraUI
import OrchestraCore

/// Shown in place of `AgentTerminalView` when a phone owns this card's agent terminal (PR D5). The
/// desktop deliberately does NOT attach to the tmux `agent` window while the phone owns it — a tmux
/// window has one size, so two attached clients at different sizes would resize-fight. Retake flips the
/// daemon lease back to this desktop; the resulting owner event remounts the live terminal automatically.
///
/// When the phone owner is **stale** (missed its heartbeat), the copy signals the phone is unreachable
/// and the button reads **Force Retake** — the same action, just labelled to reassure the user that
/// forcing the terminal back is safe.
struct AgentTerminalPlaceholder: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var stale: Bool { model.agentOwnerStale(for: task.id) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: stale ? "iphone.slash" : "iphone.gen3")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(theme.text2)

            VStack(spacing: 4) {
                Text("Taken over by phone")
                    .font(F.ui(14, .semibold)).foregroundStyle(theme.text)
                Text(stale
                     ? "The phone that took over is unreachable. You can force the terminal back."
                     : "This agent terminal is being controlled from your phone.")
                    .font(F.ui(11.5)).foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }

            Button { model.retakeAgentTerminal(task.id) } label: {
                HStack(spacing: 6) {
                    Text(stale ? "Force Retake" : "Retake Terminal")
                        .font(F.ui(12, .semibold)).foregroundStyle(.white)
                    Text("⏎").font(F.mono(10)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 14).frame(height: 30)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])   // ⏎ retakes when the placeholder owns the focus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.termBg)   // reads as "the terminal's space, just not yours right now"
    }
}
