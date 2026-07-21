import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B5a · the `send` verb: convergence kind + a required client-minted message id (dedup-first over
/// pending ∪ the confirmed-ids ring), the `{messageId, card}` return, and the editor stuck-reset seam
/// (a stuck card whose message a human edits/removes re-arms — scoped to the message's TRUE owner).
@Suite("B5a · send verb + editor stuck-reset")
struct SendVerbTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    private func liveCard(_ env: Env, branch: String = "b") async throws -> Task {
        try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: branch))
    }

    /// A card that is delivery-stuck (flag set + retry budget spent) with one queued message. Sets the
    /// stuck state directly — these tests exercise the RE-ARM, not the flip (that is B4's suite).
    private func stuckCard(_ env: Env, branch: String, text: String = "stuck-msg") async throws -> (card: Task, mid: UUID) {
        let card = try await liveCard(env, branch: branch)
        try await env.svc.inbox.enqueue(card.id, text)
        let mid = try #require(await env.svc.inboxPeek(card.id).first).id
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = Date() }
        for _ in 0..<5 { await env.svc.chargeDeliveryAttempt(card.id) }
        return (card, mid)
    }

    // MARK: return shape + required id

    @Test("send returns the message id and a card snapshot")
    func sendReturnsMessageIdAndCard() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let mid = UUID()
        let result = try await env.svc.send(card.id, "hi", messageId: mid)
        #expect(result.messageId == mid)
        #expect(result.card.id == card.id)
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["hi"])
    }

    // Seam stamp-if-absent (04-tests §79) is NOT unit-tested at the CLI/MCP-bridge/BoardStore seams: the
    // CLI (`orchestra`) and bridge (`orchestra-mcp`) are executable targets not importable by tests, and
    // BoardStore's `ControlClient` has no param-recording fake (un-started → `call` throws), so no seam can
    // capture the outgoing `id`. The enforceable guarantee is daemon-side and lives here — `sendRequiresId`
    // proves the boundary rejects a missing id — while the F-tier isolated-stack smoke exercises the real
    // CLI/bridge send end-to-end. The three seams mint a UUID when `id` is nil (trivial, correct by
    // inspection, mirroring spawn's stamp).
    @Test("the registry rejects a send with no message id and enqueues nothing")
    func sendRequiresId() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let send = try #require(CommandRegistry().command("send"))
        await #expect(throws: OrchestraError.self) {
            _ = try await send.run(env.svc, .object(["ref": .string(card.ref()), "message": .string("hi")]), .mcp)
        }
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)   // never reached the handler's enqueue
    }

    @Test("the registry send returns the stamped message id in its result")
    func registrySendReturnsId() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let mid = UUID()
        let send = try #require(CommandRegistry().command("send"))
        let out = try await send.run(env.svc,
            .object(["ref": .string(card.ref()), "message": .string("hi"), "id": .string(mid.uuidString)]), .mcp)
        #expect(out["messageId"]?.stringValue == mid.uuidString)
    }

    // MARK: dedup-first (idempotency)

    @Test("a retry with a still-pending id is a no-op — no second row, no overwrite")
    func sendDedupPendingNoOp() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let mid = UUID()
        try await env.svc.send(card.id, "first", messageId: mid)
        let r2 = try await env.svc.send(card.id, "second-ignored", messageId: mid)
        #expect(r2.messageId == mid)
        let msgs = try await env.svc.inboxPeek(card.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text == "first")   // the replay neither appended nor rewrote
    }

    @Test("a retry with an id already in the confirmed-ids ring is a no-op (delivered + removed)")
    func sendDedupConfirmedRingNoOp() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let mid = UUID()
        try await env.svc.inbox.enqueueIfUnknown(card.id, "delivered", id: mid)
        // Deliver it: claim → confirm records the id in the ring AND removes the row.
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) }, now: Date()))
        #expect(try await env.svc.inbox.confirm(token: batch.token))
        #expect(await env.svc.inbox.wasConfirmed(mid))

        let r = try await env.svc.send(card.id, "lost-response retry", messageId: mid)
        #expect(r.messageId == mid)
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)   // ring dedup: not re-delivered
    }

    @Test("a dedup replay mutates NO delivery state and fires no wake (dedup runs FIRST)")
    func replayLeavesDeliveryStateAndFiresNoWake() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env, branch: "b")
        // Build a stuck, RESUMABLE, DEAD card — a state where a wrongful wake is OBSERVABLE: `deliverable`
        // is true for a non-archived `.dead` card and `wake` is AWAITED, so a cold wake relaunches it
        // (`.dead → .relaunching` + epoch bump, exactly as `armRevivesDeadResumable` proves). A `.running`
        // card would make `wake` a no-op, so "nothing changed" could NOT distinguish a dedup-return from a
        // wake that merely found no route (impl-review DENY). A correct dedup return leaves ALL of
        // phase / epoch / stuck / budget / queue untouched.
        let mid = UUID()
        try await env.svc.inbox.enqueueIfUnknown(card.id, "stuck-msg", id: mid)
        env.adapter.writeTranscript(for: card.agentSessionId!)               // resumable ⇒ a wake WOULD relaunch
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = Date() }
        for _ in 0..<5 { await env.svc.chargeDeliveryAttempt(card.id) }
        let before = try #require(await env.svc.store.get(card.id))

        // `mid` is already pending ⇒ this send is a dedup no-op; it must return BEFORE re-arm AND wake.
        let r = try await env.svc.send(card.id, "replayed", messageId: mid)

        let after = try #require(await env.svc.store.get(card.id))
        #expect(r.messageId == mid)
        #expect(after.phase.kind == .dead)                                   // NO wake (a cold wake → .relaunching)
        #expect(after.sessionEpoch == before.sessionEpoch)                   // NO wake (a cold wake bumps the epoch)
        #expect(after.deliveryStuckSince != nil)                             // NO re-arm (stuck kept)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 5)     // NO re-arm (budget kept)
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["stuck-msg"])   // not re-appended
    }

    @Test("two concurrent same-id sends append exactly one row (atomic dedup, no reentrancy race)")
    func concurrentSameIdSendsSingleRow() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let mid = UUID()
        async let a = env.svc.send(card.id, "A", messageId: mid)
        async let b = env.svc.send(card.id, "B", messageId: mid)
        _ = try await (a, b)
        #expect(try await env.svc.inboxPeek(card.id).count == 1)   // one row despite two racing sends
    }

    // MARK: re-arm + rev exception

    @Test("a fresh send to a stuck card clears the stuck flag and resets the retry budget")
    func sendClearsStuckAndResetsBudget() async throws {
        let env = TestEnv.make()
        let (card, _) = try await stuckCard(env, branch: "b")
        // Park the card `.running` so the opportunistic wake no-ops (this test isolates the re-arm, not
        // delivery) — a running card is not deliverable and wake returns before charging anything.
        try await env.svc.report(card.id, StatusReport(run: .running))

        try await env.svc.send(card.id, "try again", messageId: UUID())

        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 0)
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["stuck-msg", "try again"])
    }

    @Test("send emits no task-upsert on a running, non-stuck card (the inbox rev exception)")
    func sendEmitsNoTaskEvent() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        try await env.svc.report(card.id, StatusReport(run: .running))   // wake will no-op; card is not stuck
        await yieldBriefly()
        let baseline = await collector.upserts.count

        try await env.svc.send(card.id, "queued", messageId: UUID())
        await yieldBriefly()

        #expect(await collector.upserts.count == baseline)              // the send bumped no board rev
        #expect(try await env.svc.inboxPeek(card.id).count == 1)        // yet the message IS durable
    }

    // MARK: editor stuck-reset seam (B5a-owed)

    @Test("editing a stuck card's message re-arms it (clear stuck + reset budget)")
    func editStuckCardReArms() async throws {
        let env = TestEnv.make()
        let (card, mid) = try await stuckCard(env, branch: "b")
        try await env.svc.inboxUpdate(card.id, messageId: mid, text: "fixed")
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 0)
    }

    @Test("removing a stuck card's message re-arms it")
    func removeStuckCardReArms() async throws {
        let env = TestEnv.make()
        let (card, mid) = try await stuckCard(env, branch: "b")
        try await env.svc.inboxRemove(card.id, messageId: mid)
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 0)
    }

    @Test("editing a HEALTHY (non-stuck) card leaves its retry budget untouched")
    func editHealthyCardLeavesBudget() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        try await env.svc.inbox.enqueue(card.id, "m")
        let mid = try #require(await env.svc.inboxPeek(card.id).first).id
        for _ in 0..<3 { await env.svc.chargeDeliveryAttempt(card.id) }   // accruing, NOT yet stuck

        try await env.svc.inboxUpdate(card.id, messageId: mid, text: "edited")

        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 3)   // gate holds — no reset
    }

    @Test("editing a nonexistent message id throws and leaves the stuck state unchanged")
    func editUnknownIdLeavesStuckUnchanged() async throws {
        let env = TestEnv.make()
        let (card, _) = try await stuckCard(env, branch: "b")
        await #expect(throws: OrchestraError.self) {
            try await env.svc.inboxUpdate(card.id, messageId: UUID(), text: "x")
        }
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 5)
    }

    @Test("removing a nonexistent message id is a no-op and leaves the stuck state unchanged")
    func removeUnknownIdLeavesStuckUnchanged() async throws {
        let env = TestEnv.make()
        let (card, _) = try await stuckCard(env, branch: "b")
        try await env.svc.inboxRemove(card.id, messageId: UUID())     // global no-op → no owner → no re-arm
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 5)
    }

    /// Codex MAJOR: the editor verbs are keyed by (ref, message-id) but `Inbox.remove`/`update` mutate
    /// GLOBALLY by message id. Re-arming the passed ref would unstick the WRONG card. The fix re-arms the
    /// removed message's true owner — so a cross-card id leaves the ref card wedged and unsticks the owner.
    @Test("a cross-card message id re-arms the message's true owner, not the passed ref")
    func removeCrossCardIdReArmsOwnerNotRef() async throws {
        let env = TestEnv.make()
        let (cardA, _) = try await stuckCard(env, branch: "a", text: "A-msg")
        let (cardB, midB) = try await stuckCard(env, branch: "b", text: "B-msg")

        // Pass A's ref but B's message id — the mutation hits B's message (global by id).
        try await env.svc.inboxRemove(cardA.id, messageId: midB)

        #expect(try #require(await env.svc.store.get(cardA.id)).deliveryStuckSince != nil)   // ref untouched
        #expect(await env.svc.deliveryAttemptCountForTest(cardA.id) == 5)
        #expect(try #require(await env.svc.store.get(cardB.id)).deliveryStuckSince == nil)   // owner re-armed
        #expect(await env.svc.deliveryAttemptCountForTest(cardB.id) == 0)
    }

    @Test("reordering a stuck card does NOT re-arm it (reorder preserves leases)")
    func reorderStuckCardDoesNotReArm() async throws {
        let env = TestEnv.make()
        let card = try await liveCard(env)
        try await env.svc.inbox.enqueue(card.id, "one")
        try await env.svc.inbox.enqueue(card.id, "two")
        let ids = try await env.svc.inboxPeek(card.id).map(\.id)
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = Date() }
        for _ in 0..<5 { await env.svc.chargeDeliveryAttempt(card.id) }

        try await env.svc.inboxReorder(card.id, orderedIds: [ids[1], ids[0]])

        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)   // unchanged
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 5)
    }
}
