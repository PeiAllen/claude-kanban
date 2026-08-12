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
        let text = stripFencedCode(MarkdownOutline.normalized(source))
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
            add(m[1].isEmpty ? m[2] : m[1], to: &out, documentDir: documentDir)
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
    /// `<img … src="…">` with either quote style.
    private static let imgTagPattern = #"(?i)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#

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
        if let colon = src.firstIndex(of: ":") {
            let scheme = src[src.startIndex..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                return
            }
        }
        let joined = src.hasPrefix("/") ? String(src.dropFirst())
                                        : (documentDir.isEmpty ? src : documentDir + "/" + src)
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
