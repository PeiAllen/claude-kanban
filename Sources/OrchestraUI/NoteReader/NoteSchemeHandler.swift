import Foundation
import WebKit
import OrchestraKit

/// Serves the reader over a PRIVATE scheme. Two kinds of request:
///
///   `orchestra-note://note/index.html`, `…/reader.js`, `…/vendor/…`  → a BUNDLED file
///   anything else                                                     → an image the note references
///
/// WHY A CUSTOM SCHEME, NOT `loadFileURL` OR `loadHTMLString`
///
/// `loadHTMLString` yields an OPAQUE origin, which makes CSP `'self'` meaningless — there is no stable
/// origin for it to match. `file://` origins carry a long history of inconsistent WebKit CORS behavior.
/// A private scheme gives the page a normal, comparable origin so the CSP behaves predictably, keeps
/// the app's filesystem entirely out of the page's reach, and composes with a nested sandboxed iframe
/// later. This is what Capacitor and comparable offline-web apps do for the same reasons.
///
/// The handler holds NO note identity. `assetProvider` is built by the view with the card and the note
/// already bound, so there is exactly one source of truth for which note's assets may be served.
final class NoteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "orchestra-note"
    static let host = "note"
    static var pageURL: URL { URL(string: "\(scheme)://\(host)/index.html")! }

    private let root: URL?
    private let assetProvider: @Sendable (String) async -> NoteAsset?
    private let lock = NSLock()
    private var live: Set<ObjectIdentifier> = []

    /// FAILS SOFT on a missing resource bundle. A force-unwrap here would crash a Release device build
    /// — iOS installs are Release-only, so a bundling mistake surfaces there first. A nil root serves
    /// 404s and the reader renders empty instead of taking the app down.
    init(assetProvider: @escaping @Sendable (String) async -> NoteAsset?) {
        self.root = NoteReaderBundle.root
        self.assetProvider = assetProvider
        super.init()
        assert(root != nil, "NoteReader resources are missing from the app bundle")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        lock.withLock { _ = live.insert(ObjectIdentifier(task)) }
        guard let url = task.request.url else { return fail(task) }
        let rel = String(url.path.drop(while: { $0 == "/" }))

        // Bundled first. Containment is COMPONENT-WISE, not a substring prefix: with a root ending in
        // `NoteReader`, a bare `hasPrefix` would also accept a sibling `NoteReader-private/…`.
        if let root {
            let rootPath = root.standardizedFileURL.path
            let candidate = root.appendingPathComponent(rel).standardizedFileURL
            let contained = candidate.path == rootPath
                || candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            if contained, let data = try? Data(contentsOf: candidate) {
                return respond(task, data: data, mime: Self.mime(for: candidate.pathExtension))
            }
        }

        // Otherwise it is an image the current note references. `rel` is already worktree-relative,
        // because reader.js rewrote every img[src] against the note's directory before requesting it.
        // The daemon re-validates against that note's own references, so a bad path fails there too.
        _Concurrency.Task { [assetProvider] in
            let asset = await assetProvider(rel)
            await MainActor.run {
                guard let asset, let data = Data(base64Encoded: asset.base64) else {
                    return self.fail(task)
                }
                self.respond(task, data: data, mime: asset.mimeType)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.withLock { live.remove(ObjectIdentifier(task)) }
    }

    /// CLAIM the task: test liveness and take ownership in ONE locked step.
    ///
    /// Completing a stopped task raises an ObjC exception, so a check-then-act — testing `live`, then
    /// removing separately — leaves a window between them. Claiming closes it by construction, rather
    /// than relying on WebKit happening to deliver `start:` and `stop:` on the same thread.
    private func claim(_ task: WKURLSchemeTask) -> Bool {
        lock.withLock { live.remove(ObjectIdentifier(task)) != nil }
    }

    private func respond(_ task: WKURLSchemeTask, data: Data, mime: String) {
        guard let url = task.request.url, claim(task) else { return }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime,
                                                  "Content-Length": "\(data.count)"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        guard claim(task) else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html":  return "text/html; charset=utf-8"
        case "css":   return "text/css; charset=utf-8"
        case "js":    return "text/javascript; charset=utf-8"
        case "woff2": return "font/woff2"
        case "json":  return "application/json"
        default:      return "application/octet-stream"
        }
    }
}
