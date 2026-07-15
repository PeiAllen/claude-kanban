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

    @Test("desktop export cache removes expired files before LRU overflow")
    func desktopCacheUsesAgeThenLRU() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/old.png"), byteCount: 8,
                                            modifiedAt: now.addingTimeInterval(-8 * 86_400))
        let oldest = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 200,
                                               modifiedAt: now.addingTimeInterval(-3 * 86_400))
        let newest = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/b.png"), byteCount: 100,
                                               modifiedAt: now.addingTimeInterval(-60))

        #expect(TranscriptImageCachePolicy.filesToRemove(entries: [newest, old, oldest], now: now,
            maxAge: 7 * 86_400, maxBytes: 256 * 1024 * 1024) == [old.url])
        #expect(TranscriptImageCachePolicy.filesToRemove(entries: [newest, oldest], now: now,
            maxAge: 7 * 86_400, maxBytes: 250) == [oldest.url])
    }
}
