import SwiftUI
import WebKit
import OrchestraKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the page reports back: a 1-based inclusive source line range, and nothing else.
///
/// The page also posts a `blockIndex`, which is still validated on arrival — a malformed payload must
/// not become a selection — but it is not carried here. Swift never needed it: the page highlights the
/// selected blocks itself, and the quote comes from the line range.
public struct DocumentSelection: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int
    /// The RENDERED text the user dragged through, as the page measured it — and untrusted, like
    /// everything else the page says. `DocumentComment.capture` quotes it only after proving the same
    /// words occur in Swift's own copy of these lines, and otherwise quotes the whole line range.
    ///
    /// It exists because the line range alone is coarse. Source and rendered text differ, so the page
    /// can rarely prove which lines a selection fell on, and the quote then covered a whole paragraph
    /// when the user had picked four words.
    public let text: String?
    /// The page's own id for the tint it just painted. Swift never interprets it — it stores the id on
    /// the comment and hands the set back, so both sides agree on which passages are still anchored.
    /// The page mints it because the page holds the character offsets, which never cross the bridge.
    public let highlightID: String?

    public init(startLine: Int, endLine: Int, text: String? = nil, highlightID: String? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.highlightID = highlightID
    }
}

/// What the reader tells the page about the rail: which passages still have a comment, and which one
/// the reviewer is looking at.
struct DocumentHighlights: Equatable {
    var keep: [String] = []
    var active: String?
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
    /// Which passages the rail still holds a comment for, and which is focused.
    let highlights: DocumentHighlights
    /// A passage to scroll into view, changed by the rail when a card is clicked. Carrying it as state
    /// rather than as an imperative call keeps this a value type that SwiftUI can diff.
    let reveal: String?
    let assetProvider: @Sendable (String) async -> DocumentAsset?
    let onSelect: (DocumentSelection) -> Void
    /// The agent rewrote these anchored passages, so their tints could not be re-placed.
    let onDetached: ([String]) -> Void
    /// The topmost anchored passage in the viewport, so the rail can follow the reading position.
    let onVisible: (String) -> Void

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
        var onDetached: ([String]) -> Void
        var onVisible: (String) -> Void
        /// The most recent payload, held until the page is ready. `evaluateJavaScript` routinely races
        /// the initial load — `window.orchestra` does not exist until reader.js has executed — so the
        /// first render is queued and flushed from `didFinish`.
        private var pending: String?
        private var pendingHighlights: String?
        private var pendingReveal: String?
        private var loaded = false
        /// The last payload actually handed to the page. SwiftUI re-runs `body` for ANY published
        /// change — a keystroke in the compose field, a filter edit, or any board tick, since the view
        /// holds BoardModel as an EnvironmentObject. `render()` rebuilds the DOM and drops every `.sel`
        /// class, so pushing unconditionally erases the user's selection highlight on the first
        /// keystroke, and re-lexes the whole document several times a second on a busy board.
        private var lastSent: String?
        private var lastHighlights: String?
        private var lastReveal: String?

        /// Hard cap on the selected text the page may report. Comfortably above the excerpt cap the
        /// comment applies later, so the cap never truncates a quote a user could actually have made.
        static let selectedTextCap = 4000

        init(onSelect: @escaping (DocumentSelection) -> Void,
             onDetached: @escaping ([String]) -> Void,
             onVisible: @escaping (String) -> Void) {
            self.onSelect = onSelect
            self.onDetached = onDetached
            self.onVisible = onVisible
        }

        func push(_ payload: [String: Any], into web: WKWebView) {
            guard let json = Self.encode(payload) else { return }
            guard json != lastSent else { return }        // nothing changed — leave the DOM alone
            lastSent = json
            guard loaded else { pending = json; return }
            evaluate(json, in: web)
        }

        /// The rail's state, pushed on its OWN channel rather than inside the render payload.
        ///
        /// Folding it into the payload would rebuild the DOM and re-lex the whole document every time
        /// the reviewer clicked a different card — and rebuilding is exactly what drops the tints.
        func pushHighlights(_ state: DocumentHighlights, into web: WKWebView) {
            let payload: [String: Any] = state.active
                .map { ["keep": state.keep, "active": $0] } ?? ["keep": state.keep]
            guard let json = Self.encode(payload), json != lastHighlights else { return }
            lastHighlights = json
            guard loaded else { pendingHighlights = json; return }
            web.evaluateJavaScript("window.orchestra.setHighlights(\(json))")
        }

        /// Scroll a passage into view. Driven by a changing value, so clicking the SAME card twice does
        /// nothing — which is correct: the passage is already where the reviewer put it.
        func pushReveal(_ id: String?, into web: WKWebView) {
            guard let id, id != lastReveal else { return }
            lastReveal = id
            guard loaded else { pendingReveal = id; return }
            guard let json = Self.encode(["id": id]) else { return }
            web.evaluateJavaScript("(function(o){window.orchestra.reveal(o.id);})(\(json))")
        }

        private static func encode(_ payload: [String: Any]) -> String? {
            guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            else { return nil }
            return String(data: d, encoding: .utf8)
        }

        /// `json` is already serialized — the payload is never string-interpolated raw, because
        /// document content is untrusted and would otherwise be a script-injection vector straight
        /// through the bridge.
        private func evaluate(_ json: String, in web: WKWebView) {
            web.evaluateJavaScript("(function(o){window.orchestra.render(o.markdown,o);})(\(json))")
        }

        /// Render FIRST, then the rail state — `setHighlights` needs blocks to attach to.
        func webView(_ web: WKWebView, didFinish _: WKNavigation!) {
            loaded = true
            if let p = pending { pending = nil; evaluate(p, in: web) }
            if let h = pendingHighlights {
                pendingHighlights = nil
                web.evaluateJavaScript("window.orchestra.setHighlights(\(h))")
            }
            if let r = pendingReveal {
                pendingReveal = nil
                lastReveal = nil                          // re-push through the normal path
                pushReveal(r, into: web)
            }
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            // The page speaks three sentences and no others. Every one of them carries ids, indices,
            // and line numbers — never a path, never a request, and never content the app acts on
            // without proving it first. Anything not exactly one of these shapes is dropped.
            guard m.name == "orchestraSelection", let d = m.body as? [String: Any] else { return }
            switch d["kind"] as? String {
            case "selection":  handleSelection(d)
            case "detached":   handleDetached(d)
            case "visible":    handleVisible(d)
            default:           return
            }
        }

        private func handleSelection(_ d: [String: Any]) {
            guard let block = d["blockIndex"] as? Int,
                  let start = d["startLine"] as? Int,
                  let end = d["endLine"] as? Int,
                  let highlight = d["highlight"] as? String,
                  block >= 0, start >= 1, end >= start,
                  Self.isHighlightID(highlight) else { return }
            // Capped here as well as in the page. The page's own cap is a courtesy, and a bridge must
            // not size a buffer from a number the other side chose.
            let text = (d["text"] as? String).map { String($0.prefix(Self.selectedTextCap)) }
            onSelect(DocumentSelection(startLine: start, endLine: end, text: text, highlightID: highlight))
        }

        private func handleDetached(_ d: [String: Any]) {
            guard let ids = d["ids"] as? [String] else { return }
            let clean = ids.filter(Self.isHighlightID)
            guard !clean.isEmpty else { return }
            onDetached(clean)
        }

        private func handleVisible(_ d: [String: Any]) {
            guard let id = d["highlight"] as? String, Self.isHighlightID(id) else { return }
            onVisible(id)
        }

        /// A highlight id is echoed back into JavaScript inside `setHighlights`, so it is validated on
        /// arrival rather than trusted. It is serialized as JSON there, which already escapes it — this
        /// is the second layer, and it keeps the id a token instead of a string of unknown shape.
        static func isHighlightID(_ s: String) -> Bool {
            s.count <= 16 && s.first == "h" && s.dropFirst().allSatisfy(\.isNumber) && s.count > 1
        }

        /// A jetsammed content process leaves the page blank and every later `evaluateJavaScript` a
        /// silent no-op. Reload, and let the next `push` re-send (the cache is cleared so it will).
        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            loaded = false
            lastSent = nil
            lastHighlights = nil
            lastReveal = nil
            web.load(URLRequest(url: DocumentSchemeHandler.pageURL))
        }

        /// A failed FIRST load must not leave the navigation gate open.
        func webView(_ web: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            loaded = true
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onDetached: onDetached, onVisible: onVisible)
    }

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
        //
        // `underPageBackgroundColor` is PUBLIC (macOS 12 / iOS 15, both below our deployment targets).
        // The older trick is `setValue(false, forKey: "drawsBackground")`, which is KVC against a
        // private property — and an NSUnknownKeyException from that is not catchable in Swift, so a
        // future SDK renaming it would crash the app rather than degrade.
        //
        // The page ALSO paints its own ground from the theme (see `payload()`), so the reader looks
        // right even if a platform stops honoring transparency here.
        web.underPageBackgroundColor = .clear
        #if os(iOS)
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
        //
        // `cssColor` throughout, never a hex form: `chip` and `hair` are translucent OVERLAYS, and a
        // conversion that drops their alpha paints solid black code blocks on a white card.
        //
        // The reader renders PROSE, so it takes the theme's PRIMARY text color. It previously took
        // `text2`, which is the secondary color the app uses for labels and captions, and a whole
        // document set in it read as muted chrome rather than as something to read.
        let colors: [String: String] = [
            "bg": theme.card.cssColor,
            "text": theme.text.cssColor,
            "text2": theme.text2.cssColor,
            "text3": theme.text3.cssColor,
            "accent": theme.accent.cssColor,
            // THE LIVE SELECTION keeps the accent, because that is what a selection looks like
            // everywhere else in the app.
            "sel": theme.accent.cssRGBA(0.22),
            // AN ANCHORED PASSAGE gets its own hue. It is a different thing from a selection — it
            // persists, it belongs to a comment, and it stays on screen after the drag is over — so it
            // must not be the same color. Indigo is the one semantic hue left unclaimed here: the
            // accent is selection, amber is the change flash, and green and red are status.
            //
            // Two strengths, and only strengths. A highlight shows focus by WEIGHT and never gains a
            // border: one anchored passage is several spans whenever it crosses inline markup, and an
            // edge would draw a seam at every join.
            "anno": theme.indigo.dot.cssRGBA(0.30),
            "annoIdle": theme.indigo.dot.cssRGBA(0.14),
            // The same hue at full strength, for the one thing that floats OVER body text and so
            // cannot be transparent — the "Comment" offer.
            "annoSolid": theme.indigo.dot.cssColor,
            "flash": theme.amber.dot.cssRGBA(0.38),
            "code": theme.chip.cssColor,
            "hair": theme.hair.cssColor,
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
        context.coordinator.onDetached = onDetached
        context.coordinator.onVisible = onVisible
        context.coordinator.push(payload(), into: web)
        context.coordinator.pushHighlights(highlights, into: web)
        context.coordinator.pushReveal(reveal, into: web)
    }
}
#else
extension DocumentWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onDetached = onDetached
        context.coordinator.onVisible = onVisible
        context.coordinator.push(payload(), into: web)
        context.coordinator.pushHighlights(highlights, into: web)
        context.coordinator.pushReveal(reveal, into: web)
    }
}
#endif
