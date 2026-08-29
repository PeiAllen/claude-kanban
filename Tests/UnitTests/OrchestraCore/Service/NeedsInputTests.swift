import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Slice 3a — the `needs-input` DECLARATION: an agent that ends its turn blocked on a decision only the
/// card's owner can make says so, because an agent waiting in its own terminal is otherwise
/// indistinguishable from an idle one.
///
/// The verb is set/replace only; the daemon owns retirement, and everything below pins the same rule from
/// a different angle: a question is cleared ONLY by proof that it is moot — the next turn demonstrably
/// starting, or a session replacement that actually completed. Every case drives the real observation,
/// lifecycle, or hook seam rather than seeding phase directly, so the tests exercise the production
/// transition funnel.
@Suite("needs-input — declare a block, cleared only by proof of the next turn")
struct NeedsInputTests {

    private func card(_ svc: OrchestraService, _ id: UUID) async -> Task? { await svc.store.get(id) }

    private func liveCard(_ svc: OrchestraService, _ repo: String, _ branch: String = "feat-q") async throws -> Task {
        try await TestEnv.spawnAndAwaitLive(
            svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
    }

    // MARK: - the verb

    @Test("needs-input sets, replaces, and normalizes; it never clears")
    func setAndReplace() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))

        _ = try await env.svc.needsInput(ref: t.shortId, question: "  Ship to main or wait for PR 4?  ")
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "Ship to main or wait for PR 4?")

        // Replace, not append — one open question per card.
        _ = try await env.svc.needsInput(ref: t.shortId, question: "Squash or keep\nthe history?")
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "Squash or keep the history?")   // newlines flattened
    }

    @Test("an empty question is rejected — there is no clear form")
    func emptyRejected() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "real question")

        await #expect { _ = try await env.svc.needsInput(ref: t.shortId, question: "   ") } throws: { error in
            guard case OrchestraError.invalidParams = error else { return false }
            return true
        }
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "real question")   // the prior declaration stands
    }

    @Test("an over-long question is capped, not rejected")
    func questionCapped() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: String(repeating: "q", count: 400))
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text.count == CardNaming.maxQuestionChars)
    }

    @Test("status carries the declaration to clients")
    func statusCarriesIt() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        #expect(try await env.svc.status(t.id).task.pendingQuestion?.text == "which base?")
    }

    // MARK: - what does NOT clear it

    @Test("ending the turn ARMS it — an idle card keeps its question")
    func survivesTurnEnd() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [.init(sessionEpoch: epoch, turnID: "old-turn", kind: .turnStarted)]
        )
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [.init(sessionEpoch: epoch, turnID: "old-turn", kind: .turnCompleted())]
        )

        #expect(await card(env.svc, t.id)?.phase == Phase.live(.waiting))
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")   // armed, waiting on the human
    }

    @Test("a permission approval resumes the SAME turn and must not clear it")
    func permissionResumeDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")   // declared mid-turn
        await env.svc.testSetHumanNeed(t.id, .permission)
        await env.svc.testSetHumanNeed(t.id, nil)

        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    @Test("a relaunch INTENT does not clear it — only a landing does")
    func relaunchIntentDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        _ = try await env.svc.resume(t.id)   // persists `.relaunching` before any launch runs
        #expect(await card(env.svc, t.id)?.phase.kind == .relaunching)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")

        // …and a bring-up that FAILS leaves the question standing: the agent never saw it, and a dead card
        // is where the human needs the question most.
        _ = await env.svc.transition(t.id, to: .dead(.resumeFailed), expecting: .relaunching)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    @Test("a stale session's rollover cannot erase the CURRENT generation's question")
    func staleRolloverDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        // A rollover stamped with a generation that is provably not the card's — the dying predecessor.
        try await env.svc.report(t.id, StatusReport(sessionId: "late-old-session"),
                                 observedEpoch: epoch + 7)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    @Test("legacy rollout status cannot clear a question")
    func legacyRolloutStatusDoesNotClear() async throws {
        let env = TestEnv.make(capabilities: .fileTailStub)
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch

        await env.svc.testCompleteTurn(t.id)
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        try await env.svc.report(
            t.id,
            StatusReport(seq: 2_000_000_000_000, desc: "legacy rollout activity"),
            observedEpoch: epoch
        )

        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
        #expect(await card(env.svc, t.id)?.turnStatus == .waiting())
    }

    @Test("a repeated running reconciliation is not a new turn")
    func midTurnRunningReconciliationDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "mid-turn question?")
        await env.svc.testSetTurnStatus(t.id, .running)

        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "mid-turn question?")
    }

    // MARK: - what DOES clear it

    @Test("the next identified turn starting clears it")
    func turnStartClears() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        await env.svc.testCompleteTurn(t.id)
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [.init(sessionEpoch: epoch, turnID: "next-turn", kind: .turnStarted)]
        )

        #expect(await card(env.svc, t.id)?.pendingQuestion == nil)
    }

    @Test("an identified next turn clears the question even when status is already running")
    func distinctRunningTurnClears() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [.init(sessionEpoch: epoch, turnID: "next-turn", kind: .turnStarted)]
        )

        #expect(await card(env.svc, t.id)?.pendingQuestion == nil)
    }

    @Test("a Stop-drain delivery does not clear the declared question")
    func stopDrainDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        try await env.svc.send(t.id, "the answer is main")

        _ = await env.svc.handleHook(
            t.shortId, event: .stop, report: nil, source: nil,
            observedEpoch: epoch, stopHookActive: false
        )

        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    /// A Stop-drain continuation is delivery evidence, not a provider-observed turn start. It must not
    /// retire a question until a current provider turn identity proves that the new turn actually started.
    @Test("a delivery continuation without a provider turn start does not clear it")
    func deliveryContinuationDoesNotClear() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        await env.svc.testCompleteTurn(t.id)

        // Declared at the end of turn N — the agent asked, and went idle.
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        try await env.svc.send(t.id, "the answer is: base it on main")
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch

        // The Stop hands the answer back as a continuation, but no provider turn identity has arrived.
        let handed = await env.svc.handleHook(t.shortId, event: .stop, report: nil, source: nil,
                                              observedEpoch: epoch, stopHookActive: false)
        #expect(handed?.continuation?.contains("base it on main") == true)
        #expect(await card(env.svc, t.id)?.phase != Phase.live(.running))
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    /// The regression that made the first version of this seam wrong. The clear used to hang off
    /// `confirmDelivery`, and a stop-drain batch is confirmed on the Stop that ENDS the continuation turn
    /// (both agents set `stop_hook_active` there, `HookRPC.stopHookActive`) — which is exactly when an
    /// agent that has run out of road declares its question. The declaration was erased a beat after it
    /// was made, on both backends, and the card went idle with nothing to show the human.
    @Test("a question declared DURING a continuation turn survives that turn's Stop")
    func declaredDuringContinuationSurvives() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        await env.svc.testCompleteTurn(t.id)
        try await env.svc.send(t.id, "here is the context you asked for")
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch

        // Stop #1 hands the message back as a continuation — turn N+1 begins.
        _ = await env.svc.handleHook(t.shortId, event: .stop, report: nil, source: nil,
                                     observedEpoch: epoch, stopHookActive: false)

        // The agent works through turn N+1, gets blocked, and declares at the END of it.
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        // Stop #2 ends the continuation: `stopHookActive` is true, so it CONFIRMS the batch turn N+1 ran.
        // Nothing new is queued, so no fresh continuation is handed back — no turn is starting, and the
        // question must still be there for the human to see on the idle card.
        _ = await env.svc.handleHook(t.shortId, event: .stop, report: nil, source: nil,
                                     observedEpoch: epoch, stopHookActive: true)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    /// The delivery continuation cannot retire Q1 without a provider turn start. A later declaration still
    /// replaces Q1, and the Stop that closes the same continuation must not touch Q2.
    @Test("Q1 → delivery → Q2 → Stop: delivery preserves Q1 and Stop preserves Q2")
    func reDeclareCycleKeepsTheNewQuestion() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        await env.svc.testCompleteTurn(t.id)

        _ = try await env.svc.needsInput(ref: t.shortId, question: "Q1: which base?")
        try await env.svc.send(t.id, "answer: base it on main")
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch

        // The delivery claim has no provider turn identity, so Q1 remains open.
        _ = await env.svc.handleHook(t.shortId, event: .stop, report: nil, source: nil,
                                     observedEpoch: epoch, stopHookActive: false)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "Q1: which base?")

        // Working through the answer raises a NEW block, declared before that turn ends.
        _ = try await env.svc.needsInput(ref: t.shortId, question: "Q2: squash or keep history?")

        // The Stop closing that turn confirms Q1's delivery. It must not touch Q2.
        _ = await env.svc.handleHook(t.shortId, event: .stop, report: nil, source: nil,
                                     observedEpoch: epoch, stopHookActive: true)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "Q2: squash or keep history?")
    }

    @Test("a same-session relaunch preserves it")
    func sameSessionRelaunchPreserves() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")
        _ = try await env.svc.resume(t.id)

        // This is a resumed provider session, not a completed replacement.
        _ = await env.svc.transition(t.id, to: .live(.waiting),
                                     observedEpoch: try #require(await card(env.svc, t.id)).sessionEpoch,
                                     expecting: .relaunching)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    @Test("/clear without a replacement session ID preserves it")
    func sessionClearPreserves() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"), observedEpoch: epoch)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }

    @Test("a current-generation session rollover clears it")
    func rolloverClears() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        try await env.svc.report(t.id, StatusReport(sessionId: "fresh-session"), observedEpoch: epoch)
        #expect(await card(env.svc, t.id)?.pendingQuestion == nil)
    }
}
