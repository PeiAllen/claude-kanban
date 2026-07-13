import Foundation
import Testing
@testable import OrchestraCore

/// `--model` on restart / handoff / resume: re-seat a LIVE card onto a different model in place, carrying
/// its context, instead of spawning a successor card. The launch id is staged in `pendingModel` (not read
/// back off `model`), which is what makes the re-seat survive the window between the intent-only verb and
/// the stepper's relaunch — see `reseatSurvivesTheDyingSessionsStatusline`, the regression that motivates
/// the whole design.
@Suite("re-seat — `--model` on restart / handoff / resume")
struct ModelReseatTests {

    /// The argv the card's session was actually launched with.
    private func argv(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                             adapter: StubAdapter, trust: TrustLedger, base: String),
                      _ id: UUID) -> [String] {
        env.sessions.ensureArgv[env.sessions.sessionName(id)] ?? []
    }

    /// A live card, ready to be re-seated. Spawns on `m1` (the stub catalog's first model).
    private func liveCard(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                                  adapter: StubAdapter, trust: TrustLedger, base: String),
                          branch: String = "b") async throws -> Task {
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: branch))
        #expect(t.model.id == "m1")
        return t
    }

    // MARK: - the override reaches the launch

    @Test("restart --model: staged on pendingModel, and the fresh session launches on the new model")
    func restartReseats() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)

        let intent = try await env.svc.restart(t.id, model: "m2")
        #expect(intent.phase.kind == .relaunching)
        #expect(intent.pendingModel == "m2")   // the launch intent
        #expect(intent.model.id == "m2")       // and the board shows it at once

        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(argv(env, t.id).contains("--model"))
        #expect(argv(env, t.id).contains("m2"))
        #expect(live.model.id == "m2")
        #expect(live.pendingModel == nil)      // consumed on the `.live` landing, like `pendingSeed`
    }

    @Test("resume --model: the resumed session launches on the new model, same session id")
    func resumeReseats() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)

        _ = try await env.svc.resume(t.id, model: "m2")
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)

        #expect(argv(env, t.id).contains("--resume"))   // resumed, not blank-restarted
        #expect(argv(env, t.id).contains("m2"))
        #expect(live.agentSessionId == t.agentSessionId)   // context carried: same transcript
        #expect(live.model.id == "m2")
    }

    @Test("handoff --model: THE motivating case — same session, seed delivered, new model")
    func handoffReseats() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)
        env.adapter.writeTranscript(for: t.agentSessionId!)

        _ = try await env.svc.resumeInCard(t.id, seed: "ESCALATION SUMMARY", model: "m2")
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)

        let a = argv(env, t.id)
        #expect(a.contains("--resume"))
        #expect(a.contains("m2"))
        #expect(a.last == "ESCALATION SUMMARY")   // the handoff context still rides as the opening turn
        #expect(live.agentSessionId == t.agentSessionId)
        #expect(live.model.id == "m2")
    }

    // MARK: - the regression the design exists for

    @Test("the DYING session's statusline cannot revert the re-seat (report() is not epoch-fenced)")
    func reseatSurvivesTheDyingSessionsStatusline() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)

        // Re-seat to m2. restart/resume are INTENT-ONLY: the card is `.relaunching` and the OLD session is
        // still alive and reporting — the stepper has not killed it yet.
        _ = try await env.svc.restart(t.id, model: "m2")

        // The old session's statusline lands, naming the model IT is running (m1). report()'s field-delta
        // half is not epoch-fenced, so this DOES write `model` back to m1 — and before `pendingModel`
        // existed, `finishLaunch` read exactly that field and relaunched on the model we were leaving.
        try await env.svc.report(t.id, StatusReport(modelId: "m1"))
        let mid = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(mid.model.id == "m1")        // the revert really happens...
        #expect(mid.pendingModel == "m2")    // ...but the INTENT is untouchable by report()

        // So the relaunch still goes up on m2, and the landing restores the display model.
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(argv(env, t.id).contains("m2"))
        #expect(!argv(env, t.id).contains("m1"))
        #expect(live.model.id == "m2")
        #expect(live.pendingModel == nil)
    }

    @Test("a launch that FAILS keeps pendingModel staged for the retry (mirrors pendingSeed)")
    func failedLaunchKeepsTheReseat() async throws {
        let env = TestEnv.make(grace: 1)
        let t = try await liveCard(env)
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        // No transcript on disk → the resume cannot proceed; the card must not silently lose the re-seat.
        env.adapter.deleteTranscript(for: t.agentSessionId!)

        _ = try await env.svc.resume(t.id, model: "m2")
        await env.svc.reconcile()
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.pendingModel == "m2")   // still staged — a later retry re-seats as asked
    }

    // MARK: - validation (the id never reaches the CLI unchecked)

    @Test("unknown model is rejected, and the card is left completely untouched")
    func unknownModelRejected() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)

        await #expect(throws: OrchestraError.self) { try await env.svc.restart(t.id, model: "no-such-model") }

        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.phase.kind == .live)      // not relaunched
        #expect(after.model.id == "m1")         // not re-seated
        #expect(after.pendingModel == nil)
    }

    @Test("a model valid for ANOTHER agent is still rejected on this card (no `claude --model gpt-…`)")
    func crossAdapterModelRejected() async throws {
        // Two agents: this card is `claude-code` (m1/m2); `codex` has a disjoint catalog (g1/g2).
        let env = TestEnv.make(grace: 2, extraAgents: [(id: "codex", models: ["g1", "g2"])])
        let t = try await liveCard(env)
        #expect(t.agentId == "claude-code")

        // g1 is a real model — for the OTHER adapter. The card's agentId can never change (its transcript is
        // vendor-specific), so authorizing it here would launch `claude --model g1` and die at the process.
        await #expect(throws: OrchestraError.self) { try await env.svc.restart(t.id, model: "g1") }
        await #expect(throws: OrchestraError.self) { try await env.svc.resume(t.id, model: "g2") }

        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.model.id == "m1")
        #expect(after.pendingModel == nil)
    }

    @Test("an explicitly-passed empty/whitespace model is an error, not a silent no-op")
    func emptyModelRejected() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)
        await #expect(throws: OrchestraError.self) { try await env.svc.restart(t.id, model: "") }
        await #expect(throws: OrchestraError.self) { try await env.svc.restart(t.id, model: "   ") }
        #expect(try #require(await env.svc.list().first { $0.id == t.id }).phase.kind == .live)
    }

    @Test("surrounding whitespace is trimmed, and a DATED vendor id resolves to its catalog entry")
    func idNormalization() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)
        // The vendor's resolved id carries a date the offline table omits (`claude-haiku-4-5` vs
        // `claude-haiku-4-5-20251001`), and that dated form is what people have written down.
        let intent = try await env.svc.restart(t.id, model: "  m2-20251001 ")
        #expect(intent.pendingModel == "m2")       // canonicalized back to the catalog id
        #expect(intent.model.id == "m2")
    }

    @Test("a rejected handoff --model does NOT eat the card's durable inbox")
    func rejectedHandoffPreservesTheInbox() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await liveCard(env)
        try await env.svc.send(t.id, "do not lose me")
        #expect(try await env.svc.inboxPeek(t.id).count == 1)

        // `resumeInCard` DRAINS the inbox (destructively) before resuming, folding it into the seed. If the
        // model were validated only downstream in `resume`, the throw would land AFTER the drain and the
        // queued messages would be gone for good.
        await #expect(throws: OrchestraError.self) {
            try await env.svc.resumeInCard(t.id, seed: "ctx", model: "no-such-model")
        }
        #expect(try await env.svc.inboxPeek(t.id).count == 1)   // survived the rejection
    }

    // MARK: - "did the vendor honor it?" tripwire

    @Test("an agent that comes up on the WRONG model warns once — it does not revert in silence")
    func vendorIgnoredTheFlagWarns() async throws {
        let env = TestEnv.make(grace: 2)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let t = try await liveCard(env)

        _ = try await env.svc.restart(t.id, model: "m2")
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)   // landed: pendingModel consumed, watch armed

        // The NEW session insists it is running m1. One stale line is tolerated (the tailer can surface a
        // last pre-kill rollout line); a vendor that truly ignored `--model` says so on every tick.
        try await env.svc.report(t.id, StatusReport(modelId: "m1"))
        try await _Concurrency.Task.sleep(for: .milliseconds(50))   // let the event stream flush
        #expect(await collector.activities.filter { $0.kind == .warning }.isEmpty)

        try await env.svc.report(t.id, StatusReport(seq: 2, modelId: "m1"))
        try await pollUntil { await !collector.activities.filter { $0.kind == .warning }.isEmpty }

        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.count == 1)   // exactly once — not a per-tick drumbeat
        let text = try #require(warnings.first?.text)
        #expect(text.contains("m2"))   // what we asked for
        #expect(text.contains("m1"))   // what is actually running
    }

    @Test("an agent that confirms the re-seat never warns — including via its DATED id")
    func vendorHonoredTheFlagIsSilent() async throws {
        let env = TestEnv.make(grace: 2)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let t = try await liveCard(env)

        _ = try await env.svc.restart(t.id, model: "m2")
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)

        // The agent answers with the vendor's dated form of the SAME model. A raw `==` would call this a
        // mismatch and accuse the vendor of ignoring a flag it honored.
        try await env.svc.report(t.id, StatusReport(modelId: "m2-20251001"))
        try await env.svc.report(t.id, StatusReport(seq: 2, modelId: "m2-20251001"))
        try await _Concurrency.Task.sleep(for: .milliseconds(50))   // let the event stream flush
        #expect(await collector.activities.filter { $0.kind == .warning }.isEmpty)
    }

    @Test("reports arriving BEFORE the relaunch lands are the dying session's — they never warn")
    func preLandingReportsDoNotWarn() async throws {
        let env = TestEnv.make(grace: 2)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let t = try await liveCard(env)

        _ = try await env.svc.restart(t.id, model: "m2")
        // Still `.relaunching` (pendingModel set): these are the OLD process's statuslines, naming the old
        // model. Judging them would accuse the vendor of ignoring a flag it was never passed. Codex reports
        // carry no epoch at all, so this fence — `pendingModel == nil` — is deliberately epoch-free.
        try await env.svc.report(t.id, StatusReport(modelId: "m1"))
        try await env.svc.report(t.id, StatusReport(seq: 2, modelId: "m1"))
        try await _Concurrency.Task.sleep(for: .milliseconds(50))   // let the event stream flush
        #expect(await collector.activities.filter { $0.kind == .warning }.isEmpty)
    }

    // MARK: - persistence

    @Test("pendingModel round-trips, and a record without the key decodes as no re-seat")
    func codableRoundTrip() throws {
        var t = Task(title: "c", repo: "/r/app", branch: "b", cwd: "/wt/b",
                     model: AgentModel(id: "m1"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        t.pendingModel = "m2"
        let back = try JSONDecoder().decode(Task.self, from: JSONEncoder().encode(t))
        #expect(back.pendingModel == "m2")

        // A pre-feature tasks.json has no `pendingModel` key at all — it must decode (additive-optional),
        // not throw and strand the board.
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"old","repo":"/r","branch":"b","cwd":"/w"}"#
        let migrated = try JSONDecoder().decode(Task.self, from: Data(legacy.utf8))
        #expect(migrated.pendingModel == nil)
    }
}
