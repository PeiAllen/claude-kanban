import Foundation

/// A card can be addressed by full UUID, shortId, or the orchestra://task/... URI. The resolver keys
/// on UUID/shortId and ignores any slug.
public enum TaskRef: Sendable, Equatable {
    case uuid(UUID)
    case short(String)
    case uri(String)

    /// Parse a free-form handle (what a CLI/MCP caller hands us) into a `TaskRef`.
    public init(parsing raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("orchestra://task/") {
            self = .uri(s)
        } else if let u = UUID(uuidString: s) {
            self = .uuid(u)
        } else {
            self = .short(s.lowercased())
        }
    }
}

/// Extract the bare short id from an `orchestra://task/<shortId>[-slug]` URI.
func shortId(fromURI uri: String) -> String? {
    guard let range = uri.range(of: "orchestra://task/", options: [.caseInsensitive]) else { return nil }
    let rest = uri[range.upperBound...]
    // shortId is the first 6 chars before any '-' slug separator.
    let firstSegment = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let candidate = String(firstSegment).lowercased()
    return candidate.isEmpty ? nil : candidate
}

/// Resolve a `TaskRef` against a list of tasks. Throws `OrchestraError.unknownTask` when not found
/// and `.ambiguousTask` when a short id matches more than one card.
public func resolve(_ ref: TaskRef, in tasks: [Task]) throws -> Task {
    switch ref {
    case .uuid(let u):
        guard let t = tasks.first(where: { $0.id == u }) else { throw OrchestraError.unknownTask(u.uuidString) }
        return t
    case .short(let s):
        let key = s.lowercased()
        // Allow either a 6-char shortId or a full uuid string passed as .short.
        if let u = UUID(uuidString: key), let t = tasks.first(where: { $0.id == u }) { return t }
        let matches = tasks.filter { $0.shortId == key }
        if matches.count > 1 { throw OrchestraError.ambiguousTask(key) }
        guard let t = matches.first else { throw OrchestraError.unknownTask(key) }
        return t
    case .uri(let uri):
        guard let sid = shortId(fromURI: uri) else { throw OrchestraError.unknownTask(uri) }
        return try resolve(.short(sid), in: tasks)
    }
}

/// Lower-cased, dash-separated, alphanumeric slug of a title (for the card ref).
public func slugify(_ title: String) -> String {
    let lowered = title.lowercased()
    var out = ""
    var lastDash = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastDash = false
        } else if !lastDash {
            out.append("-")
            lastDash = true
        }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(trimmed.prefix(48))
}

/// First line of a prompt, truncated — used to seed a card title.
public func titleSeed(from prompt: String, max: Int = 60) -> String {
    let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    if trimmed.count <= max { return trimmed }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: max)
    return String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
}
