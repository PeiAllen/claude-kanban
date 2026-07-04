import SwiftUI
import OrchestraUI
import AppKit

/// The `/` card search bar — a floating field at the top of the board. Typing filters (dims
/// non-matches and jumps to the first match); `Enter` commits and returns to the board where `n`/`N`
/// cycle matches; `Esc` clears. Shown whenever `model.searchQuery != nil`.
struct SearchBar: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    /// Local mirror of the optional model query so the field binds to a non-optional String.
    @State private var text = ""

    private var matchCount: Int { model.searchMatchIds.count }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(F.ui(11)).foregroundStyle(theme.text2)
            // AppKit-backed (not SwiftUI `TextField`) so it grabs first responder via a *deferred*
            // `makeFirstResponder`, winning the race against the agent terminal's deferred
            // `claimFocusNow()` — a synchronous `@FocusState` focus loses that race and the keystrokes
            // land in the terminal. Same fix as the `:` command palette. See `AutoFocusTextField`.
            SearchField(
                text: $text,
                textColor: theme.text,
                onChange: { v in
                    model.searchQuery = v
                    // Live-jump to the first match as you type.
                    if let first = model.searchMatchIds.first { model.selectedId = first }
                },
                onSubmit: {},                          // Enter → commit; the field resigns to the board (n/N cycle)
                onCancel: { model.searchQuery = nil }  // Esc clears the search
            )
            if !text.isEmpty {
                Text("\(matchCount)")
                    .font(F.mono(10.5, .semibold)).foregroundStyle(theme.text2)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(theme.chip))
            }
            Text("n/N · esc").font(F.mono(9.5)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 12).frame(height: 38).frame(width: 420)
        .background(theme.panelOpaque)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.22), radius: 18, y: 10)
        .onAppear { text = model.searchQuery ?? "" }
    }
}

/// The `/` search query field, backed by an AppKit `AutoFocusTextField` so it reliably claims keyboard
/// focus on open (see the doc on `AutoFocusTextField`). Unlike the command palette, the search bar is
/// not special-cased in `KeyboardController` — while it's focused the context is `.field`, so `Enter`
/// and `Esc` reach the field editor and are handled here rather than by the global key monitor.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    /// Fired on every text change (filter + live-jump to the first match).
    var onChange: (String) -> Void
    /// `Enter`: commit — the field resigns first responder so the board regains keys (`n`/`N` cycle).
    var onSubmit: () -> Void
    /// `Esc`: clear the search.
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = AutoFocusTextField()
        tf.delegate = context.coordinator
        tf.stringValue = text
        tf.placeholderString = "Search cards…"
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 12.5)
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
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            parent.text = tf.stringValue
            parent.onChange(tf.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                // Commit: drop first responder so board verbs (n/N) work, but keep the bar visible.
                control.window?.makeFirstResponder(nil)
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
