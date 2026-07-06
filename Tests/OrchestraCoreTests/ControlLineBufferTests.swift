import Foundation
import Testing
@testable import OrchestraKit

/// P1.1 — the NDJSON line buffer that bridges NIO's async byte delivery to `Transport.readLine()`'s
/// synchronous contract. Pure; sibling of `LineReader`. See notes/designs/ios-real-device-transport/04-tests.md.
@Suite("ControlLineBuffer")
struct ControlLineBufferTests {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test("a single newline-terminated frame reads back without the newline")
    func singleLine() {
        let buf = ControlLineBuffer()
        buf.append(b("hello\n"))
        #expect(buf.readLine() == d("hello"))
    }

    @Test("multiple frames in one append come out in order")
    func multipleLinesOneAppend() {
        let buf = ControlLineBuffer()
        buf.append(b("a\nb\nc\n"))
        #expect(buf.readLine() == d("a"))
        #expect(buf.readLine() == d("b"))
        #expect(buf.readLine() == d("c"))
    }

    @Test("a frame split across two appends is reassembled")
    func frameSplitAcrossAppends() {
        let buf = ControlLineBuffer()
        buf.append(b("hel"))
        buf.append(b("lo\nwor"))
        #expect(buf.readLine() == d("hello"))
        buf.append(b("ld\n"))
        #expect(buf.readLine() == d("world"))
    }

    @Test("empty frames are preserved")
    func emptyLinesPreserved() {
        let buf = ControlLineBuffer()
        buf.append(b("\n\n"))
        #expect(buf.readLine() == d(""))
        #expect(buf.readLine() == d(""))
    }

    @Test("an incomplete trailing frame is dropped at EOF")
    func incompleteTrailingDroppedAtEOF() {
        let buf = ControlLineBuffer()
        buf.append(b("a\npartial"))
        #expect(buf.readLine() == d("a"))
        buf.signalEOF()
        #expect(buf.readLine() == nil)
    }

    @Test("EOF wakes a blocked reader with nil")
    func eofWakesBlockedReader() async {
        let buf = ControlLineBuffer()
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async { cont.resume(returning: buf.readLine()) }   // blocks until EOF
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { buf.signalEOF() }
        }
        #expect(result == nil)
    }
}
