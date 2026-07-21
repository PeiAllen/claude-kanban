import Foundation
import Testing
@testable import OrchestraCore

/// Dedicated battery for `HandoffSeed.compose` (B1 task 5). `compose` itself landed early, in Task 4
/// (commit 1e31814) — `Inbox.claim`'s cold-relaunch route needed it before this task's slot came up — so
/// this file is retrofitting the spec's test coverage onto already-reviewed production code, not TDD'ing
/// new behavior. Two of these (`insufficientRemainderConsumesNothing`, `neverExceedsBudget`) are regression
/// tests for real loss shapes `compose` was written specifically to avoid: leasing a message it only
/// rendered a prefix of, and overrunning the budget at sub-marker-floor sizes.
@Suite("B1 · HandoffSeed.compose")
struct HandoffSeedComposeTests {
    func msg(_ t: String) -> InboxMessage { InboxMessage(cardId: UUID(), text: t) }

    @Test("handoff + messages: handoff first, inbox under its header, consumed counted")
    func composesBoth() {
        let r = HandoffSeed.compose(handoff: "prior context", messages: [msg("m1"), msg("m2")])
        let out = try! #require(r)
        #expect(out.consumed == 2)
        #expect(out.payload.hasPrefix("prior context"))
        #expect(out.payload.contains(StopDrain.inboxHeader(2)))
    }

    @Test("handoff-only: a non-empty payload with zero consumed — a handoff is never dropped")
    func handoffOnly() {
        let out = try! #require(HandoffSeed.compose(handoff: "just the handoff", messages: []))
        #expect(out.consumed == 0)
        #expect(out.payload == "just the handoff")
    }

    @Test("messages-only degrades to a message render")
    func messagesOnly() {
        let out = try! #require(HandoffSeed.compose(handoff: nil, messages: [msg("only")]))
        #expect(out.consumed == 1)
        #expect(out.payload.contains("only"))
    }

    @Test("a card source stays in metadata while the cold seed uses operator-relayed framing")
    func cardSourceStaysOutOfColdSeed() {
        let source = InboxMessageSource.card(id: UUID(), title: "child-review")
        let message = InboxMessage(cardId: UUID(), text: "result is ready", source: source)
        let out = try! #require(HandoffSeed.compose(handoff: nil, messages: [message]))

        #expect(out.payload.hasPrefix("Message from the user (relayed to you via Orchestra):"))
        #expect(out.payload.contains("result is ready"))
        #expect(out.payload.contains(source.label) == false)
    }

    @Test("nil when there is genuinely nothing to seed (and for a blank handoff)")
    func nothingToSeed() {
        #expect(HandoffSeed.compose(handoff: nil, messages: []) == nil)
        #expect(HandoffSeed.compose(handoff: "   \n ", messages: []) == nil)
    }

    @Test("the whole-message fit runs under ONE budget covering the handoff part")
    func fitsUnderOneBudget() {
        let handoff = String(repeating: "H", count: 200)
        // A budget that leaves room for the handoff + header + exactly one message.
        let one = HandoffSeed.compose(handoff: handoff, messages: [msg("m1")])!.payload.count
        let out = try! #require(HandoffSeed.compose(handoff: handoff,
                                                    messages: [msg("m1"), msg("m2")], budget: one))
        #expect(out.consumed == 1)                       // the tail stays pending, un-rendered
        #expect(out.payload.count <= one)
        #expect(!out.payload.contains("m2"))
    }

    @Test("a handoff that alone exceeds the budget still seeds, truncated — never dropped")
    func oversizedHandoffTruncates() {
        let out = try! #require(HandoffSeed.compose(handoff: String(repeating: "H", count: 500),
                                                    messages: [msg("m1")], budget: 100))
        #expect(out.consumed == 0)
        #expect(out.payload.count <= 100)
        #expect(!out.payload.isEmpty)
        #expect(out.payload.hasPrefix("[…truncated]"))   // marker present, mirroring fold
        #expect(out.payload.contains("H"))               // the actual handoff content, truncated
    }

    @Test("a handoff leaving too little room NEVER reports a truncated message as consumed")
    func insufficientRemainderConsumesNothing() {
        // The loss shape: a 9k handoff leaves ~1k, and StopDrain.fit's always-consume-≥1 fallback would
        // report `consumed: 1` for a 2k message it only rendered a PREFIX of — the claim would lease it
        // and a later confirm would delete the full original.
        let handoff = String(repeating: "H", count: 9_000)
        let big = msg(String(repeating: "m", count: 2_000))
        let out = try! #require(HandoffSeed.compose(handoff: handoff, messages: [big], budget: 10_000))
        #expect(out.consumed == 0)                       // the message stays pending, whole
        #expect(out.payload.count <= 10_000)             // and the seed never blows its budget
        #expect(!out.payload.contains("mmmm"))           // no partial render rode along
        #expect(out.payload == handoff)                  // the handoff context is NOT silently dropped
    }

    @Test("compose never exceeds its budget — including sub-marker-floor budgets")
    func neverExceedsBudget() {
        // Includes budgets below "[…truncated]\n".count (13) — the marker itself must be truncated,
        // not overrun. 1 and 5 are the cases the ≥40 sweep missed.
        for budget in [1, 5, 13, 40, 80, 120, 300] {
            let out = HandoffSeed.compose(handoff: String(repeating: "H", count: 100),
                                          messages: [msg("m1"), msg("m2")], budget: budget)
            #expect((out?.payload.count ?? 0) <= budget)
        }
    }
}
