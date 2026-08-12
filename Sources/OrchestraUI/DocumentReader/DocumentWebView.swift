import SwiftUI
import WebKit
import OrchestraKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the page reports back. A block index and a 1-based inclusive source line range — nothing else.
public struct DocumentSelection: Equatable, Sendable {
    public let blockIndex: Int
    public let startLine: Int
    public let endLine: Int
}

/// The shared WKWebView that renders a document on BOTH platforms.
///
/// One renderer, two gestures: the Mac keeps native text selection and reports an arbitrary range; the
/// phone disables text interaction entirely and reports the block you tap. An arbitrary text range is
/// not readable through SwiftUI — `.textSelection(.enabled)` lets the user copy and hands the app
/// nothing — which is the reason this is a webview at all.
///
/// SECURITY SHAPE
///  - Served over a private scheme, so the CSP's `'self'` means something and the page can never touch
///    the app's filesystem.
///  - The JS→Swift bridge is SELECTION-ONLY. The page cannot request anything, write anything, or name
///    a path; the worst a compromised page can do is misreport which lines the user picked, and Swift
///    then quotes those lines from its own copy of the file.
///  - Navigation is refused after the initial load. A note is not a browser.
@MainActor
struct DocumentWebView {
    let markdown: String
    let documentPath: String
    let theme: Theme
    let assetProvider: @Sendable (String) async -> DocumentAsset?
    let onSelect: (DocumentSelection) -> Void

    /// `WKUserContentController` retains its handler STRONGLY. Registering the coordinator directly
    /// leaks the webview AND the coordinator for the app's lifetime, so a weak proxy sits between them.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?
        init(_ t: any WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    /// `@MainActor` because every entry point is: WebKit delivers `didReceive`, `didFinish`, and
    /// `decidePolicyFor` on the main thread, and `updateNSView`/`updateUIView` run there too. Stating it
    /// lets the non-Sendable `onSelect` closure cross into the coordinator without a data-race warning.
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onSelect: (DocumentSelection) -> Void
        /// The most recent payload, held until the page is ready. `evaluateJavaScript` routinely races
        /// the initial load — `window.orchestra` does not exist until reader.js has executed — so the
        /// first render is queued and flushed from `didFinish`.
        private var pending: [String: Any]?
        private var loaded = false

        init(onSelect: @escaping (DocumentSelection) -> Void) { self.onSelect = onSelect }

        func push(_ payload: [String: Any], into web: WKWebView) {
            guard loaded else { pending = payload; return }
            evaluate(payload, in: web)
        }

        private func evaluate(_ payload: [String: Any], in web: WKWebView) {
            // JSON-encoded, never string-interpolated: note content is untrusted and would otherwise
            // be a script-injection vector straight through the bridge.
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("(function(o){window.orchestra.render(o.markdown,o);})(\(json))")
        }

        func webView(_ web: WKWebView, didFinish _: WKNavigation!) {
            loaded = true
            if let p = pending { pending = nil; evaluate(p, in: web) }
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            // SELECTION-ONLY. Anything that is not exactly this shape is dropped on the floor.
            guard m.name == "orchestraSelection", let d = m.body as? [String: Any],
                  let block = d["blockIndex"] as? Int,
                  let start = d["startLine"] as? Int,
                  let end = d["endLine"] as? Int,
                  block >= 0, start >= 1, end >= start else { return }
            onSelect(DocumentSelection(blockIndex: block, startLine: start, endLine: end))
        }

        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler decide: @escaping (WKNavigationActionPolicy) -> Void) {
            // The page itself NEVER navigates: one initial load, then nothing.
            guard loaded else { decide(.allow); return }
            decide(.cancel)
            // A user-activated http(s) link opens in the system browser instead, so links still work
            // while the reader stays pinned to its own document. A blanket cancel would make every link
            // in every note dead — a regression against Obsidian and against the shipping iOS page.
            // Every other scheme is dropped silently: `file:`, `javascript:`, and custom schemes have
            // no business being followed out of note content.
            guard action.navigationType == .linkActivated,
                  let url = action.request.url,
                  ["http", "https"].contains(url.scheme ?? "") else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    fileprivate func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(DocumentSchemeHandler(assetProvider: assetProvider),
                                forURLScheme: DocumentSchemeHandler.scheme)
        cfg.userContentController.add(WeakScriptMessageHandler(coordinator), name: "orchestraSelection")
        #if os(iOS)
        // Kill native text interaction at the ENGINE level. CSS `-webkit-user-select: none` leaves the
        // iOS 15+ magnifier loupe alive and has been implicated in a WKWebView crash; this disables the
        // gestures outright. Safe here because the reader is read-only — nothing in the page needs a
        // caret. Do NOT reuse this configuration if inline editing is ever added.
        cfg.preferences.isTextInteractionEnabled = false
        #endif

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = coordinator
        // Transparent, or the webview paints its own white sheet over the app's dark inspector.
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")   // no public API for this on macOS
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #endif
        web.load(URLRequest(url: DocumentSchemeHandler.pageURL))
        return web
    }

    fileprivate func payload() -> [String: Any] {
        // Map the app's Theme onto the custom properties reader.css consumes. These names must stay in
        // sync with the `var(--…)` fallbacks in the stylesheet.
        let colors: [String: String] = [
            "text": theme.text2.cssHex,
            "text2": theme.text3.cssHex,
            "accent": theme.accent.cssHex,
            "sel": theme.accent.cssRGBA(0.16),
            "flash": theme.amber.dot.cssRGBA(0.38),
            "code": theme.chip.cssHex,
            "hair": theme.hair.cssHex,
        ]
        return [
            "markdown": markdown,
            "platform": platformKey,
            // The document's DIRECTORY resolves relative image sources; its full PATH keys the flash
            // baseline, so switching files does not flash every block.
            "documentDir": (documentPath as NSString).deletingLastPathComponent,
            "documentPath": documentPath,
            "theme": colors,
        ]
    }

    private var platformKey: String {
        #if os(iOS)
        return "ios"
        #else
        return "mac"
        #endif
    }
}

#if os(macOS)
extension DocumentWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.push(payload(), into: web)
    }
}
#else
extension DocumentWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.push(payload(), into: web)
    }
}
#endif
