import Foundation

/// The set of LOCAL images a document references — the allowlist behind the `documentAsset` endpoint.
///
/// This is what keeps that endpoint from being a general worktree file read. Without it the daemon
/// serves any image-extension file under any card's worktree; with it, it serves only what the document
/// being read actually points at.
///
/// Scanning errs toward EXCLUSION. A reference form this misses degrades to a broken image, which is
/// visible and harmless. A form it wrongly includes widens the daemon's read surface, which is not. In
/// particular only the image form `![…](…)` counts — `[text](…)` is a link, and treating links as
/// images would re-widen the allowlist to any path a document happens to mention.
public enum MarkdownAssets {

    /// Worktree-relative paths of every local image `source` references, each resolved against
    /// `documentDir` and normalized. Remote URLs and `data:` URIs are excluded: the CSP blocks the first,
    /// and the page never asks the daemon for the second.
    public static func referencedImages(in source: String, documentDir: String) -> Set<String> {
        let text = stripNonRendering(stripFencedCode(MarkdownOutline.normalized(source)))
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

    /// `![alt](…)` — the `!` is load-bearing; a bare `[alt](…)` is a link, not an image. The lookbehind
    /// is load-bearing too: `\![alt](…)` is an ESCAPED bang, which renders as a literal `!` followed by
    /// a link. Matching it anyway allowlisted a file the page never asks for.
    private static let inlineImagePattern = #"(?<!\\)!\[[^\]]*\]\(([^)]*)\)"#
    /// `![alt][label]`, including the collapsed `![label][]` form.
    private static let refImagePattern = #"(?<!\\)!\[([^\]]*)\]\[([^\]]*)\]"#
    /// `[label]: destination` at the start of a line.
    private static let defPattern = #"(?m)^\ {0,3}\[([^\]]+)\]:\s*<?([^>\s]+)>?"#
    /// `<img … src=…>`, quoted either way or bare. The unquoted form is valid HTML and the page renders
    /// it, so omitting it here made a legitimate image 404 rather than keeping anything out.
    private static let imgTagPattern =
        #"(?i)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#

    /// Drop fenced code before scanning, so a document that DOCUMENTS markdown syntax cannot widen its own
    /// allowlist by containing an example image reference.
    private static func stripFencedCode(_ s: String) -> String {
        var kept: [Substring] = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                let run = trimmed.prefix { $0 == fenceChar }.count
                if run >= fenceLen, trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                    inFence = false; fenceLen = 0
                }
                continue
            }
            if let c = trimmed.first, c == "`" || c == "~" {
                let run = trimmed.prefix { $0 == c }.count
                if run >= 3 { inFence = true; fenceChar = c; fenceLen = run; continue }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Drop the two remaining spans that LOOK like markdown but never render as an image: inline code
    /// and HTML comments.
    ///
    /// Both are the same failure as fenced code, one scale down. A document explaining the syntax with
    /// `` `![x](secret.png)` `` renders a literal string, and a commented-out reference renders nothing
    /// at all — yet either one would put that file on the allowlist. The endpoint's whole claim is
    /// "only what this document points at", so a span the reader will never request must not widen it.
    ///
    /// This stays RECOGNITION rather than parsing, so it remains an approximation of what marked does.
    /// That is acceptable only because it errs toward exclusion, and because a wrong answer here widens
    /// the surface by in-tree IMAGE files, never by arbitrary ones — the containment and type gates
    /// downstream do not depend on it.
    private static func stripNonRendering(_ s: String) -> String {
        var text = s
        // HTML comments first: one may contain backticks.
        text = replacing(#"(?s)<!--.*?-->"#, in: text)
        // Inline code: a run of N backticks closed by the next run of exactly N.
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            out += rest[rest.startIndex..<open]
            let run = rest[open...].prefix { $0 == "`" }
            var search = rest.index(open, offsetBy: run.count)
            var closed = false
            while let next = rest[search...].firstIndex(of: "`") {
                let closing = rest[next...].prefix { $0 == "`" }
                if closing.count == run.count { search = rest.index(next, offsetBy: closing.count); closed = true; break }
                search = rest.index(next, offsetBy: closing.count)
            }
            if !closed { out += rest[open...]; return out }     // unterminated: keep it verbatim
            rest = rest[search...]
        }
        out += rest
        return out
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                           withTemplate: "")
    }

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
