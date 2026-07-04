import SwiftUI

/// The archive confirmation dialog. Raised only by the keyboard `a` shortcut (deliberate UI actions —
/// the inspector / recovery buttons and the command palette — archive directly), so an accidental
/// keystroke can't permanently archive a card. ⏎ confirms, esc / ⌘W / click-away cancels, all handled
/// by `BoardModel` via `KeyboardController`.
struct ArchiveConfirmView: View {
    let cardTitle: String

    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Archive this card?")
                    .font(F.ui(15, .semibold)).foregroundStyle(theme.text)
                if !cardTitle.isEmpty {
                    Text(cardTitle)
                        .font(F.ui(12.5)).foregroundStyle(theme.text2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Text("Archiving is slow to reverse — treat it as permanent.")
                    .font(F.ui(11.5)).foregroundStyle(theme.text3)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { model.cancelArchive() } label: {
                    HStack(spacing: 6) {
                        Text("Cancel").font(F.ui(12, .medium)).foregroundStyle(theme.text2)
                        Text("esc").font(F.mono(10)).foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    .surface(theme.card, corner: 8, hair: theme.hair)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { model.confirmArchive() } label: {
                    HStack(spacing: 6) {
                        Text("Archive").font(F.ui(12, .semibold)).foregroundStyle(.white)
                        Text("⏎").font(F.mono(10)).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(theme.red.text)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(theme.panelOpaque)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.30), radius: 30, y: 18)
    }
}
