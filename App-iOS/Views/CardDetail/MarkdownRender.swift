import SwiftUI
import UIKit
import MarkdownUI
import OrchestraKit
import OrchestraUI
import SwiftMath

/// Renders Notes with MarkdownUI's GFM parser. The only pre-processing is the math extension owned
/// by OrchestraKit; MarkdownUI remains responsible for tables, links, images, lists, code, and all
/// other Markdown syntax.
struct MarkdownView: View {
    let markdown: String
    @Environment(\.theme) private var theme: OrchestraUI.Theme

    var body: some View {
        MarkdownUI.Markdown(MarkdownMathPreprocessor.replacingMath(in: markdown))
            .markdownTheme(.gitHub)
            .markdownInlineImageProvider(NotesInlineImageProvider())
            .markdownTextStyle(\MarkdownUI.Theme.text) {
                MarkdownUI.ForegroundColor(theme.text2)
            }
            .markdownTextStyle(\MarkdownUI.Theme.link) {
                MarkdownUI.ForegroundColor(theme.accent)
            }
            .markdownTextStyle(\MarkdownUI.Theme.code) {
                MarkdownUI.FontFamilyVariant(.monospaced)
                MarkdownUI.ForegroundColor(theme.term)
            }
            .markdownBlockStyle(\MarkdownUI.Theme.blockquote) { configuration in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            MarkdownUI.ForegroundColor(theme.text3)
                        }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .markdownBlockStyle(\MarkdownUI.Theme.table) { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: false)
                        .markdownTableBorderStyle(.init(color: theme.hair))
                        .markdownTableBackgroundStyle(
                            .alternatingRows(theme.colBg, theme.card)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .markdownMargin(top: 0, bottom: 16)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotesInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        guard let formula = MarkdownMathPreprocessor.formula(from: url) else {
            return try await DefaultInlineImageProvider.default.image(with: url, label: label)
        }

        return await MainActor.run {
            MathImageRenderer.image(expression: formula.expression, display: formula.display)
        }
    }
}

@MainActor
private enum MathImageRenderer {
    static func image(expression: String, display: Bool) -> Image {
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.displayErrorInline = true
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        label.font = MTFontManager().latinModernFont(withSize: display ? 22 : 16)
        label.textColor = .label
        label.latex = expression

        let measured = label.sizeThatFits(CGSize(width: 4096, height: 4096))
        let size = CGSize(
            width: max(1, ceil(measured.width) + 8),
            height: max(1, ceil(measured.height) + 6)
        )
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            label.layer.render(in: context.cgContext)
        }
        return Image(uiImage: rendered)
    }
}
