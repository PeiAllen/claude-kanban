import SwiftUI

/// The `?` keyboard-shortcuts overlay — a reference card grouped by surface. Static content (mirrors
/// notes/designs/2026-07-02-keyboard-shortcuts-vim-navigation-design.md); `Esc` / click-away closes it
/// via `BoardModel.closeFrontmost()`.
struct KeyboardHelpView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    private struct Row: Identifiable { let id = UUID(); let keys: String; let desc: String }
    private struct Section: Identifiable { let id = UUID(); let title: String; let rows: [Row] }

    private let sections: [Section] = [
        Section(title: "Navigate", rows: [
            Row(keys: "h j k l", desc: "Move card selection (within a pane)"),
            Row(keys: "g g / G", desc: "First / last card in column"),
            Row(keys: "⌃h ⌃j ⌃k ⌃l", desc: "Move focus between panes (spatial)"),
            Row(keys: "Enter", desc: "Open inspector"),
            Row(keys: "i", desc: "Type to the agent (focus terminal)"),
            Row(keys: "⌃h  (in terminal)", desc: "Eject back to the board"),
            Row(keys: "Esc", desc: "Close / clear the frontmost thing"),
        ]),
        Section(title: "Go to & find", rows: [
            Row(keys: "g p / g i / g r", desc: "Plan / Implementation / Review"),
            Row(keys: "g f", desc: "Freeform dock"),
            Row(keys: "g a / g d / g s", desc: "Activity / Done / Settings"),
            Row(keys: "/  ·  n / N", desc: "Search cards · next / prev match"),
            Row(keys: "f", desc: "Link-hints — jump to any card"),
            Row(keys: ":", desc: "Command palette"),
        ]),
        Section(title: "Act on the card", rows: [
            Row(keys: "c", desc: "New card (spawn)"),
            Row(keys: "H / L", desc: "Carry card left / right a column"),
            Row(keys: "a", desc: "Archive"),
            Row(keys: "o", desc: "View changes in Zed"),
            Row(keys: "d", desc: "Toggle Agent / Diff view"),
            Row(keys: "I", desc: "Open the inbox editor"),
            Row(keys: "y c / y t / y p", desc: "Copy chat link / tmux target / path"),
            Row(keys: "t", desc: "New shell tab"),
        ]),
        Section(title: "Panes & layout", rows: [
            Row(keys: "⌃j (in terminal)", desc: "Agent ↔ shell panel"),
            Row(keys: "⌃h / ⌃l (shell)", desc: "Switch shell tabs"),
            Row(keys: "⌃⇧h j k l", desc: "Resize the focused pane"),
            Row(keys: "z", desc: "Collapse / expand the focused dock"),
        ]),
        Section(title: "Standard (⌘)", rows: [
            Row(keys: "⌘N", desc: "New card"),
            Row(keys: "⌘T", desc: "New shell"),
            Row(keys: "⌘W", desc: "Close frontmost (→ archive card)"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard shortcuts").font(F.ui(15, .semibold)).foregroundStyle(theme.text)
                Spacer()
                Text("esc to close").font(F.mono(10)).foregroundStyle(theme.text3)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.title.uppercased())
                            .font(F.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(theme.text2)
                        ForEach(section.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.keys)
                                    .font(F.mono(11, .semibold)).foregroundStyle(theme.text)
                                    .frame(width: 128, alignment: .leading)
                                Text(row.desc)
                                    .font(F.ui(11.5)).foregroundStyle(theme.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(theme.panelOpaque)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.30), radius: 30, y: 18)
    }
}
