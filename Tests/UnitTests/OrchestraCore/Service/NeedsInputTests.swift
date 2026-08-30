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
/// starting. Every case drives the real observation, lifecycle, or hook seam rather than seeding phase
/// directly, so the tests exercise the production transition funnel.
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

    @Test("a relaunch intent and failed landing both preserve it")
    func relaunchIntentAndFailurePreserve() async throws {
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
        await env.svc.testSetTurnStatus(t.id, .running)
        let oldPhaseDate = Date(timeIntervalSince1970: 1)
        await env.svc.seedPhase(t.id, .live(.running), phaseChangedAt: oldPhaseDate)

        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [.init(sessionEpoch: epoch, turnID: "next-turn", kind: .turnStarted)]
        )

        let after = try #require(await card(env.svc, t.id))
        #expect(after.pendingQuestion == nil)
        #expect(after.phaseChangedAt > oldPhaseDate)
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

    @Test("a current-generation session rollover alone preserves it")
    func rolloverAlonePreserves() async throws {
        let env = TestEnv.make()
        let t = try await liveCard(env.svc, TestEnv.repo(env.base))
        let epoch = try #require(await card(env.svc, t.id)).sessionEpoch
        _ = try await env.svc.needsInput(ref: t.shortId, question: "which base?")

        try await env.svc.report(t.id, StatusReport(sessionId: "fresh-session"), observedEpoch: epoch)
        #expect(await card(env.svc, t.id)?.pendingQuestion?.text == "which base?")
    }
}
