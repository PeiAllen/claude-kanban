import SwiftUI
import OrchestraKit

/// The reading pass, as a column of cards beside the document.
///
/// Cards sit in DOCUMENT ORDER rather than floating beside the passage each one anchors. Floating them
/// would mean chasing the webview's scroll position from SwiftUI frame by frame, which lags visibly on
/// a fast scroll and buys a spatial cue the page's own tint already gives. Instead the rail follows the
/// reading position: the page reports which anchored passage is at the top of the viewport, and the
/// rail scrolls that card into view.
///
/// The same view serves the Mac's side column and the phone's sheet. Only the container differs.
@MainActor
struct DocumentCommentRail: View {
    @ObservedObject var reader: DocumentReaderModel
    @Environment(\.theme) private var theme: Theme
    let send: (UUID) -> Void
    let sendAll: () -> Void
    /// Focus follows the active card, so a new anchor is ready to type into with no extra click.
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.hair)
            ScrollViewReader { scroll in
                ScrollView {
                    // Eager, not lazy. A reading pass is a handful of comments, so laziness saves
                    // nothing and costs the ScrollViewReader a reliable target for a card that has not
                    // been scrolled into existence yet.
                    VStack(spacing: 8) {
                        ForEach(reader.comments) { comment in
                            card(comment).id(comment.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: reader.activeComment) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(id, anchor: .center) }
                    // Only take focus for a card still being written. Scrolling to a SENT card — which
                    // is what following the reading position does — must not steal the keyboard.
                    if reader.comments.first(where: { $0.id == id })?.sent == false { focused = id }
                }
            }
        }
        .background(theme.panelOpaque)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Comments").font(.footnote.weight(.semibold)).foregroundStyle(theme.text2)
            Text("\(reader.comments.count)")
                .font(.caption2.monospacedDigit()).foregroundStyle(theme.text3)
            Spacer(minLength: 6)
            // One message for the whole pass. Shown only once there is more than one thing to send —
            // with a single comment it would duplicate the card's own Send button.
            if reader.unsent.count > 1 {
                Button(action: sendAll) {
                    Text("Send all \(reader.unsent.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(!reader.canSendAll)
                .opacity(reader.canSendAll ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func card(_ comment: PendingComment) -> some View {
        let active = reader.activeComment == comment.id
        return VStack(alignment: .leading, spacing: 7) {
            anchorHeader(comment)
            quote(comment)
            if comment.sent {
                sentBody(comment)
            } else {
                composeBody(comment)
            }
        }
        .padding(10)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(active ? theme.accent.opacity(0.55) : theme.cardBorder,
                        lineWidth: active ? 1.2 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(comment.sent ? 0.62 : 1)
        .contentShape(Rectangle())
        // Clicking anywhere on a card focuses it, which also scrolls its passage into view.
        .onTapGesture { reader.focus(comment.id) }
    }

    /// Where in the document this comment points. The line range is the machine-readable half and the
    /// heading path is the human one, so both are here — the heading survives an edit that moves lines.
    private func anchorHeader(_ comment: PendingComment) -> some View {
        HStack(spacing: 5) {
            Text(lineLabel(comment))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.text3)
            // The DEEPEST heading only. A full path never fits a 288pt card, and truncating one leaves
            // a fragment of the outermost heading ("…ow it stays fresh ›") — the least specific part,
            // kept at the cost of the most specific. The whole path still goes in the message.
            if let section = comment.anchor.headingPath.last {
                Text(section)
                    .font(.caption2).foregroundStyle(theme.text3)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // The agent rewrote the passage under this comment. The QUOTE is still true — it froze at
            // selection time — but there is no tint in the page to look for any more, and saying so is
            // better than letting the reviewer hunt for one.
            if comment.detached {
                Text("text moved")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.amber.text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(theme.amber.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if comment.sent {
                Text("sent")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.green.text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(theme.green.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func quote(_ comment: PendingComment) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle().fill(theme.accent.opacity(0.45)).frame(width: 2)
            Text(plainQuote(comment.anchor.excerpt))
                .font(.caption)
                .foregroundStyle(theme.text2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func composeBody(_ comment: PendingComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Comment on this passage…", text: reader.draftBinding(comment.id), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused, equals: comment.id)
                .font(.callout)
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 8) {
                Button("Discard") { reader.discard(comment.id) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
                Button { send(comment.id) } label: {
                    Text(reader.sending.contains(comment.id) ? "Sending…" : "Send")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(theme.accent.opacity(reader.canSend(comment.id) ? 1 : 0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                // The ONLY double-send guard. A comment carries no dedup key on purpose: a deliberate
                // re-send is meaningful and must never be silently swallowed.
                .disabled(!reader.canSend(comment.id))
            }
        }
    }

    /// A sent comment stays on screen, and stays readable. The pass is a record of what you said, so
    /// removing a card the moment it goes out would lose your place in a long document.
    private func sentBody(_ comment: PendingComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(comment.draft)
                .font(.callout).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { reader.discard(comment.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .buttonStyle(.plain)
        }
    }

    private func lineLabel(_ comment: PendingComment) -> String {
        guard let s = comment.anchor.startLine, let e = comment.anchor.endLine else { return "—" }
        return s == e ? "\(s)" : "\(s)–\(e)"
    }

    /// The stored excerpt is already `> `-prefixed, because that is the shape it takes in the message.
    /// A card shows it as prose, on one run of text.
    private func plainQuote(_ excerpt: String) -> String {
        excerpt.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
