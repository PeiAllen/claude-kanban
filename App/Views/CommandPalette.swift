import SwiftUI

/// The `:` command palette — a fuzzy list of every board action with its shortcut shown inline (so the
/// palette teaches the keymap). `Ctrl-j`/`Ctrl-k` move the highlight, `Enter` runs it, `Esc` closes —
/// all driven by `KeyboardController` (which holds the highlight in `BoardModel.paletteIndex`).
struct CommandPalette: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    @FocusState private var focused: Bool

    var body: some View {
        let cmds = model.filteredPaletteCommands
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(":").font(F.mono(14, .bold)).foregroundStyle(theme.text2)
                TextField("Run a command…", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(F.ui(13.5)).foregroundColor(theme.text)
                    .focused($focused)
                    .onChange(of: model.paletteQuery) { _, _ in model.paletteIndex = 0 }
            }
            .padding(.horizontal, 14).frame(height: 44)
            Rectangle().fill(theme.hair).frame(height: 0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cmds.enumerated()), id: \.element.id) { idx, cmd in
                            row(cmd, active: idx == model.paletteIndex).id(idx)
                        }
                        if cmds.isEmpty {
                            Text("No matching command")
                                .font(F.ui(12)).foregroundStyle(theme.text3)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: model.paletteIndex) { _, i in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .frame(width: 500)
        .background(theme.panelOpaque)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.30), radius: 30, y: 18)
        .onAppear { focused = true }
    }

    private func row(_ cmd: BoardModel.PaletteCommand, active: Bool) -> some View {
        HStack(spacing: 10) {
            Text(cmd.title).font(F.ui(13)).foregroundStyle(active ? theme.text : theme.text2)
            Spacer(minLength: 12)
            Text(cmd.keys).font(F.mono(11, .semibold)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? theme.chip : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if let i = model.filteredPaletteCommands.firstIndex(where: { $0.id == cmd.id }) {
                model.paletteIndex = i; model.runPaletteSelection()
            }
        }
    }
}
