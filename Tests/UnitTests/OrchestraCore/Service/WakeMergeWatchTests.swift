import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("C2 · wake + merge-watch (real card state; subscriber; settled-terminal)")
struct WakeMergeWatchTests {

    /// Run `body` with a deadline. Returns nil if it did not finish in time — so a LOST conclusion
    /// fails the test instead of suspending it forever (the suite-wide `--parallel` hang this guards).
    /// Backed by TestSupport's yield-based `withDeadline` (no wall-clock sleep in the race).
    static func withDeadline<T: Sendable>(_ seconds: Double,
                                          _ body: @escaping @Sendable () async -> T) async -> T? {
        await TestSupport.withDeadline(.seconds(seconds), body)
    }

    /// **Bug #2 — the `--parallel` suite hang.** A child that concludes WHILE a `wait` is still between
    /// its card-state read and its MergeWatch subscribe must still resolve that wait. `wait` used to read
    /// state first and subscribe last, with two actor hops in between; a conclusion landing in that window
    /// reached ZERO subscribers, was dropped (MergeWatch keeps no memory of it), and the waiter then parked
    /// on a continuation nobody would ever resume — forever, since `wait` has no timeout. Under a loaded
    /// `swift test --parallel` the window is wide enough to hit, wedging the whole run.
    ///
    /// No `pollUntil` on the subscription here — waiting for the subscribe is what HIDES the race. The
    /// child is killed immediately, so the conclusion races the subscribe. Agent-agnostic: both backends.
    @Test("wait does not lose a conclusion that races its subscribe (bug-#2 suite hang)",
          arguments: [("claude-code", AgentCapabilities.claudeCode),
                      ("codex", ReadinessSignalTests.codexStubCaps)])
    func waitSurvivesConclusionRacingSubscribe(agent: (id: String, caps: AgentCapabilities)) async throws {
        let env = TestEnv.make(capabilities: agent.caps)
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAwaited(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))

        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        env.sessions.setAlive(child.id, false)          // crash: session vanished, no SessionEnd
        await env.svc.reconcileLiveness()               // → .dead(sessionVanished) → concludeCard

        // The card really did settle terminal — so a dropped conclusion is the ONLY way `wait` can hang.
        let settled = try #require(await env.svc.store.get(child.id))
        #expect(settled.phase == .dead(.sessionVanished))

        let concl = await Self.withDeadline(5) { await waiting.value }
        waiting.cancel()
        #expect(concl != nil, "wait never resolved — the conclusion was dropped in the subscribe window")
        #expect(concl??.cardId == child.id)
        #expect(concl??.kind == .exited)
        #expect(concl??.deadReason == .sessionVanished)
    }

    // 1 · conclusion from real card state (archive → Done), driven off the lifecycle event.
    @Test("archive (move to Done) concludes a watched child")
    func concludesOnArchive() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        try await env.svc.archive(child.id)
        let conc = await waiting.value
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
    }

    // 2 · 0-commit branch = NOT concluded (regression: never git merge-base).
    @Test("a live child on a 0-commit branch does NOT conclude (no git-ancestry false positive)")
    func zeroCommitNotConcluded() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Branch has no commits ahead of main (git merge-base would call it 'merged'); the card is alive.
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "ancestor"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        // negative: drive the machinery that COULD wrongly conclude (a reconcile pass over real state),
        // give its async fan-out room, then assert the subscription survived
        await env.svc.reconcile()
        await yieldBriefly()
        #expect(await env.svc.activeWaitSubscriptionCount() == 1)   // still subscribed — real state, not git
        waiting.cancel(); _ = await waiting.value
    }

    // 3 · cancel.
    @Test("wait returns nil when cancelled")
    func waitCancels() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
    }

    // 4 · subscriber, not git-poll: resolution is driven by the service marking terminal (archive),
    //     and wait remains subscribed until THEN even though nothing about git changed.
    @Test("watcher resolves only off the service's terminal transition, not any git state")
    func resolvesOffLifecycleEvent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        await yieldBriefly()   // negative: a wrongful premature resolve gets its chance to land
        #expect(await env.svc.activeWaitSubscriptionCount() == 1) // no premature resolve
        try await env.svc.archive(child.id)                    // the single authority marks terminal
        #expect(await waiting.value?.cardId == child.id)       // now it resolves
    }

    // 5 · a crash (sessionVanished) IS a settled conclusion now (2.5 bug-#2): `markDead` routes through the
    //     funnel, so a non-terminal → terminal death concludes and a suspended `wait` resolves instead of
    //     hanging. (Pre-2.5 a revivable crash silently swallowed the conclusion — the hang this fixes.)
    @Test("a crash (sessionVanished) concludes the wait with .exited/sessionVanished (bug-#2)")
    func crashConcludesWait() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: child.agentSessionId!)
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        env.sessions.setAlive(child.id, false)
        await env.svc.reconcileLiveness()                      // → .dead sessionVanished, routed to conclude
        let concl = await waiting.value                        // the wait resolves (no longer hangs)
        #expect(concl?.cardId == child.id)
        #expect(concl?.kind == .exited)
        #expect(concl?.deadReason == .sessionVanished)
    }

    // 5b · a CLEAN agent exit IS a settled conclusion (.exited).
    @Test("a clean agent exit (SessionEnd exit) concludes with .exited")
    func cleanExitConcludes() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        // The post-upgrade SessionEnd carries the session's ORCH_EPOCH, so the funnel kills via its
        // generation fence (a nil-epoch exit would first require a real-liveness probe — see
        // PhaseTransitionTests.test_nilEpochKillSignalRequiresProbe).
        try await env.svc.report(child.id, StatusReport(endReason: "exit"), observedEpoch: child.sessionEpoch)
        #expect(await waiting.value?.kind == .exited)
    }

    // 6 · multi fan-out conclusions coalesce in the inbox (one drain, none lost).
    @Test("N children conclude → N inbox messages that drain together in one payload")
    func fanoutCoalesces() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "orch", repo: repo, branch: "orch"))
        let a = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "A", repo: repo, branch: "a"))
        let b = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "B", repo: repo, branch: "b"))
        let c = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "C", repo: repo, branch: "c"))
        await env.svc.registerWatch(parent.id, [a.id, b.id, c.id])

        // Conclude all three while the parent is mid-turn (no active wait).
        try await env.svc.archive(a.id)
        try await env.svc.archive(b.id)
        try await env.svc.archive(c.id)

        let inbox = await env.svc.inbox
        #expect(await inbox.peek(parent.id).count == 3)          // none lost
        let epoch = try #require(await env.svc.store.get(parent.id)).sessionEpoch
        let payload = try #require(await env.svc.payloadForStop(parent.id, observedEpoch: epoch, stopHookActive: false))
        #expect(payload.contains(a.shortId))                     // all three drain together
        #expect(payload.contains(b.shortId))
        #expect(payload.contains(c.shortId))
        // Claim-then-confirm: all three ride ONE claim (delivered together) and are now LEASED — not
        // removed — until the continuation's own Stop confirms them.
        let leased = await inbox.peek(parent.id)
        #expect(leased.count == 3)
        #expect(leased.allSatisfy { $0.lease?.route == .stopDrain })
        _ = await env.svc.payloadForStop(parent.id, observedEpoch: epoch, stopHookActive: true)
        #expect(await inbox.peek(parent.id).isEmpty)             // the continuation's Stop confirms the batch
    }

    // extra · the `wait` command is registered (MCP parity) and round-trips a conclusion.
    @Test("the `wait` command is registered and round-trips a conclusion")
    func waitCommandRoundtrips() async throws {
        #expect(CommandRegistry().command("wait") != nil)
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let cmd = try #require(CommandRegistry().command("wait"))
        let waiting = _Concurrency.Task {
            try await cmd.run(env.svc, .object(["refs": .array([.string(child.id.uuidString)])]), .agent)
        }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        try await env.svc.archive(child.id)
        let result = try await waiting.value
        #expect(result["cardId"]?.stringValue?.lowercased() == child.id.uuidString.lowercased())
        #expect(result["kind"]?.stringValue == "done")
    }

    @Test("CLI wait process output is the conclusion notice, so it does not also enqueue one")
    func cliWaitDoesNotDuplicateConclusionIntoInbox() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        try await env.svc.archive(child.id)

        #expect(await waiting.value?.cardId == child.id)
        #expect(try await env.svc.inboxPeek(parent.id).isEmpty)
    }

    @Test("MCP wait registers a watcher and returns immediately for Claude")
    func mcpWaitRegistersAndReturnsImmediately() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let cmd = try #require(CommandRegistry().command("wait"))

        let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await cmd.run(env.svc, .object([
                    "refs": .array([.string(child.id.uuidString)]),
                    "watcher": .string(parent.id.uuidString),
                ]), .mcp)
            }
            group.addTask {
                // yield-based failure backstop: fires only if `wait` wrongly PARKS on the child's
                // conclusion instead of registering-and-returning (the child never concludes here)
                try await pollUntil("MCP wait returns without parking", timeout: .seconds(60)) { false }
                throw OrchestraError.invalidParams("MCP wait did not return immediately")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        #expect(result["watching"]?.boolValue == true)
        #expect(await env.svc.activeWaitSubscriptionCount() == 0)
        try await env.svc.archive(child.id)
        #expect(try await env.svc.inboxPeek(parent.id).contains { $0.text.contains(child.shortId) })
    }

    @Test("MCP watch wakes an idle Claude watcher because no wait process will re-invoke it")
    func mcpWatchWakesIdleClaudeWatcher() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: parent.agentSessionId!)
        await env.svc.testSetTurnStatus(parent.id, .waiting())
        let name = env.sessions.sessionName(parent.id)

        let cmd = try #require(CommandRegistry().command("wait"))
        let result = try await cmd.run(env.svc, .object([
            "refs": .array([.string(child.id.uuidString)]),
            "watcher": .string(parent.id.uuidString),
        ]), .mcp)
        #expect(result["watching"]?.boolValue == true)

        // Archiving the child concludes it (at intent) → fan-out wakes the idle parent (resume-seed →
        // `.relaunching`); the reconciler then drives that relaunch to deliver the seed.
        try await env.svc.archive(child.id)
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[name]?.contains("--resume") == true
        }
        let seed = try #require(env.sessions.ensureArgv[name]?.last)
        #expect(seed.contains(child.shortId))
        let epoch = try #require(await env.svc.store.get(parent.id)).sessionEpoch   // current post-relaunch epoch
        #expect(await env.svc.payloadForStop(parent.id, observedEpoch: epoch, stopHookActive: false) == nil)
    }

    @Test("legacy Codex task_complete neither closes the turn nor concludes a delegated child")
    func codexTaskCompleteDoesNotCloseTurnOrConcludeChild() async throws {
        let base = NSTemporaryDirectory() + "orch-codex-complete-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/cwd", withIntermediateDirectories: true)
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: base + "/codexhome")
        let env = TestEnv.make(registry: AgentRegistry(adapters: [codex]))
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p", agentId: "codex"))
        let child = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(),
            prompt: "what is 2+2",
            agentId: "codex",
            cwd: base + "/cwd",
            access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        #expect(codex.parse(.fileTail(line: #"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#)) == nil)
        await yieldBriefly()   // negative: a wrongful conclusion (awaited inside report) gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)   // NOT concluded — wait still pending
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.turnStatus == .running)                      // app-server turn/completed is authoritative
        #expect(after.archived == false)
        waiting.cancel(); _ = await waiting.value
    }

    @Test("Claude TaskCompleted neither closes the turn nor concludes a delegated child")
    func claudeTaskCompletedDoesNotCloseTurnOrConcludeChild() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let repo = TestEnv.repo(env.base)
        let cwd = env.base + "/borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let parent = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "summarize", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        #expect(ClaudeCodeAdapter().parse(.hooksPush(kind: "taskcompleted", payload: .object([:]))) == nil)
        await yieldBriefly()   // negative: a wrongful conclusion (awaited inside report) gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)   // NOT concluded — wait still pending
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.turnStatus == .running)                      // only a top-level turn end closes the turn
        #expect(after.archived == false)
        waiting.cancel(); _ = await waiting.value
    }

    @Test("Claude stop still waits for the human and does not conclude")
    func claudeStopDoesNotConclude() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let cwd = env.base + "/borrowed-stop"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let child = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "ask if unclear", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let epoch = try #require(await env.svc.store.get(child.id)).sessionEpoch
        await env.svc.receiveAgentSignals(
            cardId: child.id,
            signals: [.init(sessionEpoch: epoch, kind: .turnCompleted())]
        )
        await yieldBriefly()   // negative: a wrongful conclusion (awaited inside report) gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.workInFlight == false)
        #expect(after.turnStatus == .waiting())
        waiting.cancel(); _ = await waiting.value
    }

    @Test("provider-neutral turn completion leaves a watched read-only delegated child idle — success is not a conclusion")
    func genericTurnCompletionDoesNotConcludeReadOnlyDelegatedChild() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let cwd = env.base + "/generic-borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "p"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "answer briefly", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let epoch = try #require(await env.svc.store.get(child.id)).sessionEpoch
        await env.svc.receiveAgentSignals(
            cardId: child.id,
            signals: [.init(sessionEpoch: epoch, kind: .turnCompleted())]
        )
        await yieldBriefly()   // negative: a wrongful conclusion (awaited inside report) gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)   // NOT concluded — wait still pending
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.turnStatus == .waiting())                     // idles, success is agent-signalled (send)
        #expect(after.archived == false)
        waiting.cancel(); _ = await waiting.value
    }

    @Test("ordinary worktree turn completion still waits for the human and does not conclude")
    func worktreeTurnCompletionDoesNotConclude() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let epoch = try #require(await env.svc.store.get(child.id)).sessionEpoch
        await env.svc.receiveAgentSignals(
            cardId: child.id,
            signals: [.init(sessionEpoch: epoch, kind: .turnCompleted())]
        )
        await yieldBriefly()   // negative: a wrongful conclusion gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.workInFlight == false)
        #expect(after.turnStatus == .waiting())
        waiting.cancel(); _ = await waiting.value
    }

    @Test("idle notification is not a turn edge and does not conclude")
    func idleNotificationDoesNotCloseTurn() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let cwd = env.base + "/borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let child = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "summarize", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let report = try #require(ClaudeCodeAdapter().parse(.hooksPush(
            kind: "notification",
            payload: try JSONValue.parse(Data(#"{"notification_type":"idle_prompt","message":"done"}"#.utf8)))))
        try await env.svc.report(child.id, report)   // legacy report fields cannot change AgentState
        await yieldBriefly()   // negative: a wrongful conclusion gets its chance to land

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.workInFlight == true)
        #expect(after.turnStatus == .running)
        waiting.cancel(); _ = await waiting.value
    }

    // extra · wait short-circuits on an already-concluded child (re-issue race).
    @Test("wait returns immediately if a watched child already concluded")
    func alreadyConcluded() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        try await env.svc.archive(child.id)                      // concludes before any wait
        let conc = await env.svc.wait(watcher: nil, refs: [child.id])
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
    }
}
