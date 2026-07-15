import Foundation

/// An opaque, daemon-issued reference to a temporary image attached to one card session.
public struct TranscriptImageReference: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardId: UUID
    public let sessionEpoch: Int
    public let caption: String
    public let mimeType: String
    public let filename: String

    public init(id: UUID, cardId: UUID, sessionEpoch: Int, caption: String,
                mimeType: String, filename: String) {
        self.id = id
        self.cardId = cardId
        self.sessionEpoch = sessionEpoch
        self.caption = caption
        self.mimeType = mimeType
        self.filename = filename
    }
}

/// The bounded image bytes returned to an app after it resolves an opaque reference.
public struct TranscriptImagePayload: Codable, Sendable, Equatable {
    public let reference: TranscriptImageReference
    public let dataBase64: String

    public init(reference: TranscriptImageReference, dataBase64: String) {
        self.reference = reference
        self.dataBase64 = dataBase64
    }
}

/// The exact link grammar shared by terminal handlers and capture fallback renderers.
public enum TranscriptImageLink {
    public static let origin = "https://orchestra.invalid"
    private static let prefix = "\(origin)/media/"

    public static func url(for id: UUID) -> String {
        "\(prefix)\(id.uuidString.lowercased())"
    }

    /// Accept an opaque media URL only when every byte belongs to Orchestra's fixed grammar. This is
    /// deliberately not a general URL parser: a query, fragment, port, or additional path segment must
    /// remain ordinary terminal text instead of becoming a privileged media request.
    public static func referenceID(from raw: String) -> UUID? {
        guard raw.hasPrefix(prefix) else { return nil }
        let identifier = String(raw.dropFirst(prefix.count))
        guard let id = UUID(uuidString: identifier),
              id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        else { return nil }
        return id
    }
}

/// Renders the agent-visible terminal marker. The readable fallback is intentional: renderers that
/// strip OSC control sequences still leave the exact opaque URL available for capture clients.
public enum TranscriptImageMarker {
    public static func render(referenceID: UUID, caption: String?) -> String {
        let url = TranscriptImageLink.url(for: referenceID)
        let label = "▣ Image: \(sanitizedCaption(caption)) · preview"
        let escape = "\u{1B}"
        let opener = "\(escape)]8;id=orchestra-\(referenceID.uuidString.lowercased());\(url)\(escape)\\"
        let closer = "\(escape)]8;;\(escape)\\"
        return "\(opener)\(label)\(closer) \(url)"
    }

    private static func sanitizedCaption(_ caption: String?) -> String {
        let rawCaption: String = caption ?? ""
        let stripped = rawCaption.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let text = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(text.prefix(120))
        return bounded.isEmpty ? "image" : bounded
    }
}

/// A capture-text segment. Only `.reference` receives an attributed terminal link on mobile.
public enum TranscriptImageTextSegment: Sendable, Equatable {
    case text(String)
    case reference(UUID)
}

/// Splits captured transcript text without interpreting arbitrary URLs or local filesystem paths.
public enum TranscriptImageTextTokenizer {
    public static func tokenize(_ text: String) -> [TranscriptImageTextSegment] {
        let prefix = "\(TranscriptImageLink.origin)/media/"
        var segments: [TranscriptImageTextSegment] = []
        var textStart = text.startIndex
        var searchStart = text.startIndex

        while let match = text.range(of: prefix, options: .literal, range: searchStart..<text.endIndex) {
            let idStart = match.upperBound
            guard let candidateEnd = text.index(idStart, offsetBy: 36, limitedBy: text.endIndex) else {
                break
            }

            let candidate = String(text[match.lowerBound..<candidateEnd])
            let hasContinuation = candidateEnd < text.endIndex && isURLContinuation(text[candidateEnd])
            guard let id = TranscriptImageLink.referenceID(from: candidate), !hasContinuation else {
                searchStart = match.upperBound
                continue
            }

            if textStart < match.lowerBound {
                segments.append(.text(String(text[textStart..<match.lowerBound])))
            }
            segments.append(.reference(id))
            textStart = candidateEnd
            searchStart = candidateEnd
        }

        if textStart < text.endIndex {
            segments.append(.text(String(text[textStart...])))
        }
        return segments
    }

    private static func isURLContinuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 47, 63, 35, 37, 95, 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
    }
}

/// Metadata used by the macOS preview export cache. It stays platform-neutral so eviction ordering is
/// hermetically testable without AppKit or filesystem access.
public struct TranscriptImageCacheEntry: Sendable, Equatable {
    public let url: URL
    public let byteCount: Int
    public let modifiedAt: Date

    public init(url: URL, byteCount: Int, modifiedAt: Date) {
        self.url = url
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

/// Deterministic removal policy for temporary desktop exports: expire old files first, then evict the
/// least-recently-modified survivors until their total size fits within the configured bound.
public enum TranscriptImageCachePolicy {
    public static func filesToRemove(entries: [TranscriptImageCacheEntry], now: Date,
                                     maxAge: TimeInterval, maxBytes: Int) -> [URL] {
        let stale = entries.filter { now.timeIntervalSince($0.modifiedAt) > maxAge }
        var retained = entries.filter { !stale.contains($0) }.sorted(by: isNewer)
        var total = retained.reduce(0) { $0 + $1.byteCount }
        var removed = stale.sorted(by: isOlder).map(\.url)

        while total > maxBytes, let oldest = retained.popLast() {
            total -= oldest.byteCount
            removed.append(oldest.url)
        }
        return removed
    }

    private static func isNewer(_ lhs: TranscriptImageCacheEntry, _ rhs: TranscriptImageCacheEntry) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.url.path > rhs.url.path
    }

    private static func isOlder(_ lhs: TranscriptImageCacheEntry, _ rhs: TranscriptImageCacheEntry) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.url.path < rhs.url.path
    }
}
