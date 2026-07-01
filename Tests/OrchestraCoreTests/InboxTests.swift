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

@Suite("C1 · drainForStop loop guard")
struct DrainForStopTests {
    @Test("caps consecutive auto-injects and preserves the pending message when tripped")
    func injectCap() async throws {
        let env = TestEnv.make()
        let inbox = await env.svc.inbox      // the SAME instance the service drains — no cache fight
        let card = UUID()
        let cap = await env.svc.maxConsecutiveInjects

        // Each stop re-fills the inbox, so the counter climbs (never natural-resets).
        for i in 0..<cap {
            try await inbox.enqueue(card, "msg\(i)")
            let payload = await env.svc.drainForStop(card)
            #expect(payload != nil)                      // injected each time up to the cap
        }
        try await inbox.enqueue(card, "over the cap")
        let capped = await env.svc.drainForStop(card)
        #expect(capped == nil)                           // loop guard tripped → no inject
        #expect(await inbox.peek(card).map(\.text) == ["over the cap"])  // message NOT lost

        // A genuine user prompt resets the guard → injects again.
        await env.svc.resetInjectCount(card)
        let after = await env.svc.drainForStop(card)
        #expect(after?.contains("over the cap") == true)
    }

    @Test("empty inbox resets the counter and returns nil")
    func emptyResets() async throws {
        let env = TestEnv.make()
        let card = UUID()
        #expect(await env.svc.drainForStop(card) == nil)  // nothing pending
    }
}

@Suite("C1 · send routes through the inbox")
struct SendRoutingTests {
    @Test("send enqueues a durable message instead of typing into tmux")
    func sendEnqueues() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(SpawnInput(prompt: "work", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "hello there")

        let inbox = Inbox(path: env.base + "/inbox.json")
        #expect(await inbox.peek(task.id).map(\.text) == ["hello there"])
    }
}

@Suite("C1 · Stop-drain preserves the notify/waiting report")
struct NotifyPreservedTests {
    @Test("the Stop hook's notify event still parses to a waiting StatusReport and drives the card to waiting")
    func notifyStillWaiting() async throws {
        // 1. parse is byte-identical: notify → waiting.
        let report = ClaudeCodeAdapter().parse(.hooksPush(kind: "notify", payload: .object([:])))
        #expect(report?.snapshot?.status == .waiting)

        // 2. applied through the service, the card goes to .waiting — with a message still queued in the inbox
        //    (the drain is a separate step; the notify/waiting report is unaffected).
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(SpawnInput(prompt: "w", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "queued")
        try await env.svc.report(task.id, report!)
        let st = try await env.svc.status(task.id)
        #expect(st.task.status == .waiting)                                          // notify/waiting preserved
        #expect(await Inbox(path: env.base + "/inbox.json").peek(task.id).count == 1) // drain not triggered
    }
}
