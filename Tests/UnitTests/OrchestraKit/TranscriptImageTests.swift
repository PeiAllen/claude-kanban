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
}
