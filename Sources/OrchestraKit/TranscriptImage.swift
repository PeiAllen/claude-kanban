import Foundation

/// The one definition of a legal transcript image caption, shared so the advertised contract and the
/// enforced contract cannot drift: `CommandCatalog` publishes `pattern`/`maxLength` from here into the
/// `publish-image` tool schema (so an MCP client rejects a bad caption before the call), and the daemon
/// handler validates with `validate` (so every client path — CLI, MCP, anything later — is covered, since
/// the registry dispatches on `phaseGate` alone and never validates params against a schema).
///
/// A caption is deliberately a slug, not free text, because it is ALSO the filename every client gives
/// the copy it stages for the user. Constraining the input at the boundary is what lets every consumer
/// downstream skip sanitizing: the daemon, the macOS export, and the iOS staged file can each use the
/// caption verbatim as a filename stem, and no path can be built out of agent text that was never legal.
///
/// The rule is the hostname-label shape — alphanumeric ends, dashes only inside:
///   * dashes only INSIDE, so a caption can never produce `-foo.png`, which every Unix tool reads as
///     flags and which invites a CLI arg parser to eat the value as an option;
///   * ASCII only, which bans `/` and `:` (path separators), leading dots (`..`), and — the subtle one —
///     Unicode *format* characters like U+202E RIGHT-TO-LEFT OVERRIDE, which are NOT control characters
///     and would otherwise survive a control-stripping filter to spoof a filename's visible extension;
///   * ASCII also makes the length cap byte-exact, so `maxBytes` cannot be overrun by multi-byte
///     characters the way a Character-counted cap can (120 emoji = ~480 bytes > NAME_MAX).
public enum TranscriptImageCaption {
    /// Bytes == characters here, since every legal character is ASCII. Comfortably inside NAME_MAX (255)
    /// with room for an extension and the enclosing directory.
    public static let maxLength = 80

    /// Hostname-label shape. A single character must still be alphanumeric, hence the optional tail.
    public static let pattern = "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$"

    /// The human-facing rule, one sentence — reused verbatim by the tool schema, the CLI help, and the
    /// agent-facing guidance so an agent reads the same contract wherever it looks.
    public static let rule =
        "letters, digits and dashes only, starting and ending alphanumeric, \(maxLength) characters max"

    public static func isValid(_ caption: String) -> Bool {
        guard !caption.isEmpty, caption.utf8.count <= maxLength else { return false }
        return caption.range(of: pattern, options: .regularExpression) != nil
    }

    /// A nil/omitted caption is legal and means "no label" — only a PRESENT caption must be well-formed.
    /// Rejecting rather than munging is the point: a silently-rewritten caption would desync the label the
    /// agent believes it published from the filename the human sees.
    public static func validated(_ caption: String?) throws -> String? {
        guard let caption else { return nil }
        guard isValid(caption) else { throw TranscriptImageCaptionError.malformed }
        return caption
    }
}

public enum TranscriptImageCaptionError: Error, Equatable {
    case malformed
}

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
