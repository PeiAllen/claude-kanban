import SwiftUI
import OrchestraUI

/// A small toolbar pill showing which surface currently owns the keyboard (focus-as-mode indicator).
/// Answers "am I about to type into the agent?" at a glance — an amber dot means a terminal is focused.
struct ContextChip: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    private var label: String {
        switch model.focusZone {
        case .board:     return "BOARD"
        case .inspector: return "INSPECTOR"
        case .terminal:  return "TERMINAL"
        case .shell:     return "SHELL"
        }
    }

    private var isTerminal: Bool {
        model.focusZone == .terminal || model.focusZone == .shell
    }

    var body: some View {
        HStack(spacing: 5) {
            if isTerminal {
                Circle().fill(theme.amber.dot).frame(width: 5, height: 5)
            }
            Text(label)
                .font(F.mono(9.5, .semibold))
                .foregroundStyle(isTerminal ? theme.amber.text : theme.text2)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule(style: .continuous).fill(theme.chip))
        .overlay(Capsule(style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .help("Keyboard focus — press ? for shortcuts")
    }
}
