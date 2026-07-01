import Foundation
import Testing
@testable import OrchestraCore

@Suite("C1 · Inbox durable store")
struct InboxStoreTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }

    @Test("enqueue → drain preserves FIFO order, per card")
    func enqueueDrainOrder() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path)
        let a = UUID(); let b = UUID()
        try await inbox.enqueue(a, "a1")
        try await inbox.enqueue(b, "b1")
        try await inbox.enqueue(a, "a2")

        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])   // peek is non-destructive
        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])
        let drainedA = try await inbox.drain(a)
        #expect(drainedA.map(\.text) == ["a1", "a2"])
        #expect(await inbox.peek(a).isEmpty)                        // drain cleared a
        #expect(await inbox.peek(b).map(\.text) == ["b1"])          // b untouched
    }

    @Test("messages survive a daemon restart (new Inbox instance, same path)")
    func durableAcrossRestart() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        do {
            let inbox = Inbox(path: path)
            try await inbox.enqueue(card, "before restart")
        }
        // Fresh instance simulates a daemon restart — must read the persisted queue.
        let reborn = Inbox(path: path)
        #expect(await reborn.peek(card).map(\.text) == ["before restart"])
        #expect(try await reborn.drain(card).map(\.text) == ["before restart"])
    }
}

@Suite("C1 · StopDrain payload")
struct StopDrainTests {
    func msg(_ t: String) -> InboxMessage { InboxMessage(cardId: UUID(), text: t) }

    @Test("empty → nil")
    func emptyNil() { #expect(StopDrain.compose([]) == nil) }

    @Test("compose preserves order (FIFO)")
    func order() {
        let r = StopDrain.compose([msg("first"), msg("second")])
        let f = r?.range(of: "first"); let s = r?.range(of: "second")
        #expect(f != nil && s != nil && f!.lowerBound < s!.lowerBound)
    }

    @Test("payload is bounded to 10k chars")
    func bound() {
        let big = String(repeating: "x", count: 25_000)
        let r = StopDrain.compose([msg(big)])
        #expect(r != nil)
        #expect(r!.count <= StopDrain.maxPayloadChars)
    }

    @Test("blockJSON is valid decision:block with escaped reason")
    func blockJson() throws {
        let json = StopDrain.blockJSON(reason: "line1\n\"quoted\"")
        let parsed = try JSONValue.parse(Data(json.utf8))
        #expect(parsed["decision"]?.stringValue == "block")
        #expect(parsed["reason"]?.stringValue == "line1\n\"quoted\"")
    }
}
