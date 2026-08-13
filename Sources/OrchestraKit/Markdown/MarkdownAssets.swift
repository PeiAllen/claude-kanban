import Foundation

/// The set of LOCAL images a document references — the allowlist behind the `documentAsset` endpoint.
///
/// This is what keeps that endpoint from being a general worktree file read. Without it the daemon
/// serves any image-extension file under any card's worktree; with it, it serves only what the document
/// being read actually points at.
///
/// It scopes what a CLIENT may name. It does not police what a document's author may reference, and it
/// must not be mistaken for doing so: anyone who can write the document can simply write a real image
/// reference. So the exact boundary between "this regex calls it a reference" and "marked renders an
/// image" carries no weight — both sides of it are the author's own choice. Being approximate here is
/// free.
///
/// Only the image form `![…](…)` counts. `[text](…)` is a link, and treating links as images would widen
/// the allowlist to any path a document happens to mention, which is a different and much larger set.
public enum MarkdownAssets {

    /// Worktree-relative paths of every local image `source` references, each resolved against
    /// `documentDir` and normalized. Remote URLs and `data:` URIs are excluded: the CSP blocks the first,
    /// and the page never asks the daemon for the second.
    public static func referencedImages(in source: String, documentDir: String) -> Set<String> {
        // Scanned WHOLE, fenced code included. Stripping fences kept a document's own syntax examples
        // off the allowlist, which sounds tidy and defends against nobody: the author of that fence can
        // write a real image reference just as easily. It cost a hand-rolled fence state machine that
        // had to track marked's, and its only failure mode was 404ing a live image.
        let text = MarkdownOutline.normalized(source)
        var out = Set<String>()

        // Link reference DEFINITIONS first, so `![a][ref]` resolves whichever order the file uses.
        var definitions: [String: String] = [:]
        for m in matches(defPattern, in: text) {
            let label = m[1].lowercased()
            if definitions[label] == nil { definitions[label] = m[2] }
        }

        // `![alt](target)` — target may be <bracketed> and may carry a "title".
        for m in matches(inlineImagePattern, in: text) {
            add(target(fromInline: m[1]), to: &out, documentDir: documentDir)
        }
        // `![alt][label]` and the collapsed `![label][]`.
        for m in matches(refImagePattern, in: text) {
            let label = (m[2].isEmpty ? m[1] : m[2]).lowercased()
            if let dest = definitions[label] { add(dest, to: &out, documentDir: documentDir) }
        }
        // Raw `<img src=…>`, since the settled format keeps formatting HTML.
        for m in matches(imgTagPattern, in: text) {
            add([m[1], m[2], m[3]].first { !$0.isEmpty } ?? "", to: &out, documentDir: documentDir)
        }
        return out
    }

    /// Collapse `.` and `..`. MUST match `reader.js`'s `normalizePath`, or a path the page requests
    /// will not match the path this allowlists and the image silently 404s.
    public static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." { _ = out.popLast(); continue }
            out.append(seg)
        }
        return out.joined(separator: "/")
    }

    // MARK: - internals

    /// `![alt](…)` — the `!` is load-bearing; a bare `[alt](…)` is a link, not an image.
    private static let inlineImagePattern = #"!\[[^\]]*\]\(([^)]*)\)"#
    /// `![alt][label]`, including the collapsed `![label][]` form.
    private static let refImagePattern = #"!\[([^\]]*)\]\[([^\]]*)\]"#
    /// `[label]: destination` at the start of a line.
    private static let defPattern = #"(?m)^\ {0,3}\[([^\]]+)\]:\s*<?([^>\s]+)>?"#
    /// `<img … src=…>`, quoted either way or bare. The unquoted form is valid HTML and the page renders
    /// it, so omitting it here made a legitimate image 404 rather than keeping anything out.
    private static let imgTagPattern =
        #"(?i)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#

    /// Pull the destination out of an inline target: strip `<…>`, then drop any trailing "title".
    private static func target(fromInline raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), let close = s.firstIndex(of: ">") {
            return String(s[s.index(after: s.startIndex)..<close])
        }
        // A title is separated by whitespace and quoted; the destination is everything before it.
        if let space = s.firstIndex(where: { $0 == " " || $0 == "\t" }) { s = String(s[s.startIndex..<space]) }
        return s
    }

    private static func add(_ raw: String, to set: inout Set<String>, documentDir: String) {
        let src = raw.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty, !src.hasPrefix("//") else { return }
        // Anything carrying a scheme is remote or inline; neither is ours to serve.
        // Mirrors reader.js's /^[a-z][a-z0-9+.\-]*:/i EXACTLY. It must: a form one side treats as a
        // scheme and the other treats as a path is a silent 404 (`1x:a.png` was such a case).
        if let colon = src.firstIndex(of: ":") {
            let scheme = src[src.startIndex..<colon]
            if let first = scheme.first, first.isLetter,
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                return
            }
        }
        // Strip a query or fragment, then PERCENT-DECODE. WebKit percent-decodes `url.path` before the
        // scheme handler ever sees it, so an allowlist holding the still-encoded text can never match:
        // `![x](images/my%20image.png)` is requested as `images/my image.png`. `%20` is the
        // CommonMark-canonical space and what most editors emit, so this is the common case.
        var cleaned = src
        if let cut = cleaned.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            cleaned = String(cleaned[cleaned.startIndex..<cut])
        }
        cleaned = cleaned.removingPercentEncoding ?? cleaned
        guard !cleaned.isEmpty else { return }
        let joined = cleaned.hasPrefix("/") ? String(cleaned.dropFirst())
                                            : (documentDir.isEmpty ? cleaned : documentDir + "/" + cleaned)
        let path = normalize(joined)
        guard !path.isEmpty else { return }
        set.insert(path)
    }

    /// All capture groups for every match; a group that did not participate reads as "".
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
