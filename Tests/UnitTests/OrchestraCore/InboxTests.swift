import Foundation
import Testing
@testable import OrchestraCore

/// Write an on-disk inbox envelope directly — the fixture seam for migration/claimable tests.
func writeEnvelope(path: String, messages: [InboxMessage], confirmedIds: [UUID]) throws {
    struct Envelope: Encodable { let messages: [InboxMessage]; let confirmedIds: [UUID] }
    try OrchestraJSON.pretty.encode(Envelope(messages: messages, confirmedIds: confirmedIds))
        .write(to: URL(fileURLWithPath: path))
}

@Suite("B1 · Inbox claim")
struct InboxClaimTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }
    static let t0 = Date(timeIntervalSince1970: 10_000)
    /// The stop-drain render: whole-message FIFO fit under the budget.
    // @Sendable is REQUIRED: Package.swift is tools-6.0 with no language-mode override, so a static let
    // of a bare function type is "not concurrency-safe" (#MutableGlobalVariable) and won't compile.
    static let fit: @Sendable ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { StopDrain.fit($0, budget: $1) }

    @Test("claim leases EXACTLY the consumed prefix — the over-budget tail stays pending")
    func claimLeasesExactConsumedPrefix() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        // A budget that fits the header + exactly one of these two messages.
        for t in ["first", "second"] { try await inbox.enqueue(card, t) }
        let oneFits = StopDrain.renderMessages([InboxMessage(cardId: card, text: "first")]).count + 10
        let batch = try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: oneFits,
                                          render: Self.fit, now: Self.t0)
        let b = try #require(batch)
        #expect(b.ids.count == 1)
        #expect(b.payload.contains("first"))
        #expect(!b.payload.contains("second"))                    // never rendered…
        let rows = await inbox.peek(card)
        #expect(rows.first(where: { $0.text == "first" })?.lease?.token == b.token)
        #expect(rows.first(where: { $0.text == "second" })?.lease == nil)  // …so never leased
    }

    @Test("a fresh lease is not claimable by another route, and blocks nothing behind it")
    func freshLeaseNotClaimableByOtherRoute() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        for t in ["a", "b"] { try await inbox.enqueue(card, t) }
        let first = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                       render: { ms, bud in StopDrain.fit(Array(ms.prefix(1)), budget: bud) },
                                                       now: Self.t0))
        #expect(first.ids.count == 1)
        // A channelPush claim 1s later skips the freshly-leased "a" and takes "b".
        let second = try #require(try await inbox.claim(card, route: .channelPush, epoch: 1, budget: 10_000,
                                                        render: Self.fit, now: Self.t0.addingTimeInterval(1)))
        #expect(second.payload.contains("b"))
        // NOT plain `!contains("a")`: the provenance header itself contains the letter "a" ("Orchestra",
        // "message", "instructions", "agent", "act", …), so that check can never pass regardless of
        // correctness. `renderMessages` always places a lone message's text immediately after "\n\n"
        // with nothing else following, so this checks the message SLOT specifically.
        #expect(!second.payload.contains("\n\na"))
        #expect(second.token != first.token)
    }

    @Test("a lease older than the timeout is re-claimable, minting a fresh token")
    func expiredLeaseReclaimableWithFreshToken() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path, leaseTimeout: 60); let card = UUID()
        try await inbox.enqueue(card, "m")
        let a = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))
        // 59s: still leased, not claimable.
        #expect(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                      render: Self.fit, now: Self.t0.addingTimeInterval(59)) == nil)
        // 61s: expired → re-claimable, fresh token invalidating the old one.
        let b = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0.addingTimeInterval(61)))
        #expect(b.token != a.token)
        #expect(b.ids == a.ids)
    }

    @Test("a lease from an older epoch is re-claimable IMMEDIATELY — no waiting out the timeout")
    func staleEpochLeaseReclaimableImmediately() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        _ = try await inbox.claim(card, route: .channelPush, epoch: 1, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        // Epoch 2's claim one second later: the epoch-1 session is provably gone.
        let b = try await inbox.claim(card, route: .relaunchSeed, epoch: 2, budget: 10_000,
                                      render: Self.fit, now: Self.t0.addingTimeInterval(1))
        #expect(b?.ids.count == 1)
    }

    @Test("a relaunchSeed claim re-owns its OWN prior relaunchSeed lease at any epoch")
    func relaunchSeedReownsOwnLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        let a = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 5, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))
        // The relaunch timed out; the retry re-steps at the SAME epoch, well inside the timeout.
        // Without re-own it would come up seedless.
        let b = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 5, budget: 10_000,
                                                   render: Self.fit, now: Self.t0.addingTimeInterval(2)))
        #expect(b.ids == a.ids)
        #expect(b.token != a.token)
        // …but another route may NOT steal that fresh lease.
        #expect(try await inbox.claim(card, route: .stopDrain, epoch: 5, budget: 10_000,
                                      render: Self.fit, now: Self.t0.addingTimeInterval(3)) == nil)
    }

    @Test("claim is FIFO across cards and takes whole messages only")
    func claimFifoWholeMessages() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let a = UUID(); let b = UUID()
        try await inbox.enqueue(a, "a1"); try await inbox.enqueue(b, "b1"); try await inbox.enqueue(a, "a2")
        let batch = try #require(try await inbox.claim(a, route: .stopDrain, epoch: 1, budget: 10_000,
                                                       render: Self.fit, now: Self.t0))
        let aIds = await inbox.peek(a).map(\.id)
        #expect(batch.ids == aIds)                                // both of a's, in order
        #expect(await inbox.peek(b).first?.lease == nil)          // b untouched
    }

    @Test("a partial re-claim kills the old token on the unconsumed tail")
    func partialReclaimKillsStaleTailToken() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        for t in ["a", "b"] { try await inbox.enqueue(card, t) }
        // Epoch 1 leases BOTH under T0.
        let t0 = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                    render: Self.fit, now: Self.t0))
        #expect(t0.ids.count == 2)
        // The session dies; epoch bumps. The retry's budget only fits "a", so "b" is left behind — and
        // must NOT keep riding the now-dead T0.
        let t1 = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 2, budget: 10_000,
                                                    render: { ms, bud in StopDrain.fit(Array(ms.prefix(1)), budget: bud) },
                                                    now: Self.t0.addingTimeInterval(1)))
        #expect(t1.ids.count == 1)
        let tail = try #require(await inbox.peek(card).first(where: { $0.text == "b" }))
        #expect(tail.lease == nil)                        // dead token cleared, not left live
        // A late ack from the provably-gone epoch-1 session must not delete an undelivered message.
        try await inbox.confirm(token: t0.token)
        #expect(await inbox.peek(card).contains(where: { $0.text == "b" }))
    }

    @Test("a handoff-only relaunch claim returns a batch with zero ids; nil only when nothing to seed")
    func relaunchClaimNonNilOnHandoffOnly() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        // Empty inbox + a pending handoff → the handoff's context must NOT be silently dropped.
        let seed: ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { ms, bud in
            HandoffSeed.compose(handoff: "carry this context", messages: ms, budget: bud)
        }
        let b = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 1, budget: 10_000,
                                                   render: seed, now: Self.t0))
        #expect(b.ids.isEmpty)
        #expect(b.payload.contains("carry this context"))
        // No handoff AND no message → genuinely nothing to seed.
        let none: ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { ms, bud in
            HandoffSeed.compose(handoff: nil, messages: ms, budget: bud)
        }
        #expect(try await inbox.claim(card, route: .relaunchSeed, epoch: 1, budget: 10_000,
                                      render: none, now: Self.t0) == nil)
    }
}

@Suite("B1 · Inbox envelope migration")
struct InboxEnvelopeTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }

    @Test("a legacy bare array migrates to messages + an empty ring — never .bak")
    func legacyInboxArrayMigrates() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        let legacy = [InboxMessage(cardId: card, text: "pending send")]
        try OrchestraJSON.pretty.encode(legacy).write(to: URL(fileURLWithPath: path))

        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["pending send"])          // NOT dropped
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))          // NOT sidelined
        #expect(await inbox.wasConfirmed(UUID()) == false)                       // empty ring
    }

    @Test("a legacy array is rewritten as an envelope on the next persist")
    func legacyRewritesAsEnvelope() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        try OrchestraJSON.pretty.encode([InboxMessage(cardId: card, text: "old")])
            .write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        try await inbox.enqueue(card, "new")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(json is [String: Any])                                            // envelope, not array
        #expect(await Inbox(path: path).peek(card).map(\.text) == ["old", "new"]) // both survive
    }

    @Test("an envelope with leased and lease-less rows decodes")
    func envelopeWithLeasedRowsDecodes() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        let leased = InboxMessage(cardId: card, text: "leased",
                                  lease: DeliveryLease(route: .stopDrain, epoch: 1, leasedAt: Date()))
        try writeEnvelope(path: path, messages: [leased, InboxMessage(cardId: card, text: "free")],
                          confirmedIds: [])
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["leased", "free"])
        #expect(await inbox.peek(card).first?.lease?.route == .stopDrain)
    }

    @Test("one malformed row is dropped element-wise — the valid pending sends survive, no .bak")
    func malformedRowDroppedNotBaked() async throws {
        let path = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".bak") }
        let card = UUID()
        // A syntactically valid envelope whose middle row is missing `id` (the unrecoverable case).
        let json = """
        {"confirmedIds":[],"messages":[
          {"id":"\(UUID().uuidString)","cardId":"\(card.uuidString)","text":"good one","createdAt":"2020-01-01T00:00:00Z"},
          {"cardId":"\(card.uuidString)","text":"malformed — no id","createdAt":"2020-01-01T00:00:00Z"},
          {"id":"\(UUID().uuidString)","cardId":"\(card.uuidString)","text":"good two","createdAt":"2020-01-01T00:00:00Z"}
        ]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["good one", "good two"])   // valid sends kept
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))           // whole file NOT stranded
    }

    @Test("a malformed confirmed-id is dropped — the ring tolerates it, messages survive, no .bak")
    func malformedRingEntryDroppedNotBaked() async throws {
        let path = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".bak") }
        let card = UUID(); let goodId = UUID()
        // A structurally valid envelope whose ring holds one un-parseable id beside a good one.
        let json = """
        {"confirmedIds":["\(goodId.uuidString)","not-a-uuid"],"messages":[
          {"id":"\(UUID().uuidString)","cardId":"\(card.uuidString)","text":"pending","createdAt":"2020-01-01T00:00:00Z"}
        ]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["pending"])       // the valid send is NOT lost
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))  // a bad ring entry doesn't strand the file
        #expect(await inbox.wasConfirmed(goodId))                        // the parseable tombstone is kept
    }

    @Test("only top-level-unparseable JSON still .bak's")
    func corruptInboxStillBaks() async throws {
        let path = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".bak") }
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(UUID()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path + ".bak"))
    }
}

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

    @Test("enqueue stamps createdAt from the injected clock, not the wall clock")
    func enqueueUsesInjectedNow() async throws {
        let path = InboxEnvelopeTests.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let fixed = Date(timeIntervalSince1970: 1_000)
        let inbox = Inbox(path: path, now: { fixed })
        let card = UUID()
        try await inbox.enqueue(card, "m")
        #expect(await inbox.peek(card).first?.createdAt == fixed)
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

@Suite("Inbox edit / remove / reorder")
struct InboxEditTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }

    @Test("remove drops one message by id, leaves the rest")
    func removeOne() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "a"); try await inbox.enqueue(c, "b")
        let ids = await inbox.peek(c).map(\.id)
        try await inbox.remove(ids[0])
        #expect(await inbox.peek(c).map(\.text) == ["b"])
    }

    @Test("update replaces text only, preserving id/createdAt")
    func updateText() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "old")
        let m = try #require(await inbox.peek(c).first)
        try await inbox.update(m.id, text: "new")
        let after = try #require(await inbox.peek(c).first)
        #expect(after.text == "new")
        #expect(after.id == m.id)
        #expect(after.createdAt == m.createdAt)
    }

    @Test("update throws for an unknown message id")
    func updateUnknown() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path)
        await #expect(throws: OrchestraError.self) {
            try await inbox.update(UUID(), text: "x")
        }
    }

    @Test("reorder permutes a card's messages and preserves other cards' interleaving")
    func reorderPreservesInterleave() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let a = UUID(); let b = UUID()
        // array order: a1, b1, a2, a3
        try await inbox.enqueue(a, "a1"); try await inbox.enqueue(b, "b1")
        try await inbox.enqueue(a, "a2"); try await inbox.enqueue(a, "a3")
        let aIds = await inbox.peek(a).map(\.id)          // [a1, a2, a3]
        // new order for a: a3, a1, a2
        try await inbox.reorder(a, orderedIds: [aIds[2], aIds[0], aIds[1]])
        #expect(await inbox.peek(a).map(\.text) == ["a3", "a1", "a2"])
        #expect(await inbox.peek(b).map(\.text) == ["b1"])  // b untouched
    }

    @Test("reorder rejects a non-permutation of the card's ids")
    func reorderRejectsBadIds() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "a"); try await inbox.enqueue(c, "b")
        await #expect(throws: OrchestraError.self) {
            try await inbox.reorder(c, orderedIds: [UUID()])   // wrong ids
        }
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

    @Test("payload is bounded to 10k chars, header preserved even when body is truncated")
    func bound() {
        let big = String(repeating: "x", count: 25_000)
        let r = StopDrain.compose([msg(big)])
        #expect(r != nil)
        #expect(r!.count <= StopDrain.maxPayloadChars)
        #expect(r!.hasPrefix("📥 Orchestra inbox"))   // provenance header survives truncation
        #expect(r!.hasSuffix("[…truncated]"))
    }

    @Test("carries a channel-neutral provenance header naming Orchestra, pluralized by count")
    func provenanceHeader() {
        let one = StopDrain.compose([msg("do X")])
        #expect(one?.contains("1 queued message") == true)
        #expect(one?.contains("Orchestra") == true)
        #expect(one?.contains("do X") == true)
        // Channel-neutral: no Stop-hook-specific wording leaks in (shared with the Codex seed path).
        #expect(one?.lowercased().contains("turn-end") == false)
        #expect(one?.lowercased().contains("hook") == false)
        let two = StopDrain.compose([msg("a"), msg("b")])
        #expect(two?.contains("2 queued messages") == true)
    }

    @Test("multi-message batch is numbered [k/N]; a lone message is not")
    func numbering() {
        let three = StopDrain.compose([msg("a"), msg("b"), msg("c")])
        #expect(three?.contains("[1/3] a") == true)
        #expect(three?.contains("[2/3] b") == true)
        #expect(three?.contains("[3/3] c") == true)
        let one = StopDrain.compose([msg("solo")])
        #expect(one?.contains("[1/1]") == false)   // no redundant index on a single message
        #expect(one?.contains("solo") == true)
    }

    @Test("fit consumes only the whole messages that fit and reports the count")
    func fitPartial() {
        let big = String(repeating: "x", count: 4_000)
        let r = StopDrain.fit([msg(big), msg(big), msg(big)])   // 3×4k + header > 10k
        #expect(r != nil)
        #expect(r!.payload.count <= StopDrain.maxPayloadChars)
        #expect(r!.consumed >= 1 && r!.consumed < 3)             // at least one deferred, none sliced
    }

    @Test("fit always consumes at least one, truncating a lone oversized message")
    func fitOversizedSingle() {
        let huge = String(repeating: "y", count: 25_000)
        let r = StopDrain.fit([msg(huge)])
        #expect(r?.consumed == 1)
        #expect(r!.payload.count <= StopDrain.maxPayloadChars)
        #expect(r!.payload.hasSuffix("[…truncated]"))
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

    @Test("drains whole-messages-to-fit under the 10k bound and leaves the overflow for the next turn")
    func drainToFit() async throws {
        let env = TestEnv.make()
        let inbox = await env.svc.inbox
        let card = UUID()
        let big = String(repeating: "x", count: 4_000)          // 3×4k + header overflows one 10k payload
        for i in 0..<3 { try await inbox.enqueue(card, "\(i)-" + big) }

        let first = await env.svc.drainForStop(card)
        #expect(first != nil)
        #expect(first!.count <= StopDrain.maxPayloadChars)       // bounded
        let remaining = await inbox.peek(card)
        #expect(!remaining.isEmpty)                              // overflow deferred, not lost
        #expect(remaining.allSatisfy { $0.text.count == big.count + 2 })  // whole messages, never sliced

        let second = await env.svc.drainForStop(card)
        #expect(second != nil)
        #expect(await inbox.peek(card).isEmpty)                  // remainder delivered on the next turn-end
    }
}

@Suite("C1 · send routes through the inbox")
struct SendRoutingTests {
    @Test("send enqueues a durable message instead of typing into tmux")
    func sendEnqueues() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "hello there")

        let inbox = Inbox(path: env.base + "/inbox.json")
        #expect(await inbox.peek(task.id).map(\.text) == ["hello there"])
    }

    @Test("send rejects a message over the inbox cap and enqueues nothing")
    func rejectsOverCap() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        let tooBig = String(repeating: "x", count: StopDrain.maxMessageChars + 1)

        await #expect(throws: OrchestraError.self) { try await env.svc.send(task.id, tooBig) }
        let inbox = Inbox(path: env.base + "/inbox.json")
        #expect(await inbox.peek(task.id).isEmpty)   // nothing queued — rejected at the boundary
    }

    @Test("send accepts a message exactly at the cap, delivered whole (never truncated)")
    func acceptsAtCap() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        let atLimit = String(repeating: "y", count: StopDrain.maxMessageChars)

        try await env.svc.send(task.id, atLimit)
        let payload = try #require(await env.svc.drainForStop(task.id))
        #expect(payload.count <= StopDrain.maxPayloadChars)
        #expect(payload.contains(atLimit))                 // whole message present
        #expect(payload.hasSuffix("[…truncated]") == false)  // not clipped
    }
}

@Suite("C1 · Stop-drain preserves the stop/waiting report")
struct NotifyPreservedTests {
    @Test("the Stop hook's stop event still parses to a waiting StatusReport and drives the card to waiting")
    func notifyStillWaiting() async throws {
        // 1. parse is byte-identical: the stop event → waiting (the old shared "notify" kind is now split
        //    into distinct notification/stop --event values; both still map to waiting).
        let report = ClaudeCodeAdapter().parse(.hooksPush(kind: "stop", payload: .object([:])))
        #expect(report?.snapshot?.run != nil)

        // 2. applied through the service, the card goes to .waiting — with a message still queued in the inbox
        //    (the drain is a separate step; the notify/waiting report is unaffected).
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "w", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "queued")
        try await env.svc.report(task.id, report!)
        let st = try await env.svc.status(task.id)
        #expect(st.task.waitReason != nil)                                          // notify/waiting preserved
        #expect(await Inbox(path: env.base + "/inbox.json").peek(task.id).count == 1) // drain not triggered
    }
}
