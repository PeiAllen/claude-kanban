import SwiftUI
import OrchestraUI
import AppKit

/// The `:` command palette — a fuzzy list of every board action with its shortcut shown inline (so the
/// palette teaches the keymap). `Ctrl-j`/`Ctrl-k` move the highlight, `Enter` runs it, `Esc` closes —
/// all driven by `KeyboardController` (which holds the highlight in `BoardModel.paletteIndex`).
struct CommandPalette: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        let cmds = model.filteredPaletteCommands
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(":").font(F.mono(14, .bold)).foregroundStyle(theme.text2)
                // AppKit-backed (not SwiftUI `TextField`) so it grabs first responder via a *deferred*
                // `makeFirstResponder` — the same trick the agent terminal uses to claim focus. A
                // SwiftUI `@FocusState` focus in `onAppear` is synchronous and loses the race to the
                // terminal's deferred `claimFocusNow()`, which is why the palette's keystrokes used to
                // land in the terminal instead. See `AutoFocusTextField`.
                PaletteField(text: $model.paletteQuery, textColor: theme.text) { model.paletteIndex = 0 }
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

/// The palette's query field, backed by an AppKit `AutoFocusTextField` so it reliably claims keyboard
/// focus on open (see the doc on `AutoFocusTextField`). `Enter` / `Esc` / `Ctrl-j` / `Ctrl-k` are
/// handled by `KeyboardController`'s global key monitor (which runs before the field editor sees the
/// key), so this field only needs to mirror typed text back into `paletteQuery`.
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    /// Called whenever the text changes (the palette resets its highlight to the top match).
    var onChange: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = AutoFocusTextField()
        tf.delegate = context.coordinator
        tf.placeholderString = "Run a command…"
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13.5)
        tf.textColor = NSColor(textColor)
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text { tf.stringValue = text }
        tf.textColor = NSColor(textColor)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            parent.text = tf.stringValue
            parent.onChange()
        }
    }
}
