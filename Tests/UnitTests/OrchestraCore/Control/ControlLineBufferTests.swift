import Foundation
import Testing
@testable import OrchestraKit

/// P1.1 — the NDJSON line buffer that bridges NIO's async byte delivery to `Transport.readLine()`'s
/// synchronous contract. Pure; sibling of `LineReader`. See
/// docs/02-architecture.md § "The client transport seam and reconnect" (the `Transport`/`readLine` contract).
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

    @Test("an over-long frame (no newline past the cap) is dropped and the buffer resyncs (#11)")
    func overLongFrameDroppedAndResyncs() {
        let buf = ControlLineBuffer(maxPending: 16)
        buf.append(b("ok\n"))
        #expect(buf.readLine() == d("ok"))                 // a normal frame reads back
        buf.append(b("this-frame-is-way-too-long-with-no-newline-in-sight"))  // > 16 bytes, no '\n'
        buf.append(b("-still-going-and-going"))            // dropped, still resyncing
        buf.append(b("\nnext\n"))                          // the newline resyncs framing
        #expect(buf.readLine() == d("next"))               // the oversized frame was dropped; we resync cleanly
    }

    @Test("EOF wakes a blocked reader with nil")
    func eofWakesBlockedReader() async {
        let buf = ControlLineBuffer()
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async { cont.resume(returning: buf.readLine()) }   // blocks until EOF
            // No wall-clock delay: `eof` is sticky under the buffer's NSCondition, so whether signalEOF
            // lands before the reader parks (fast path: eof already set) or after (broadcast wakes it),
            // readLine returns nil either way — deterministic, no lost wakeup, no race on ordering.
            DispatchQueue.global().async { buf.signalEOF() }
        }
        #expect(result == nil)
    }
}
