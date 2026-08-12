import Foundation

/// Where the document reader's bundled page lives on disk, inside the app.
///
/// Split out from the scheme handler so it can be asserted directly: `Bundle.module` resolving through
/// an XcodeGen-generated app target is standard but easy to get wrong, and a Release-only bundling
/// mistake would otherwise surface as a blank reader on a device rather than a failing test.
public enum DocumentReaderBundle {

    /// The directory holding `index.html`, `reader.css`, `reader.js`, and `vendor/`.
    /// `nil` when the resources did not make it into the app bundle.
    public static var root: URL? {
        Bundle.module.url(forResource: "DocumentReader", withExtension: nil)
    }

    /// The page's entry point, or `nil` if the bundle is missing.
    public static var indexHTML: URL? { root?.appendingPathComponent("index.html") }

    /// Every file the page needs in order to render offline. Used by the bundling test, so a vendored
    /// asset that silently stops shipping fails CI instead of the reader.
    public static let requiredFiles = [
        "index.html",
        "reader.css",
        "reader.js",
        "vendor/marked.umd.js",
        "vendor/marked-katex-extension.umd.js",
        "vendor/katex.min.js",
        "vendor/katex.min.css",
        "vendor/purify.min.js",
    ]
}
