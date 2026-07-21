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

    @Test("claim, release, and watermarking preserve durable source provenance")
    func leaseLifecyclePreservesSource() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        let source = InboxMessageSource.card(id: UUID(), title: "child-review")
        try await inbox.enqueue(InboxMessage(cardId: card, text: "review complete", source: source))

        let first = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1,
                                                       budget: 10_000, render: Self.fit, now: Self.t0))
        #expect(await inbox.peek(card).first?.source == source)
        try await inbox.release(token: first.token)
        #expect(await inbox.peek(card).first?.source == source)

        _ = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 1,
                                                budget: 10_000, render: Self.fit, now: Self.t0))
        try await inbox.setTailWatermark(cardId: card, epoch: 1, watermark: 42, path: "/tmp/rollout.jsonl")
        let row = try #require(await inbox.peek(card).first)
        #expect(row.source == source)
        #expect(row.lease?.tailWatermark == 42)
    }

    @Test("isLeaseLive: live only while present AND unexpired — epoch-agnostic (B4 arm predicate)")
    func isLeaseLiveTokenScoped() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path, leaseTimeout: 60); let card = UUID()
        try await inbox.enqueue(card, "m")
        let batch = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 1,
                                                       budget: 4096, render: Self.fit, now: Self.t0))

        #expect(await inbox.isLeaseLive(token: batch.token, now: Self.t0))
        // A STALE-EPOCH lease is still live while unexpired — epoch-agnostic by design (the arm must
        // charge it only once EXPIRED, not merely because its generation moved).
        #expect(await inbox.isLeaseLive(token: batch.token, now: Self.t0.addingTimeInterval(59)))
        // …and dead once expired, which is what lets the arm charge it.
        #expect(await inbox.isLeaseLive(token: batch.token, now: Self.t0.addingTimeInterval(61)) == false)
        #expect(await inbox.isLeaseLive(token: UUID(), now: Self.t0) == false)   // unknown token
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
        // NOT a substring check on "a" vs "b": the provenance header itself contains the letter "a"
        // ("Orchestra", "message", "instructions", "agent", "act", …), so a plain `!contains("a")` can
        // never pass. A "\n\na" slot check is ALSO non-discriminating: in the buggy case (fresh
        // cross-route lease wrongly claimable) the pool is [a,b] and `fit` renders the NUMBERED
        // multi-message form (`header + "\n\n[1/2] a\n\n[2/2] b"`), where every "\n\n" is followed by
        // "[", never bare "a" — so that check would still pass even on the bug. Assert on the leased SET
        // instead, which is unambiguous across both render forms.
        #expect(second.ids.count == 1)                       // buggy case would lease BOTH → 2
        let aRow = try #require(await inbox.peek(card).first(where: { $0.text == "a" }))
        #expect(aRow.lease?.token == first.token)            // a's original stopDrain lease untouched, not re-stolen
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

@Suite("B1 · Inbox confirm / release / ring")
struct InboxConfirmTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }
    static let t0 = Date(timeIntervalSince1970: 10_000)
    // @Sendable is REQUIRED: Package.swift is tools-6.0 with no language-mode override, so a static let
    // of a bare function type is "not concurrency-safe" (#MutableGlobalVariable) and won't compile.
    static let fit: @Sendable ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { StopDrain.fit($0, budget: $1) }

    @Test("confirm removes the batch and records its ids in the ring — one atomic write")
    func confirmRemovesAndRings() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        let b = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))
        try await inbox.confirm(token: b.token)
        #expect(await inbox.peek(card).isEmpty)
        // Crash-equivalence: a fresh actor reads BOTH halves off disk (removal + ring), never one.
        let reborn = Inbox(path: path)
        #expect(await reborn.peek(card).isEmpty)
        #expect(await reborn.wasConfirmed(b.ids[0]))
    }

    @Test("a stale or unknown token confirms/releases nothing — idempotent no-ops")
    func staleTokenNoops() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        let stale = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                       render: Self.fit, now: Self.t0))
        // The batch is re-claimed (expiry) — the old token is now dead.
        let fresh = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                       render: Self.fit, now: Self.t0.addingTimeInterval(61)))
        try await inbox.confirm(token: stale.token)          // a late ack from the superseded attempt…
        #expect(await inbox.peek(card).count == 1)           // …must NOT remove the re-claimed message
        try await inbox.release(token: stale.token)
        #expect(await inbox.peek(card).first?.lease?.token == fresh.token)   // fresh lease intact
        #expect(try await inbox.confirm(token: UUID()) == false)     // unknown token → no-op outcome
        #expect(await inbox.peek(card).count == 1)
        #expect(try await inbox.confirm(token: fresh.token) == true) // a real removal
        #expect(try await inbox.confirm(token: fresh.token) == false)  // idempotent second confirm → no-op
        #expect(await inbox.peek(card).isEmpty)
    }

    @Test("release returns the batch to pending; releaseAll clears every lease for a card")
    func releaseSemantics() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID(); let other = UUID()
        try await inbox.enqueue(card, "m1"); try await inbox.enqueue(other, "o1")
        let b = try #require(try await inbox.claim(card, route: .channelPush, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))
        try await inbox.release(token: b.token)
        #expect(await inbox.peek(card).first?.lease == nil)
        #expect(await inbox.peek(card).count == 1)                       // released, NOT removed
        _ = try await inbox.claim(card, route: .channelPush, epoch: 1, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        _ = try await inbox.claim(other, route: .channelPush, epoch: 1, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        try await inbox.releaseAll(card)
        #expect(await inbox.peek(card).first?.lease == nil)
        #expect(await inbox.peek(other).first?.lease != nil)             // other card untouched
    }

    @Test("the confirmed-ids ring evicts FIFO at its cap")
    func ringBounded() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        var firstId: UUID?; var secondId: UUID?; var lastId: UUID?
        for i in 0...Inbox.confirmedRingCap {                            // cap + 1 confirms
            try await inbox.enqueue(card, "m\(i)")
            let b = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                       render: Self.fit, now: Self.t0))
            if firstId == nil { firstId = b.ids[0] } else if secondId == nil { secondId = b.ids[0] }
            lastId = b.ids[0]
            try await inbox.confirm(token: b.token)
        }
        let reborn = Inbox(path: path)
        #expect(await reborn.wasConfirmed(firstId!) == false)            // the ONE oldest evicted…
        #expect(await reborn.wasConfirmed(secondId!))                    // …and everything newer RETAINED —
        #expect(await reborn.wasConfirmed(lastId!))                      //    proves FIFO-of-256, not a clear
    }

    @Test("hasClaimable ignores a held same-epoch lease but sees expiry and stale epochs")
    func hasClaimableSemantics() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        #expect(await inbox.hasClaimable(card, epoch: 1, now: Self.t0) == false)   // empty
        try await inbox.enqueue(card, "m")
        #expect(await inbox.hasClaimable(card, epoch: 1, now: Self.t0))            // pending
        _ = try await inbox.claim(card, route: .relaunchSeed, epoch: 1, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        // A held same-epoch lease must NOT re-wake the card on the live edge.
        #expect(await inbox.hasClaimable(card, epoch: 1, now: Self.t0.addingTimeInterval(5)) == false)
        #expect(await inbox.hasClaimable(card, epoch: 1, now: Self.t0.addingTimeInterval(61)))  // expired
        #expect(await inbox.hasClaimable(card, epoch: 2, now: Self.t0.addingTimeInterval(5)))   // stale epoch
    }

    @Test("hasLiveLease sees an unexpired same-epoch lease; expired / stale-epoch / unleased → false")
    func hasLiveLeaseSemantics() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        #expect(await inbox.hasLiveLease(card, epoch: 1, now: Self.t0) == false)   // unleased → no live lease
        _ = try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        #expect(await inbox.hasLiveLease(card, epoch: 1, now: Self.t0.addingTimeInterval(5)))       // live
        #expect(await inbox.hasLiveLease(card, epoch: 1, now: Self.t0.addingTimeInterval(61)) == false)  // expired
        #expect(await inbox.hasLiveLease(card, epoch: 2, now: Self.t0.addingTimeInterval(5)) == false)   // other epoch
    }

    @Test("claim(blockIfLiveLease:) refuses a claim while an unexpired same-epoch lease is live — atomically")
    func claimBlockedByLiveLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        let big = String(repeating: "q", count: 6_000)     // two of these can't co-fit one 10k budget
        try await inbox.enqueue(card, "1-" + big)
        try await inbox.enqueue(card, "2-" + big)
        // A first claim leases message 1 (only one fits the budget) — a live lease.
        _ = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                               render: Self.fit, now: Self.t0))
        // The check + lease are ONE atomic actor call, so a second claim is REFUSED while that lease is live
        // — even though message 2 is claimable. Deterministic: no scheduler timing needed. This is the
        // invariant that stops two same-epoch stopDrain leases from coexisting (which would let a later
        // `.first` confirm remove the wrong batch); the concurrent-Stop test exercises the same path live.
        #expect(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000, render: Self.fit,
                                      now: Self.t0.addingTimeInterval(1), blockIfLiveLease: true) == nil)
        // WITHOUT the flag, that same second claim WOULD lease message 2 — proving the flag is what blocks.
        #expect((try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000, render: Self.fit,
                                       now: Self.t0.addingTimeInterval(1), blockIfLiveLease: false)) != nil)
    }

    @Test("setTailWatermark stamps the held relaunchSeed lease at that epoch, keeping its token")
    func setTailWatermarkStampsHeldRelaunchLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        let batch = try #require(try await inbox.claim(card, route: .relaunchSeed, epoch: 7, budget: 10_000,
                                                       render: Self.fit, now: Self.t0))
        try await inbox.setTailWatermark(cardId: card, epoch: 7, watermark: 4096, path: "/roll/a.jsonl")
        let lease = try #require(await inbox.peek(card).first?.lease)
        #expect(lease.token == batch.token)          // watermark update preserves the token
        #expect(lease.tailWatermark == 4096)
        #expect(lease.tailPath == "/roll/a.jsonl")
        #expect(lease.route == .relaunchSeed && lease.epoch == 7)
    }

    @Test("setTailWatermark is a no-op when there is no relaunchSeed lease at that epoch")
    func setTailWatermarkNoopWhenNoLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m")
        _ = try await inbox.claim(card, route: .relaunchSeed, epoch: 7, budget: 10_000,
                                  render: Self.fit, now: Self.t0)
        // Wrong epoch and a non-relaunchSeed lease both leave the watermark unset.
        try await inbox.setTailWatermark(cardId: card, epoch: 6, watermark: 1, path: "/x")
        #expect(await inbox.peek(card).first?.lease?.tailWatermark == nil)
        try await inbox.setTailWatermark(cardId: UUID(), epoch: 7, watermark: 1, path: "/x")  // other card
        #expect(await inbox.peek(card).first?.lease?.tailWatermark == nil)
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

    @Test("a non-STRING ring element (a number) is dropped — messages survive, no .bak")
    func nonStringRingElementDroppedNotBaked() async throws {
        let path = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".bak") }
        let card = UUID(); let goodId = UUID()
        let json = """
        {"confirmedIds":["\(goodId.uuidString)",5],"messages":[
          {"id":"\(UUID().uuidString)","cardId":"\(card.uuidString)","text":"pending","createdAt":"2020-01-01T00:00:00Z"}
        ]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["pending"])       // valid send NOT stranded
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
        #expect(await inbox.wasConfirmed(goodId))                        // the good tombstone kept
    }

    @Test("a non-ARRAY confirmedIds degrades to an empty ring — messages survive, no .bak")
    func nonArrayConfirmedIdsDegradesToEmptyRing() async throws {
        let path = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".bak") }
        let card = UUID()
        let json = """
        {"confirmedIds":5,"messages":[
          {"id":"\(UUID().uuidString)","cardId":"\(card.uuidString)","text":"pending","createdAt":"2020-01-01T00:00:00Z"}
        ]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        let inbox = Inbox(path: path)
        #expect(await inbox.peek(card).map(\.text) == ["pending"])       // valid send NOT stranded
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
        #expect(await inbox.wasConfirmed(UUID()) == false)              // empty ring
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

    @Test("enqueue preserves FIFO order per card; remove clears one card without touching another")
    func enqueueFifoAndRemove() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path)
        let a = UUID(); let b = UUID()
        try await inbox.enqueue(a, "a1")
        try await inbox.enqueue(b, "b1")
        try await inbox.enqueue(a, "a2")

        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])   // FIFO, per card
        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])   // peek is non-destructive
        for m in await inbox.peek(a) { try await inbox.remove(m.id) }
        #expect(await inbox.peek(a).isEmpty)                        // a cleared
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
        let source = InboxMessageSource.card(id: UUID(), title: "review-pass")
        do {
            let inbox = Inbox(path: path)
            try await inbox.enqueue(card, "before restart", source: source)
        }
        // Fresh instance simulates a daemon restart — must read the persisted queue.
        let reborn = Inbox(path: path)
        #expect(await reborn.peek(card).map(\.text) == ["before restart"])
        #expect(await reborn.peek(card).map(\.source) == [source])
    }

    @Test("enqueue without a source persists Orchestra provenance")
    func defaultEnqueuePersistsOrchestraSource() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        do {
            let inbox = Inbox(path: path)
            try await inbox.enqueue(card, "generated nudge")
        }

        let reborn = Inbox(path: path)
        #expect(await reborn.peek(card).first?.source == .orchestra)
    }

    @Test("legacy inbox message decodes without source and displays unavailable provenance")
    func legacySourceIsUnknown() throws {
        let original = InboxMessage(cardId: UUID(), text: "old", source: .human)
        var object = try #require(JSONSerialization.jsonObject(
            with: OrchestraJSON.pretty.encode(original)) as? [String: Any])
        object.removeValue(forKey: "source")
        let legacy = try OrchestraJSON.decoder.decode(
            InboxMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.source == nil)
        #expect(legacy.sourceLabel == "Unknown (queued before source tracking)")
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

    @Test("update replaces text only, preserving id, source, deduplication, and createdAt")
    func updateText() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(InboxMessage(
            cardId: c,
            text: "old",
            source: .card(id: UUID(), title: "review-pass"),
            dedupKey: "handoff-result"))
        let m = try #require(await inbox.peek(c).first)
        try await inbox.update(m.id, text: "new")
        let after = try #require(await inbox.peek(c).first)
        #expect(after.text == "new")
        #expect(after.id == m.id)
        #expect(after.source == m.source)
        #expect(after.dedupKey == m.dedupKey)
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
        let a1Source = InboxMessageSource.human
        let b1Source = InboxMessageSource.orchestra
        let a2Source = InboxMessageSource.card(id: UUID(), title: "review-pass")
        let a3Source = InboxMessageSource.card(id: UUID(), title: "test-pass")
        // array order: a1, b1, a2, a3
        try await inbox.enqueue(a, "a1", source: a1Source)
        try await inbox.enqueue(b, "b1", source: b1Source)
        try await inbox.enqueue(a, "a2", source: a2Source)
        try await inbox.enqueue(a, "a3", source: a3Source)
        let aIds = await inbox.peek(a).map(\.id)          // [a1, a2, a3]
        // new order for a: a3, a1, a2
        try await inbox.reorder(a, orderedIds: [aIds[2], aIds[0], aIds[1]])
        #expect(await inbox.peek(a).map(\.text) == ["a3", "a1", "a2"])
        #expect(await inbox.peek(a).map(\.source) == [a3Source, a1Source, a2Source])
        #expect(await inbox.peek(b).map(\.text) == ["b1"])  // b untouched
        #expect(await inbox.peek(b).map(\.source) == [b1Source])
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

@Suite("B1 · Inbox editor force-release")
struct InboxEditorLeaseTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }
    static let t0 = Date(timeIntervalSince1970: 10_000)
    // @Sendable is REQUIRED: Package.swift is tools-6.0 with no language-mode override, so a static let
    // of a bare function type is "not concurrency-safe" (#MutableGlobalVariable) and won't compile.
    static let fit: @Sendable ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { StopDrain.fit($0, budget: $1) }

    @Test("remove force-releases the whole in-flight batch — the human always wins")
    func removeForceReleasesLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m1"); try await inbox.enqueue(card, "m2")
        let b = try #require(try await inbox.claim(card, route: .channelPush, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))
        let victim = try #require(await inbox.peek(card).first)
        try await inbox.remove(victim.id)
        #expect(await inbox.peek(card).map(\.text) == ["m2"])
        #expect(await inbox.peek(card).first?.lease == nil)     // sibling released, not left in flight
        try await inbox.confirm(token: b.token)                 // the in-flight ack is now inert…
        #expect(await inbox.peek(card).count == 1)              // …so it cannot remove m2
    }

    @Test("update force-releases the WHOLE batch — a sibling can't be confirmed against stale text")
    func updateForceReleasesLease() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "typo"); try await inbox.enqueue(card, "keep")
        let b = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                   render: Self.fit, now: Self.t0))   // leases BOTH under one token
        let m1 = try #require(await inbox.peek(card).first)
        try await inbox.update(m1.id, text: "fixed")
        #expect(await inbox.peek(card).allSatisfy { $0.lease == nil })   // sibling released too
        try await inbox.confirm(token: b.token)                          // stale ack now inert
        #expect(await inbox.peek(card).map(\.text) == ["fixed", "keep"]) // sibling NOT removed
    }

    @Test("reorder permutes the full set INCLUDING leased rows, preserving their leases")
    func reorderPermutesFullSetIncludingLeased() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let card = UUID()
        try await inbox.enqueue(card, "m1"); try await inbox.enqueue(card, "m2")
        let b = try #require(try await inbox.claim(card, route: .stopDrain, epoch: 1, budget: 10_000,
                                                   render: { ms, bud in StopDrain.fit(Array(ms.prefix(1)), budget: bud) },
                                                   now: Self.t0))
        let ids = await inbox.peek(card).map(\.id)
        try await inbox.reorder(card, orderedIds: Array(ids.reversed()))   // reorder takes [UUID]
        #expect(await inbox.peek(card).map(\.text) == ["m2", "m1"])
        // Order is metadata for FUTURE renders — the live claim is unaffected.
        #expect(await inbox.peek(card).first(where: { $0.text == "m1" })?.lease?.token == b.token)
        try await inbox.confirm(token: b.token)
        #expect(await inbox.peek(card).map(\.text) == ["m2"])
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
        #expect(r!.hasPrefix("Message from the user (relayed to you via Orchestra):"))
        #expect(r!.hasSuffix("[…truncated]"))
    }

    @Test("uses the measured user-relayed header without queue or injection language")
    func operatorRelayedHeader() {
        let one = StopDrain.compose([msg("do X")])
        #expect(one?.hasPrefix("Message from the user (relayed to you via Orchestra):") == true)
        #expect(one?.contains("do X") == true)
        // Channel-neutral: no Stop-hook-specific wording leaks in (shared with the Codex seed path).
        #expect(one?.lowercased().contains("turn-end") == false)
        #expect(one?.lowercased().contains("hook") == false)
        #expect(one?.lowercased().contains("inbox") == false)
        #expect(one?.lowercased().contains("queued") == false)
        #expect(one?.lowercased().contains("act on") == false)
        let two = StopDrain.compose([msg("a"), msg("b")])
        #expect(two?.hasPrefix("Messages from the user (relayed to you via Orchestra):") == true)
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

    @Test("model delivery uses operator-relayed framing while source remains UI metadata")
    func hidesSourcesFromDelivery() {
        let card = InboxMessage(cardId: UUID(), text: "review this",
                                source: .card(id: UUID(), title: "review-pass"))
        let human = InboxMessage(cardId: UUID(), text: "please prioritize", source: .human)
        let batch = StopDrain.compose([human, card])
        #expect(card.sourceLabel.hasPrefix("Card review-pass (") == true)
        #expect(batch?.contains("[1/2] please prioritize") == true)
        #expect(batch?.contains("[2/2] review this") == true)
        #expect(batch?.contains("review-pass") == false)
        #expect(batch?.contains("From Card") == false)
        #expect(batch?.contains("From Human") == false)
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

// The C1 `drainForStop` loop-guard suite retired with the method: `payloadForStop` replaces it
// (claim-then-confirm, epoch-fenced, so it needs a real store card — the old bare-UUID tests can't
// satisfy the fence). Its loop-guard / empty-reset / drain-to-fit coverage moved to
// `Service/PayloadForStopTests.swift`.

@Suite("C1 · send routes through the inbox")
struct InboxRoutingTests {
    @Test("send enqueues a durable message instead of typing into tmux")
    func sendEnqueues() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "hello there")

        let inbox = Inbox(path: env.base + "/inbox.json")
        #expect(await inbox.peek(task.id).map(\.text) == ["hello there"])
        #expect(await inbox.peek(task.id).first?.source == .human)
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
        let epoch = try #require(await env.svc.store.get(task.id)).sessionEpoch
        let atLimit = String(repeating: "y", count: StopDrain.maxMessageChars)

        try await env.svc.send(task.id, atLimit)
        let payload = try #require(await env.svc.payloadForStop(task.id, observedEpoch: epoch, stopHookActive: false))
        #expect(payload.count <= StopDrain.maxPayloadChars)
        #expect(payload.contains(atLimit))                 // whole message present
        #expect(payload.hasSuffix("[…truncated]") == false)  // not clipped
    }

    @Test("a long card title remains UI-only and does not shrink or leak into delivery")
    func longCardSourceStaysOutOfDeliveryEnvelope() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        let epoch = try #require(await env.svc.store.get(task.id)).sessionEpoch
        let messageId = UUID()
        let source = InboxMessageSource.card(
            id: UUID(),
            title: String(repeating: "x", count: StopDrain.maxPayloadChars))

        try await env.svc.send(task.id, "please take this next", messageId: messageId, sender: source)
        let queued = try #require(try await env.svc.inboxPeek(task.id).first)
        #expect(queued.id == messageId)
        #expect(queued.source == source)
        let payload = try #require(await env.svc.payloadForStop(task.id, observedEpoch: epoch, stopHookActive: false))
        #expect(payload.contains("please take this next"))
        #expect(payload.contains(source.label) == false)
    }

    @Test("send accepts a card source message at the shared delivery cap")
    func acceptsCardSourceAtCap() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))
        let epoch = try #require(await env.svc.store.get(task.id)).sessionEpoch
        let source = InboxMessageSource.card(id: UUID(), title: "child-review")
        let atLimit = String(repeating: "y", count: StopDrain.maxMessageChars)

        try await env.svc.send(task.id, atLimit, sender: source)
        let payload = try #require(await env.svc.payloadForStop(task.id, observedEpoch: epoch, stopHookActive: false))
        #expect(payload.count == StopDrain.maxPayloadChars)
        #expect(payload.contains(atLimit))
        #expect(payload.contains(source.label) == false)
        #expect(payload.hasSuffix("[…truncated]") == false)
    }
}

/// B5a · the Inbox primitives `send` and the editor now depend on: an ATOMIC dedup-append keyed on the
/// client message id (so a reentrant double-send can't double-append), and owner-returning editor
/// mutations (so the service re-arms the message's true owner, not the caller's ref).
@Suite("B5a · Inbox send idempotency + editor owner")
struct InboxSendIdempotencyTests {
    private func freshInbox() -> (inbox: Inbox, path: String, cardA: UUID, cardB: UUID) {
        let path = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json"
        return (Inbox(path: path), path, UUID(), UUID())
    }

    @Test("enqueueIfUnknown appends once, then dedups a still-pending id")
    func enqueueIfUnknownPendingDedups() async throws {
        let (inbox, path, card, _) = freshInbox()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = UUID()
        #expect(try await inbox.enqueueIfUnknown(card, "first", id: id) == true)
        #expect(try await inbox.enqueueIfUnknown(card, "again", id: id) == false)   // pending → dedup
        #expect(await inbox.peek(card).map(\.text) == ["first"])                    // one row, unrewritten
    }

    @Test("enqueueIfUnknown preserves source beside its client id through lease and editor rebuilds")
    func enqueueIfUnknownPreservesSourceThroughRebuilds() async throws {
        let (inbox, path, card, _) = freshInbox()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = UUID()
        let source = InboxMessageSource.card(id: UUID(), title: "child-review")
        #expect(try await inbox.enqueueIfUnknown(card, "review complete", id: id, source: source))

        let stopBatch = try #require(try await inbox.claim(
            card, route: .stopDrain, epoch: 1, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) }, now: Date()))
        try await inbox.release(token: stopBatch.token)
        #expect(await inbox.peek(card).first?.source == source)

        _ = try #require(try await inbox.claim(
            card, route: .relaunchSeed, epoch: 1, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) }, now: Date()))
        try await inbox.setTailWatermark(cardId: card, epoch: 1, watermark: 42, path: "/tmp/rollout.jsonl")
        #expect(try await inbox.update(id, text: "edited") == card)

        let row = try #require(await inbox.peek(card).first)
        #expect(row.id == id)
        #expect(row.source == source)
        #expect(row.lease == nil)
    }

    @Test("enqueueIfUnknown dedups an id already tombstoned in the confirmed-ids ring")
    func enqueueIfUnknownRingDedups() async throws {
        let (inbox, path, card, _) = freshInbox()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = UUID()
        #expect(try await inbox.enqueueIfUnknown(card, "delivered", id: id) == true)
        let batch = try #require(try await inbox.claim(
            card, route: .channelPush, epoch: 1, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) }, now: Date()))
        #expect(try await inbox.confirm(token: batch.token))       // records id in the ring, removes the row
        #expect(await inbox.wasConfirmed(id))

        #expect(try await inbox.enqueueIfUnknown(card, "retry", id: id) == false)   // ring → dedup
        #expect(await inbox.peek(card).isEmpty)                    // not re-appended
    }

    /// BLOCKER (final-review): `enqueueIfUnknown` must be TRANSACTIONAL — a persist failure must NOT
    /// leave the id published in memory, or the contracted retry would dedup to `false` (and `send` report
    /// success) with the message never on disk → an acknowledged send lost on the next daemon death. This
    /// reproduces the failure across a daemon reconstruction: persist throws (the inbox path's parent is a
    /// regular file), the FIRST call throws and rolls back; after the path is unblocked the retry
    /// RE-ENQUEUES and the message survives a fresh-`Inbox` reload. Pre-fix the retry returns `false` and
    /// the reload is empty.
    @Test("a persist throw rolls back enqueueIfUnknown so the same-id retry re-enqueues and survives a reload")
    func enqueueIfUnknownPersistThrowRollsBack() async throws {
        let dir = NSTemporaryDirectory() + "inbox-blocker-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let wall = dir + "/wall"                                  // a FILE where persist needs a DIRECTORY
        FileManager.default.createFile(atPath: wall, contents: Data())
        let inboxPath = wall + "/inbox.json"                     // parent `wall` is a file → persist() throws
        let card = UUID(), id = UUID()

        let first = Inbox(path: inboxPath)
        await #expect(throws: (any Error).self) { _ = try await first.enqueueIfUnknown(card, "hi", id: id) }
        #expect(await first.peek(card).isEmpty)                  // rolled back — NOT left published in memory

        // Unblock the path (a transient disk condition clears) and RETRY the same id on a fresh inbox.
        try FileManager.default.removeItem(atPath: wall)
        let retry = Inbox(path: inboxPath)
        #expect(try await retry.enqueueIfUnknown(card, "hi", id: id) == true)   // re-enqueues (would be false unfixed)

        // Reload from disk (a daemon reconstruction): the acknowledged send is durable, never lost.
        let reloaded = Inbox(path: inboxPath)
        #expect(await reloaded.peek(card).map(\.id) == [id])
    }

    /// The `enqueue`/dedupKey sibling of the BLOCKER: same add-then-dedup-suppress shape, so a persist
    /// throw must roll the row back too, else the deduped redrive would silently drop it.
    @Test("a persist throw rolls back a dedupKey enqueue so the row isn't left suppressing its own redrive")
    func enqueueDedupKeyPersistThrowRollsBack() async throws {
        let dir = NSTemporaryDirectory() + "inbox-blocker-dk-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let wall = dir + "/wall"
        FileManager.default.createFile(atPath: wall, contents: Data())
        let inboxPath = wall + "/inbox.json"
        let card = UUID()

        let first = Inbox(path: inboxPath)
        await #expect(throws: (any Error).self) { try await first.enqueue(card, "x", dedupKey: "k") }
        #expect(await first.peek(card).isEmpty)                  // rolled back

        try FileManager.default.removeItem(atPath: wall)
        let retry = Inbox(path: inboxPath)
        try await retry.enqueue(card, "x", dedupKey: "k")        // the dedupKey no longer suppresses a phantom row
        #expect(await Inbox(path: inboxPath).peek(card).map(\.text) == ["x"])   // durable
    }

    @Test("remove returns the message's owner cardId, or nil when the id is absent")
    func removeReturnsOwnerNilWhenAbsent() async throws {
        let (inbox, path, card, _) = freshInbox()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = UUID()
        try await inbox.enqueueIfUnknown(card, "m", id: id)
        #expect(try await inbox.remove(UUID()) == nil)             // absent → nil owner
        #expect(try await inbox.remove(id) == card)               // present → the owner
        #expect(await inbox.peek(card).isEmpty)
    }

    @Test("update returns the edited message's owner; an absent id throws")
    func updateReturnsOwner() async throws {
        let (inbox, path, card, _) = freshInbox()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = UUID()
        try await inbox.enqueueIfUnknown(card, "m", id: id)
        #expect(try await inbox.update(id, text: "edited") == card)
        await #expect(throws: OrchestraError.self) { _ = try await inbox.update(UUID(), text: "x") }
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
