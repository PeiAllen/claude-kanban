import SwiftUI

/// The `/` card search bar — a floating field at the top of the board. Typing filters (dims
/// non-matches and jumps to the first match); `Enter` commits and returns to the board where `n`/`N`
/// cycle matches; `Esc` clears. Shown whenever `model.searchQuery != nil`.
struct SearchBar: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    @FocusState private var focused: Bool
    /// Local mirror of the optional model query so the TextField binds to a non-optional String.
    @State private var text = ""

    private var matchCount: Int { model.searchMatchIds.count }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(F.ui(11)).foregroundStyle(theme.text2)
            TextField("Search cards…", text: $text)
                .textFieldStyle(.plain)
                .font(F.ui(12.5)).foregroundColor(theme.text)
                .focused($focused)
                .onChange(of: text) { _, v in
                    model.searchQuery = v
                    // Live-jump to the first match as you type.
                    if let first = model.searchMatchIds.first { model.selectedId = first }
                }
                .onSubmit { focused = false }                 // commit → board; n/N now cycle
                .onExitCommand { model.searchQuery = nil }     // Esc clears the search
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
        .onAppear { text = model.searchQuery ?? ""; focused = true }
    }
}
