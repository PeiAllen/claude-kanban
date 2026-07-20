import Foundation
import Testing
@testable import OrchestraCore

/// B3 — the `RolloutTailer` now hands each line its byte-start offset + source path (the fileTail
/// provenance the held-relaunch confirm fences on), and exposes a stateless `eofOffset` for the
/// post-kill watermark capture.
@Suite("B3 · RolloutTailer provenance")
struct RolloutTailerProvenanceTests {
    static func tmp() -> String { NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl" }

    @Test("newLines carry each line's byte start offset and the source path")
    func newLinesCarryStartOffsetAndPath() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        let tailer = RolloutTailer()
        try "alpha\nbravo\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lines = await tailer.newLines(cardId: card, path: path)
        #expect(lines.count == 2)
        #expect(lines[0].line == "alpha")
        #expect(lines[0].startOffset == 0)
        #expect(lines[0].path == path)
        #expect(lines[1].line == "bravo")
        #expect(lines[1].startOffset == 6)   // "alpha\n" is 6 bytes
    }

    @Test("a blank line advances the offset but is not emitted")
    func blankLineAdvancesOffsetButNotEmitted() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let tailer = RolloutTailer()
        try "one\n\nthree\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lines = await tailer.newLines(cardId: UUID(), path: path)
        #expect(lines.map(\.line) == ["one", "three"])
        #expect(lines[1].startOffset == 5)   // "one\n" (4) + "\n" (1)
    }

    @Test("only the offset advances across calls — a second read starts past the first")
    func offsetAdvancesAcrossCalls() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        let tailer = RolloutTailer()
        try "first\n".write(toFile: path, atomically: true, encoding: .utf8)
        _ = await tailer.newLines(cardId: card, path: path)
        let fh = FileHandle(forWritingAtPath: path)!
        try fh.seekToEnd(); fh.write(Data("second\n".utf8)); try fh.close()
        let lines = await tailer.newLines(cardId: card, path: path)
        #expect(lines.count == 1)
        #expect(lines[0].line == "second")
        #expect(lines[0].startOffset == 6)   // continues past "first\n"
    }

    @Test("eofOffset reads the file size; a missing file is 0")
    func eofOffsetReadsFileSize() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        try "0123456789".write(toFile: path, atomically: true, encoding: .utf8)   // 10 bytes
        #expect(RolloutTailer.eofOffset(path: path) == 10)
        #expect(RolloutTailer.eofOffset(path: Self.tmp()) == 0)   // missing → 0
    }

    @Test("a file shorter than the stored cursor (rotation) re-reads from offset 0")
    func rotationResetsOffset() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        let tailer = RolloutTailer()
        try "first-long-line\n".write(toFile: path, atomically: true, encoding: .utf8)
        _ = await tailer.newLines(cardId: card, path: path)   // advance the cursor past the long line
        try "x\n".write(toFile: path, atomically: true, encoding: .utf8)   // rotation: file is now shorter
        let lines = await tailer.newLines(cardId: card, path: path)
        #expect(lines.count == 1)
        #expect(lines[0].line == "x")
        #expect(lines[0].startOffset == 0)   // re-read from the top
    }
}
