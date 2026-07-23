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

    // MARK: - waitReason (notification classification)

    private func parse(_ kind: String, _ json: String) -> StatusReport? {
        let p = (try? JSONValue.parse(Data(json.utf8))) ?? .object([:])
        return ClaudeCodeAdapter().parse(.hooksPush(kind: kind, payload: p))
    }

    @Test("Task encodes/decodes waitReason round-trip; absent decodes to nil")
    func waitReasonCodable() async throws {
        let (_, t) = try await spawned()
        var card = t
        card.phase = .live(.waiting(.permission))
        let data = try JSONEncoder().encode(card)
        let back = try JSONDecoder().decode(Task.self, from: data)
        #expect(back.waitReason == .permission)
        let legacy = try JSONEncoder().encode(t)          // t.waitReason is nil already
        #expect(try JSONDecoder().decode(Task.self, from: legacy).waitReason == nil)
    }

    @Test("StatusReport routes waitReason into the snapshot bucket")
    func waitReasonRoutes() {
        let r = StatusReport(run: .waiting(.permission))
        #expect(r.snapshot?.run == .waiting(.permission))
        #expect(r.snapshot?.run != nil)
    }

    @Test("StatusReport routes provider-neutral turn completion into the snapshot bucket")
    func turnCompletedRoutes() {
        let r = StatusReport(run: .waiting(.humanTurn), turnCompleted: true)
        #expect(r.snapshot?.run != nil)
        #expect(r.snapshot?.run == .waiting(.humanTurn))
        #expect(r.snapshot?.turnCompleted == true)
    }

    @Test("report sets waitReason on a waiting snapshot and clears it when status leaves waiting")
    func waitReasonLifecycle() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(run: .waiting(.permission)))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.waitReason != nil)
        #expect(after.waitReason == .permission)
        try await env.svc.report(t.id, StatusReport(run: .running))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.waitReason == nil)
    }

    @Test("fileTail permission hook fences a late stale .running rollout line (#10 C1 race)")
    func fileTailPermissionFence() async throws {
        // A fileTail agent (Codex): telemetry == .fileTail, so the permission fence is active.
        let env = TestEnv.make(capabilities: .codex)
        let repo = TestEnv.repo(env.base)
        // .codex is `.rolloutMeta` → the blank spawn awaits; drive its launch-ready signal (spawnAwaited).
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "Task", repo: repo, branch: "b"))

        // The PermissionRequest hook arrives as a seq==0 push → the card blocks on permission.
        try await env.svc.report(t.id, StatusReport(run: .waiting(.permission)))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.waitReason != nil)
        #expect(after.waitReason == .permission)

        // The tool-call rollout line the agent wrote µs BEFORE it blocked (→ .running, seq = its
        // timestamp) is delivered a poll-tick LATER by the tailer. Its seq is far below "now", so the
        // fence (cursor advanced to now-µs by the hook) drops it — the permission wait survives. Pre-fix
        // this seq (> 0) sailed past the gate and flipped the card back to .running: no Needs-You, no push.
        try await env.svc.report(t.id, StatusReport(seq: 1_000, run: .running))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.waitReason != nil, "a late pre-block .running line must not un-block the permission wait")
        #expect(after.waitReason == .permission)

        // A genuinely-later line (timestamp AFTER the fence, i.e. post-approval work) still applies.
        let future = UInt64(Date().timeIntervalSince1970 * 1_000_000) + 5_000_000
        try await env.svc.report(t.id, StatusReport(seq: future, run: .running))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.phaseDisplay == .running, "a genuinely-later line still advances the card past permission")
    }

    @Test("Notification permission_prompt → waiting/.permission")
    func classifyPermission() {
        let r = parse("notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#)
        #expect(r?.snapshot?.run != nil)
        #expect(r?.snapshot?.run == .waiting(.permission))
        #expect(r?.snapshot?.desc == "Claude needs your permission to use Bash")
    }

    @Test("Notification idle_prompt → waiting/.humanTurn")
    func classifyIdle() {
        let r = parse("notification", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#)
        #expect(r?.snapshot?.run != nil)
        #expect(r?.snapshot?.run == .waiting(.humanTurn))
    }

    @Test("Stop with no background work → waiting/.humanTurn")
    func classifyStopIdle() {
        let r = parse("stop", #"{"background_tasks":[],"session_crons":[]}"#)
        #expect(r?.snapshot?.run != nil)
        #expect(r?.snapshot?.run == .waiting(.humanTurn))
        #expect(r?.snapshot?.turnCompleted != true)
    }

    @Test("TaskCompleted → waiting/.humanTurn with turn-completion signal")
    func classifyTaskCompleted() {
        let r = parse("taskcompleted", #"{"task_id":"task-1","task_subject":"answer"}"#)
        #expect(r?.snapshot?.run != nil)
        #expect(r?.snapshot?.run == .waiting(.humanTurn))
        #expect(r?.snapshot?.turnCompleted == true)
    }

    @Test("Stop with pending background_tasks → nil (no status change)")
    func classifyStopBackgroundTasks() {
        let r = parse("stop", #"{"background_tasks":[{"id":"t1","type":"shell","status":"running"}],"session_crons":[]}"#)
        #expect(r == nil)
    }

    @Test("Stop with pending session_crons → nil (no status change)")
    func classifyStopCrons() {
        let r = parse("stop", #"{"background_tasks":[],"session_crons":[{"id":"c1","schedule":"*/5 * * * *"}]}"#)
        #expect(r == nil)
    }

    @Test("merges only present fields; ctxPct/desc/model update in place")
    func mergeFields() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(ctxPct: 42, modelId: "m2", desc: "Editing Foo.swift", run: .running))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.ctxPct == 42)
        #expect(after.desc == "Editing Foo.swift")
        #expect(after.model.id == "m2")   // a reported launch id updates the model (never a display label)
        #expect(after.phaseDisplay == .running)
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
        #expect(after.waitReason != nil)          // clear → idle
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
        #expect(after.phaseDisplay == .running)
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

    /// A prompt hook from a SUPERSEDED session must not clear the flag on the incoming generation: the
    /// RelaunchStepper reads it to decide a card with no transcript may still blank-launch, so clearing
    /// it strands the card `.resumeFailed`.
    @Test("a stale-epoch prompt does not clear awaitingFirstPrompt")
    func staleEpochPromptCannotStrandTheRelaunch() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        let epoch = try #require(await env.svc.list().first { $0.id == t.id }).sessionEpoch
        try await env.svc.report(t.id, StatusReport(promptText: "from the dying session"),
                                 observedEpoch: epoch - 1)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.awaitingFirstPrompt == true)   // still eligible for the blank relaunch
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
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))              // transition
        try await pollUntil("statusChanged activity delivered") {
            await collector.activities.contains { $0.kind == .statusChanged }
        }
        await yieldBriefly()   // settle so a wrongful ctx activity would also have landed
        let acts = await collector.activities
        #expect(acts.contains { $0.kind == .statusChanged })
        #expect(!acts.contains { $0.kind == .statusChanged && $0.text.contains("ctx") })
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
