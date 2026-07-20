import Foundation
import Testing
@testable import OrchestraKit

@Suite("Transcript image references")
struct TranscriptImageTests {

    @Test("only the exact opaque Orchestra media URL resolves")
    func exactURLOnly() {
        let id = UUID()
        let canonical = TranscriptImageLink.url(for: id)

        #expect(TranscriptImageLink.referenceID(from: canonical) == id)
        #expect(TranscriptImageLink.referenceID(from: "file:///tmp/image.png") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://example.com/media/\(id.uuidString)") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid/media/\(id.uuidString)?x=1") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid/media/\(id.uuidString)#preview") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid:443/media/\(id.uuidString)") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://agent@orchestra.invalid/media/\(id.uuidString)") == nil)
        #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid/media/\(id.uuidString)/extra") == nil)
    }

    @Test("marker has OSC 8 open and close sequences plus a visible fallback")
    func markerHasBothForms() {
        let id = UUID()
        let url = TranscriptImageLink.url(for: id)
        let line = TranscriptImageMarker.render(referenceID: id, caption: "diagram")
        let open = "\u{1B}]8;id=orchestra-\(id.uuidString.lowercased());\(url)\u{1B}\\"
        let close = "\u{1B}]8;;\u{1B}\\"

        #expect(line.contains(open))
        #expect(line.contains("▣ Image: diagram · preview"))
        #expect(line.contains(close))
        #expect(line.contains(url))
    }

    @Test("caption controls are stripped and a fallback caption is supplied")
    func markerCaptionIsSafe() {
        let id = UUID()
        #expect(TranscriptImageMarker.render(referenceID: id, caption: "chart\n\u{1B}[31m").contains("▣ Image: chart[31m · preview"))
        #expect(TranscriptImageMarker.render(referenceID: id, caption: "\n\u{1B}").contains("▣ Image: image · preview"))
    }

    @Test("capture tokenizer links only exact Orchestra fallback URLs")
    func tokenizerPreservesOrdinaryText() {
        let id = UUID()
        let url = TranscriptImageLink.url(for: id)
        let segments = TranscriptImageTextTokenizer.tokenize("web https://example.com/x media \(url)!")

        #expect(segments == [.text("web https://example.com/x media "), .reference(id), .text("!")])
    }

    @Test("capture tokenizer rejects a query, fragment, and extra media path")
    func tokenizerRejectsURLContinuations() {
        let id = UUID()
        let base = TranscriptImageLink.url(for: id)

        for invalid in ["\(base)?download=1", "\(base)#preview", "\(base)/full"] {
            #expect(TranscriptImageTextTokenizer.tokenize(invalid) == [.text(invalid)])
        }
    }

    // MARK: - Hyperlink payload (the SwiftTerm-stored OSC 8 body)

    @Test("the OSC 8 body SwiftTerm stores per cell round-trips to the reference")
    func hyperlinkPayloadResolves() {
        let id = UUID()
        // SwiftTerm keeps the OSC 8 params-and-URL body verbatim — exactly the bytes the marker's opener
        // emits between `ESC ] 8 ;` and the string terminator: "id=orchestra-<uuid>;<url>".
        let payload = "id=orchestra-\(id.uuidString.lowercased());\(TranscriptImageLink.url(for: id))"
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: payload) == id)
    }

    @Test("a payload without the params/URL separator is not a media link")
    func hyperlinkPayloadRequiresSeparator() {
        let id = UUID()
        // A bare URL with no leading `params;` is not the shape SwiftTerm stores for an OSC 8 link.
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: TranscriptImageLink.url(for: id)) == nil)
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: "") == nil)
    }

    @Test("only the exact opaque media URL in the payload resolves")
    func hyperlinkPayloadRejectsForeignURLs() {
        let id = UUID()
        // The URL half is held to the same fixed grammar as every other entry point.
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: "id=x;https://example.com/media/\(id.uuidString)") == nil)
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: "id=x;\(TranscriptImageLink.url(for: id))?x=1") == nil)
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: "id=x;file:///tmp/a.png") == nil)
        // A URL that itself contains a ';' still resolves — the split is one-shot, params then URL.
        #expect(TranscriptImageLink.referenceID(fromHyperlinkPayload: ";\(TranscriptImageLink.url(for: id))") == id)
    }

}

@Suite("Terminal grid hit geometry")
struct TerminalGridGeometryTests {

    // An 80×24 grid drawn in a viewport that fits it exactly: 8pt-wide, 16pt-tall cells.
    private let viewport = (width: 640.0, height: 384.0)

    @Test("a tap in the middle of a cell maps to that cell")
    func mapsPointToCell() {
        // Column 10 spans x∈[80,88); row 5 spans y∈[80,96). A point mid-cell lands on (10, 5).
        let hit = TerminalGridGeometry.screenCell(
            contentX: 84, contentY: 88, scrollOffsetX: 0, scrollOffsetY: 0,
            viewportWidth: viewport.width, viewportHeight: viewport.height, cols: 80, rows: 24)
        #expect(hit?.col == 10)
        #expect(hit?.row == 5)
    }

    @Test("the scroll offset is subtracted, so content-space maps to the visible screen row")
    func subtractsScrollOffset() {
        // A finger physically on the top visible row (screen row 0) reports a content-space y that
        // includes how far the buffer is scrolled. Subtracting the offset recovers screen row 0.
        let hit = TerminalGridGeometry.screenCell(
            contentX: 4, contentY: 320 + 8, scrollOffsetX: 0, scrollOffsetY: 320,
            viewportWidth: viewport.width, viewportHeight: viewport.height, cols: 80, rows: 24)
        #expect(hit?.row == 0)
        #expect(hit?.col == 0)
    }

    @Test("a tap outside the visible grid returns nil")
    func rejectsOutOfBounds() {
        // Below the last visible row.
        #expect(TerminalGridGeometry.screenCell(
            contentX: 4, contentY: 10_000, scrollOffsetX: 0, scrollOffsetY: 0,
            viewportWidth: viewport.width, viewportHeight: viewport.height, cols: 80, rows: 24) == nil)
        // Above the top (a point that scrolled above the visible origin).
        #expect(TerminalGridGeometry.screenCell(
            contentX: 4, contentY: 8, scrollOffsetX: 0, scrollOffsetY: 320,
            viewportWidth: viewport.width, viewportHeight: viewport.height, cols: 80, rows: 24) == nil)
    }

    @Test("a degenerate viewport or grid is rejected rather than dividing by zero")
    func rejectsDegenerateGeometry() {
        #expect(TerminalGridGeometry.screenCell(
            contentX: 1, contentY: 1, scrollOffsetX: 0, scrollOffsetY: 0,
            viewportWidth: 0, viewportHeight: 384, cols: 80, rows: 24) == nil)
        #expect(TerminalGridGeometry.screenCell(
            contentX: 1, contentY: 1, scrollOffsetX: 0, scrollOffsetY: 0,
            viewportWidth: 640, viewportHeight: 384, cols: 0, rows: 24) == nil)
    }
}

/// The caption is the ONE place agent text becomes a filename, on the daemon and on both clients. These
/// pin the boundary that lets every consumer downstream skip sanitizing — if this suite goes soft, the
/// staged-file naming in App/TranscriptImagePreview.swift and App-iOS/Views/TranscriptImagePreview.swift
/// silently inherit the hole.
@Suite("Transcript image caption — the filename boundary")
struct TranscriptImageCaptionTests {

    @Test("a plain slug is accepted, dashes inside and alphanumeric ends")
    func acceptsSlugs() {
        #expect(TranscriptImageCaption.isValid("throughput-after-the-cache-fix"))
        #expect(TranscriptImageCaption.isValid("plot2"))
        #expect(TranscriptImageCaption.isValid("a"))
        #expect(TranscriptImageCaption.isValid("A1-b2-C3"))
    }

    @Test("path construction is unrepresentable, not sanitized away")
    func rejectsPathSyntax() {
        // The reason the daemon's storage and both clients can use a caption verbatim as a filename.
        for bad in ["../../etc/passwd", "..", ".", ".hidden", "a/b", "a:b", "/abs", "a\\b"] {
            #expect(!TranscriptImageCaption.isValid(bad), "should reject \(bad)")
        }
    }

    @Test("a leading or trailing dash is rejected — the flag-lookalike footgun")
    func rejectsEdgeDashes() {
        // `-foo.png` reads as options to every Unix tool, and invites a CLI parser to eat the value.
        #expect(!TranscriptImageCaption.isValid("-foo"))
        #expect(!TranscriptImageCaption.isValid("foo-"))
        #expect(!TranscriptImageCaption.isValid("-"))
    }

    @Test("format characters are rejected, not just control characters")
    func rejectsFormatCharacters() {
        // U+202E RIGHT-TO-LEFT OVERRIDE is category Cf, NOT Cc — a control-only filter passes it through
        // and it spoofs a filename's visible extension. Same for a zero-width space.
        #expect(!TranscriptImageCaption.isValid("photo\u{202E}gnp.exe"))
        #expect(!TranscriptImageCaption.isValid("a\u{200B}b"))
        #expect(!TranscriptImageCaption.isValid("chart\u{1B}[31m"))
        #expect(!TranscriptImageCaption.isValid("two words"))
    }

    @Test("length is capped in BYTES, and ASCII-only is what makes that exact")
    func lengthIsByteExact() {
        let atCap = String(repeating: "a", count: TranscriptImageCaption.maxLength)
        #expect(TranscriptImageCaption.isValid(atCap))
        #expect(atCap.utf8.count == TranscriptImageCaption.maxLength)
        #expect(!TranscriptImageCaption.isValid(atCap + "a"))
        // A multi-byte character can't smuggle past a character-counted cap, because it isn't legal here.
        #expect(!TranscriptImageCaption.isValid(String(repeating: "👨‍👩‍👧‍👦", count: 4)))
    }

    @Test("an omitted caption is legal; a present malformed one throws rather than being rewritten")
    func validatedRejectsRatherThanMunges() throws {
        #expect(try TranscriptImageCaption.validated(nil) == nil)
        #expect(try TranscriptImageCaption.validated("ok-name") == "ok-name")
        #expect(!TranscriptImageCaption.isValid(""))
        #expect(throws: TranscriptImageCaptionError.malformed) {
            try TranscriptImageCaption.validated("../escape")
        }
    }

    @Test("the advertised schema pattern IS the enforced rule")
    func schemaMatchesEnforcement() {
        // The MCP client validates against `pattern`; the daemon validates with `isValid`. If these ever
        // disagree an agent gets told one contract and held to another.
        for caption in ["throughput-after-the-cache-fix", "-foo", "a/b", "photo\u{202E}gnp"] {
            let matchesPattern = caption.range(of: TranscriptImageCaption.pattern,
                                               options: .regularExpression) != nil
            #expect(matchesPattern == TranscriptImageCaption.isValid(caption),
                    "schema pattern and isValid disagree on \(caption)")
        }
    }
}
