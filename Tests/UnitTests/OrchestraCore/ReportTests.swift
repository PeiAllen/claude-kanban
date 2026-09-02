import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("OrchestraService.report — merge / rollover / seq-guard / re-title")
struct ReportTests {

    private func spawned() async throws -> (env: ReturnType, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "Initial task", repo: repo, branch: "b"))
        return (env, t)
    }
    typealias ReturnType = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)

    @Test("Task encodes and decodes AgentState human need independently of turn status")
    func agentStateCodable() async throws {
        let (_, t) = try await spawned()
        var card = t
        card.phase = .live(.init(turnStatus: .running, humanNeed: .permission))
        let data = try JSONEncoder().encode(card)
        let back = try JSONDecoder().decode(Task.self, from: data)
        #expect(back.turnStatus == .running)
        #expect(back.agentState?.humanNeed == .permission)
    }

    @Test("merges only present fields; ctxPct/desc/model update in place")
    func mergeFields() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(ctxPct: 42, modelId: "m2", desc: "Editing Foo.swift"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.ctxPct == 42)
        #expect(after.desc == "Editing Foo.swift")
        #expect(after.model.id == "m2")   // a reported launch id updates the model (never a display label)
        #expect(after.turnStatus == .unavailable)  // metadata reports never manufacture provider status
    }

    @Test("a reported display label updates modelDisplay only — never the launch id")
    func modelDisplayDoesNotClobberLaunchId() async throws {
        let (env, t) = try await spawned()
        let launchId = (await env.svc.list().first { $0.id == t.id })!.model.id
        // A statusline that carries only a human label must not become the launch id.
        try await env.svc.report(t.id, StatusReport(modelDisplay: "Sonnet 4.6 (Pretty)"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.model.id == launchId)                       // launch id intact
        #expect(after.model.displayName == "Sonnet 4.6 (Pretty)") // label updated
    }

    @Test("a new sessionId rolls the old onto priorSessionIds")
    func sessionRollover() async throws {
        let (env, t) = try await spawned()
        let oldId = try #require(t.agentSessionId)
        try await env.svc.report(t.id, StatusReport(sessionId: "brand-new-id", sessionSource: "clear"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.agentSessionId == "brand-new-id")
        #expect(after.priorSessionIds.contains(oldId))
        #expect(after.awaitingFirstPrompt == true)   // clear sets provisional
        #expect(after.turnStatus == .unavailable)   // replacement session awaits fresh observation
    }

    /// A genuine in-session `/rename` — a reported name that DIFFERS from the one the launch pushed —
    /// adopts and PINS. It no longer clears `awaitingFirstPrompt`: renaming is not being prompted, and
    /// that flag now means only "this session has never had a prompt" (it gates the blank relaunch).
    @Test("a reported name that changed adopts + pins the title; empty is ignored")
    func sessionName() async throws {
        let (env, t) = try await spawned()
        let epoch = try #require(await env.svc.list().first { $0.id == t.id }).sessionEpoch
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(sessionName: "Renamed Card"), observedEpoch: epoch)
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Renamed Card")
        #expect(after.titleSource == .explicit)      // pinned, exactly like set-title
        #expect(after.awaitingFirstPrompt == true)   // a rename is not a prompt
        // empty sessionName must not clobber
        try await env.svc.report(t.id, StatusReport(sessionName: ""), observedEpoch: epoch)
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Renamed Card")
    }

    /// The clobber this PR exists to stop: a live Claude session keeps echoing the `--name` it launched
    /// with, so a mirror keyed on "differs from the title" re-applied that stale name after every rename.
    /// The baseline is pre-armed at launch, so the echo is inert no matter how many times it arrives.
    @Test("a session_name echoing the launched --name never overwrites a newer title")
    func sessionNameEchoIsNotARename() async throws {
        let (env, t) = try await spawned()
        let launched = t.title
        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        let epoch = try #require(await env.svc.list().first { $0.id == t.id }).sessionEpoch
        for seq in 1...3 {   // every statusline tick still carries the OLD name
            try await env.svc.report(t.id, StatusReport(seq: UInt64(seq), sessionName: launched),
                                     observedEpoch: epoch)
        }
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Reviewer A")
        #expect(after.titleSource == .explicit)
    }

    /// A report from a SUPERSEDED generation cannot rename: `restart` bumps the epoch while the outgoing
    /// session is still alive and still reporting the name it launched with.
    @Test("a stale-epoch session_name never renames the card")
    func staleEpochSessionNameIsIgnored() async throws {
        let (env, t) = try await spawned()
        let epoch = try #require(await env.svc.list().first { $0.id == t.id }).sessionEpoch
        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        try await env.svc.report(t.id, StatusReport(sessionName: "Ghost Of A Dead Session"),
                                 observedEpoch: epoch - 1)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Reviewer A")
    }

    /// The re-title is scoped two ways now: to the FIRST prompt (via `awaitingFirstPrompt`, since the
    /// prompt hook fires on every turn) and to a card whose title actually came from a prompt.
    @Test("first prompt after /clear re-titles a prompt-titled card; a second prompt does not")
    func reTitleAfterClear() async throws {
        let (env, t) = try await spawned()
        // This card is a worktree card, so it is branch-titled — force the prompt-titled case explicitly.
        _ = try await env.svc.store.update(t.id) { $0.titleSource = .prompt }
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(promptText: "Now do something else\nmore"))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Now do something else")
        #expect(after.awaitingFirstPrompt == false)
        #expect(after.turnStatus == .unavailable)  // a prompt report is metadata, not a turn observation
        // a later prompt does NOT re-title
        try await env.svc.report(t.id, StatusReport(promptText: "And another thing"))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Now do something else")
    }

    /// A branch/attached/explicit title outranks the prompt cutoff that used to win here.
    @Test("a first prompt never re-titles a branch-titled or pinned card")
    func firstPromptRespectsTitleSource() async throws {
        let (env, t) = try await spawned()
        #expect(t.titleSource == .branch)
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(promptText: "Should not become the title"))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "b")                  // still the branch
        #expect(after.awaitingFirstPrompt == false)  // …but the lifecycle flag still cleared
        // Same for an explicitly pinned title.
        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(promptText: "Nor this"))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Reviewer A")
    }

    /// A prompt hook from the session a `restart` is REPLACING must not touch the incoming generation.
    ///
    /// Honest about what this pins: a STAMPED stale epoch was already fenced before this PR, and the
    /// `.relaunching` assertion holds regardless because `transition()` drops a stamped-stale phase write on
    /// its own epoch fence. So this case is a guard, not the proof. The two that fail if the fence is
    /// reverted are `nilEpochPromptIsFencedWhileBeingBorn` (the unstamped hijack) and
    /// `staleEpochPromptOnALiveCardIsIgnored` (the stamped-stale case once the relaunch has landed).
    @Test("a stale-epoch prompt cannot strand or hijack a card mid-restart")
    func staleEpochPromptCannotStrandTheRelaunch() async throws {
        let (env, t) = try await spawned()
        let relaunching = try await env.svc.restart(t.id)      // intent-only: bumps the epoch, → .relaunching
        #expect(relaunching.phase.kind == .relaunching)
        #expect(relaunching.awaitingFirstPrompt == true)

        try await env.svc.report(t.id, StatusReport(promptText: "from the dying session"),
                                 observedEpoch: relaunching.sessionEpoch - 1)

        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.awaitingFirstPrompt == true)     // still eligible for the blank relaunch
        #expect(after.phase.kind == .relaunching)      // …and the relaunch was not dropped
    }

    /// An UNSTAMPED prompt (a pre-epoch session, whose hooks send no epoch at all) is fenced the same way
    /// while a card is being born — the documented migration behavior, and the fail-safe direction.
    @Test("a nil-epoch prompt cannot hijack a card mid-restart either")
    func nilEpochPromptIsFencedWhileBeingBorn() async throws {
        let (env, t) = try await spawned()
        let relaunching = try await env.svc.restart(t.id)
        try await env.svc.report(t.id, StatusReport(promptText: "from a pre-upgrade session"),
                                 observedEpoch: nil)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.awaitingFirstPrompt == true)
        #expect(after.phase.kind == .relaunching)
        #expect(relaunching.sessionEpoch == after.sessionEpoch)
    }

    /// The window a being-born-only fence would MISS: the relaunch has already landed `.live`, so the card
    /// is no longer being born — but the session it replaced is still winding down, and its stamped prompt
    /// hook is still in flight. Admitting it clears `awaitingFirstPrompt` on a generation that was never
    /// prompted and re-titles the card from a DEAD session's prompt, in the PR whose thesis is title
    /// integrity. This is why the fence is two terms, not one.
    @Test("a stamped stale-epoch prompt is ignored even after the card is live")
    func staleEpochPromptOnALiveCardIsIgnored() async throws {
        let (env, t) = try await spawned()
        _ = try await env.svc.store.update(t.id) { $0.titleSource = .prompt; $0.awaitingFirstPrompt = true }
        let live = try #require(await env.svc.store.get(t.id))
        #expect(live.phase.kind == .live)          // NOT being born

        try await env.svc.report(t.id, StatusReport(promptText: "from the session it replaced"),
                                 observedEpoch: live.sessionEpoch - 1)

        let after = try #require(await env.svc.store.get(t.id))
        #expect(after.awaitingFirstPrompt == true)   // the new generation was never prompted
        #expect(after.title == t.title)              // …and was not renamed by a dead session
    }

    /// …while an ordinary prompt to a card that is NOT being born is unaffected by the fence, epoch or no
    /// epoch. Narrowing that would break every normal turn.
    @Test("a live card's prompt still lands, with no epoch")
    func livePromptIsNotFenced() async throws {
        let (env, t) = try await spawned()
        _ = try await env.svc.store.update(t.id) { $0.titleSource = .prompt }
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(promptText: "a normal turn"), observedEpoch: nil)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.awaitingFirstPrompt == false)
        #expect(after.title == "a normal turn")
        #expect(after.turnStatus == .unavailable)  // current provider observation owns live status
    }

    @Test("no-delta report = no persist, no event (idempotent)")
    func idempotent() async throws {
        let (env, t) = try await spawned()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        try await env.svc.report(t.id, StatusReport(ctxPct: 10))
        try await env.svc.report(t.id, StatusReport(ctxPct: 10))   // same value → no event
        try await pollUntil("first report's upsert delivered") {
            await collector.upserts.contains { $0.id == t.id }
        }
        await yieldBriefly()   // then settle: a wrongful second upsert gets its chance to land
        let upserts = await collector.upserts.filter { $0.id == t.id }
        #expect(upserts.count == 1)
    }

    @Test("seq guard: stale snapshot dropped (1→3→2), gauge never ticks backward; per-card")
    func seqGuard() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(seq: 1, ctxPct: 41))
        try await env.svc.report(t.id, StatusReport(seq: 3, ctxPct: 43))
        try await env.svc.report(t.id, StatusReport(seq: 2, ctxPct: 42))   // stale → dropped
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.ctxPct == 43)
        // a second card's low seq is independent
        let t2 = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "second", repo: TestEnv.repo(env.base), branch: "b2"))
        try await env.svc.report(t2.id, StatusReport(seq: 1, ctxPct: 9))
        let after2 = try #require(await env.svc.list().first { $0.id == t2.id })
        #expect(after2.ctxPct == 9)
    }

    @Test("event-ordered transitions are NOT seq-gated (rollover applies even with a low seq)")
    func transitionsNotGated() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(seq: 5, ctxPct: 50))
        // a low-seq report still applies the sessionId rollover (event-ordered), even though its
        // snapshot ctxPct is dropped
        try await env.svc.report(t.id, StatusReport(seq: 1, sessionId: "rolled", ctxPct: 1))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.agentSessionId == "rolled")   // transition applied
        #expect(after.ctxPct == 50)                  // stale snapshot dropped
    }

    @Test("SessionEnd genuine exit → .dead (agentExited); transition reasons never reach report")
    func sessionEndDead() async throws {
        let (env, t) = try await spawned()
        // A post-upgrade SessionEnd carries the session's ORCH_EPOCH, so the funnel applies the kill via
        // its generation fence (no liveness probe needed). A NIL-epoch SessionEnd would instead require a
        // real `isAlive` probe first — that discipline is covered by PhaseTransitionTests.
        try await env.svc.report(t.id, StatusReport(endReason: "exit"), observedEpoch: t.sessionEpoch)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .agentExited)
    }

    @Test("status transition emits .statusChanged; ctxPct-only emits no activity")
    func activityOnlyOnTransition() async throws {
        let (env, t) = try await spawned()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        try await env.svc.report(t.id, StatusReport(ctxPct: 5))                      // no activity
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        await env.svc.receiveAgentSignals(
            cardId: t.id,
            signals: [
                .init(sessionEpoch: epoch, turnID: "activity-turn", kind: .turnStarted),
                .init(sessionEpoch: epoch, turnID: "activity-turn", kind: .turnCompleted()),
            ]
        )
        try await pollUntil("statusChanged activity delivered") {
            await collector.activities.contains { $0.kind == .statusChanged }
        }
        await yieldBriefly()   // settle so a wrongful ctx activity would also have landed
        let acts = await collector.activities
        #expect(acts.contains { $0.kind == .statusChanged })
        #expect(!acts.contains { $0.kind == .statusChanged && $0.text.contains("ctx") })
    }

    // MARK: - humanPaced (the stall-row human-pacing signal)

    private func humanPaced(_ svc: OrchestraService, _ id: UUID) async -> Bool {
        (await svc.list().first { $0.id == id })?.humanPaced ?? false
    }

    private func turn(_ kind: AgentSignal.Kind, on task: Task, in service: OrchestraService) async throws {
        let epoch = (await service.store.get(task.id))?.sessionEpoch ?? task.sessionEpoch
        let turnID = UUID().uuidString
        let signals: [AgentSignal]
        switch kind {
        case .turnCompleted(let resume):
            // A terminal only describes a known current provider turn. Give the test a real pair
            // rather than relying on the old uncorrelated completion compatibility path.
            signals = [
                .init(sessionEpoch: epoch, turnID: turnID, kind: .turnStarted),
                .init(sessionEpoch: epoch, turnID: turnID, kind: .turnCompleted(resume: resume)),
            ]
        case .turnStarted:
            signals = [.init(sessionEpoch: epoch, turnID: turnID, kind: kind)]
        default:
            signals = [.init(sessionEpoch: epoch, turnID: turnID, kind: kind)]
        }
        await service.receiveAgentSignals(
            cardId: task.id,
            signals: signals
        )
        try await service.waitForObservationQueueIdle(task.id)
    }

    /// A prompt typed into an idle-WAITING session is a direct human turn and marks the card human-paced;
    /// the launch's own seed prompt does not, because it lands while the card is `.running` (prompt in
    /// flight) — never through `.waiting`. That split is what keeps an agent-work card's
    /// safety-net stall alive while exempting a card a human is actually pacing.
    @Test("a prompt on an idle-waiting card sets humanPaced; a prompt while running does not")
    func humanPacedSetOnlyByAnIdleHumanTurn() async throws {
        let (env, t) = try await spawned()
        #expect(t.humanPaced == false)                                   // a fresh spawn seed ⇒ agent-paced
        // A prompt echoed while the card is RUNNING (the launch seed being submitted) is not a fresh human
        // turn: the card never sat in `.waiting`, so it stays agent-paced.
        try await env.svc.report(t.id, StatusReport(promptText: "seed echo"))
        #expect(await humanPaced(env.svc, t.id) == false)
        // Once the turn concludes and the card idle-waits, a prompt IS a direct human turn.
        try await turn(.turnCompleted(), on: t, in: env.svc)
        try await env.svc.report(t.id, StatusReport(promptText: "human follow-up"))
        #expect(await humanPaced(env.svc, t.id) == true)
    }

    /// A system-supplied launch seed reaches the report path as a `promptText`. The first stamped prompt
    /// for that generation consumes the marker; only a later prompt is classified as human.
    @Test("the launch's machine seed prompt is not human-paced; a later human prompt is")
    func humanPacedSkipsTheMachineSeedTurn() async throws {
        let (env, t) = try await spawned()      // spawns WITH a prompt → finishLaunch owes a machine turn at this epoch
        let epoch = t.sessionEpoch
        try await turn(.turnCompleted(), on: t, in: env.svc)
        // Stamped with the launch epoch: this IS the seed's own prompt, even though it lands on the idle wait.
        try await env.svc.report(t.id, StatusReport(promptText: "the machine seed"), observedEpoch: epoch)
        #expect(await humanPaced(env.svc, t.id) == false)
        // Marker consumed → the next prompt (after the turn concludes) is a genuine human turn.
        try await turn(.turnCompleted(), on: t, in: env.svc)
        try await env.svc.report(t.id, StatusReport(promptText: "a real human follow-up"), observedEpoch: epoch)
        #expect(await humanPaced(env.svc, t.id) == true)
    }

    /// A handoff hands the card a fresh AGENT-driving SEED, so it clears human-pacing. A blank restart
    /// instead lands `awaitingFirstPrompt` — the human's move again — so it SETS human-paced, even on a
    /// card that was agent-paced (proving it is set, not merely preserved).
    @Test("a handoff seed clears humanPaced; a blank restart sets it (the human's move)")
    func humanPacedClearedByHandoffSetByBlankRestart() async throws {
        // A seeded spawn is agent-paced; a blank restart makes it the human's move.
        let (env1, t1) = try await spawned()
        #expect(t1.humanPaced == false)
        let relaunching = try await env1.svc.restart(t1.id)
        #expect(relaunching.humanPaced == true)

        // A human-paced card handed a seed (a handoff) becomes agent-paced.
        let (env2, t2) = try await spawned()
        try await turn(.turnCompleted(), on: t2, in: env2.svc)
        try await env2.svc.report(t2.id, StatusReport(promptText: "human"))
        #expect(await humanPaced(env2.svc, t2.id) == true)
        let handed = try await env2.svc.resume(t2.id, seed: "handoff context")   // seed → agent-driving
        #expect(handed.humanPaced == false)
    }

}

@Suite("report field-delta") struct ReportDeltaTests {
    private func sample() -> Task {
        Task(title: "c", repo: "/r", branch: "b", cwd: "/wt/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: .plan, order: 0, initialPrompt: "c")
    }
    @Test("applyReportFields overlays only report-owned fields, preserving concurrently-mutated ones")
    func test_reportDoesNotClobberConcurrentFields() throws {
        // `current` = the store's live value, with an UNRELATED field (column) changed concurrently
        // after report took its snapshot. `snapshot` = what report computed from its (older) read.
        var current = sample()
        current.column = .impl             // concurrent write to a field report does NOT own
        current.ctxPct = 0
        var before = current               // what report READ before it suspended
        before.column = .plan              // report's stale view of the unowned field
        var snapshot = before
        snapshot.ctxPct = 42               // report's owned field, freshly computed

        current.applyReportFields(from: snapshot, changedFrom: before)

        #expect(current.ctxPct == 42)      // owned field applied
        #expect(current.column == .impl)   // unowned field PRESERVED — not clobbered
    }

    /// The delta half: an owned field report did NOT change must also survive, because `set-title` is a
    /// second writer of exactly those fields and lands inside report()'s read→write window.
    @Test("applyReportFields leaves an owned field report didn't change to a concurrent writer")
    func test_reportPreservesAConcurrentRename() throws {
        var current = sample()
        current.title = "Reviewer A"        // a `set-title` that landed while report was suspended
        current.titleSource = .explicit
        var before = current
        before.title = "feat"               // report's stale read
        before.titleSource = .branch
        before.lastSessionName = "feat"
        var snapshot = before
        snapshot.desc = "working"           // the ONLY field this report actually changed

        current.applyReportFields(from: snapshot, changedFrom: before)

        #expect(current.title == "Reviewer A")        // the rename survives
        #expect(current.titleSource == .explicit)
        #expect(current.desc == "working")            // …and report's own change still lands
    }

    @Test("a status-only report preserves a concurrent launch cutoff, while session binding clears it")
    func test_reportPreservesDiscoveryCutoffUntilSessionBinds() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        var current = sample()
        current.sessionDiscoverySince = cutoff

        // This snapshot began before a relaunch recorded the cutoff, so ordinary telemetry must not erase it.
        var before = current
        before.sessionDiscoverySince = nil          // report's read predates the cutoff
        var statusOnly = before
        statusOnly.desc = "Running"
        current.applyReportFields(from: statusOnly, changedFrom: before)
        #expect(current.sessionDiscoverySince == cutoff)

        let beforeBind = current
        var binding = current
        binding.agentSessionId = "fresh-session"
        binding.sessionDiscoverySince = nil
        current.applyReportFields(from: binding, changedFrom: beforeBind)
        #expect(current.agentSessionId == "fresh-session")
        #expect(current.sessionDiscoverySince == nil)
    }
}
