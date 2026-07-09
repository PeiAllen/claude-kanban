import Foundation
import Testing
@testable import OrchestraCore

@Suite("C2 · wake + merge-watch (real card state; subscriber; settled-terminal)")
struct WakeMergeWatchTests {

    // 1 · conclusion from real card state (archive → Done), driven off the lifecycle event.
    @Test("archive (move to Done) concludes a watched child")
    func concludesOnArchive() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "ancestor"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        #expect(await env.svc.activeWaitSubscriptionCount() == 1)   // still subscribed — real state, not git
        waiting.cancel(); _ = await waiting.value
    }

    // 3 · cancel.
    @Test("wait returns nil when cancelled")
    func waitCancels() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
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
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let parent = try await env.svc.spawn(SpawnInput(prompt: "orch", repo: repo, branch: "orch"))
        let a = try await env.svc.spawn(SpawnInput(prompt: "A", repo: repo, branch: "a"))
        let b = try await env.svc.spawn(SpawnInput(prompt: "B", repo: repo, branch: "b"))
        let c = try await env.svc.spawn(SpawnInput(prompt: "C", repo: repo, branch: "c"))
        await env.svc.registerWatch(parent.id, [a.id, b.id, c.id])

        // Conclude all three while the parent is mid-turn (no active wait).
        try await env.svc.archive(a.id)
        try await env.svc.archive(b.id)
        try await env.svc.archive(c.id)

        let inbox = await env.svc.inbox
        #expect(await inbox.peek(parent.id).count == 3)          // none lost
        let payload = try #require(await env.svc.drainForStop(parent.id))
        #expect(payload.contains(a.shortId))                     // all three drain together
        #expect(payload.contains(b.shortId))
        #expect(payload.contains(c.shortId))
        #expect(await inbox.peek(parent.id).isEmpty)             // one drain cleared them
    }

    // extra · the `wait` command is registered (MCP parity) and round-trips a conclusion.
    @Test("the `wait` command is registered and round-trips a conclusion")
    func waitCommandRoundtrips() async throws {
        #expect(CommandRegistry().command("wait") != nil)
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
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
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let cmd = try #require(CommandRegistry().command("wait"))

        let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await cmd.run(env.svc, .object([
                    "refs": .array([.string(child.id.uuidString)]),
                    "watcher": .string(parent.id.uuidString),
                ]), .mcp)
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: .milliseconds(120))
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
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: parent.agentSessionId!)
        try await env.svc.report(parent.id, StatusReport(run: .waiting(.humanTurn)))
        let name = env.sessions.sessionName(parent.id)

        let cmd = try #require(CommandRegistry().command("wait"))
        let result = try await cmd.run(env.svc, .object([
            "refs": .array([.string(child.id.uuidString)]),
            "watcher": .string(parent.id.uuidString),
        ]), .mcp)
        #expect(result["watching"]?.boolValue == true)

        try await env.svc.archive(child.id)
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        let seed = try #require(env.sessions.ensureArgv[name]?.last)
        #expect(seed.contains(child.shortId))
        #expect(await env.svc.drainForStop(parent.id) == nil)
    }

    @Test("Codex task_complete concludes a watched read-only delegated child without archiving it")
    func codexTaskCompleteConcludesReadOnlyDelegatedChild() async throws {
        let base = NSTemporaryDirectory() + "orch-codex-complete-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/cwd", withIntermediateDirectories: true)
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: base + "/codexhome")
        let env = TestEnv.make(registry: AgentRegistry(adapters: [codex]))
        let repo = TestEnv.repo(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p", agentId: "codex"))
        let child = try await env.svc.spawn(SpawnInput(
            prompt: "what is 2+2",
            agentId: "codex",
            cwd: base + "/cwd",
            access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let report = try #require(codex.parse(.fileTail(line: #"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#)))
        try await env.svc.report(child.id, report)

        let conc = await waiting.value
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.phase == .dead(.completed))
        #expect(after.archived == false)
    }

    @Test("Claude TaskCompleted concludes a watched read-only delegated child without archiving it")
    func claudeTaskCompletedConcludesReadOnlyDelegatedChild() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let repo = TestEnv.repo(env.base)
        let cwd = env.base + "/borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "summarize", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let report = try #require(ClaudeCodeAdapter().parse(.hooksPush(kind: "taskcompleted", payload: .object([:]))))
        try await env.svc.report(child.id, report)

        let conc = await waiting.value
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.phase == .dead(.completed))
        #expect(after.archived == false)
    }

    @Test("Claude stop still waits for the human and does not conclude")
    func claudeStopDoesNotConclude() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let cwd = env.base + "/borrowed-stop"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let child = try await env.svc.spawn(SpawnInput(prompt: "ask if unclear", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let report = try #require(ClaudeCodeAdapter().parse(.hooksPush(kind: "stop", payload: .object([:]))))
        try await env.svc.report(child.id, report)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.waitReason != nil)
        #expect(after.waitReason == .humanTurn)
        waiting.cancel(); _ = await waiting.value
    }

    @Test("provider-neutral turn completion concludes a watched read-only delegated child")
    func genericTurnCompletionConcludesReadOnlyDelegatedChild() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let cwd = env.base + "/generic-borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "answer briefly", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        try await env.svc.report(child.id, StatusReport(run: .waiting(.humanTurn), turnCompleted: true))

        let conc = await waiting.value
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.phase == .dead(.completed))
        #expect(after.archived == false)
    }

    @Test("ordinary worktree turn completion still waits for the human and does not conclude")
    func worktreeTurnCompletionDoesNotConclude() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        try await env.svc.report(child.id, StatusReport(run: .waiting(.humanTurn), turnCompleted: true))
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.waitReason != nil)
        #expect(after.waitReason == .humanTurn)
        waiting.cancel(); _ = await waiting.value
    }

    @Test("idle notification still waits for the human and does not conclude")
    func idleNotificationDoesNotConclude() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(binOverride: "fake-claude")]))
        let cwd = env.base + "/borrowed"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let child = try await env.svc.spawn(SpawnInput(prompt: "summarize", cwd: cwd, access: .readOnly))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }

        let report = try #require(ClaudeCodeAdapter().parse(.hooksPush(
            kind: "notification",
            payload: try JSONValue.parse(Data(#"{"notification_type":"idle_prompt","message":"done"}"#.utf8)))))
        try await env.svc.report(child.id, report)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(await env.svc.activeWaitSubscriptionCount() == 1)
        let after = try #require(await env.svc.list().first { $0.id == child.id })
        #expect(after.waitReason != nil)
        #expect(after.waitReason == .humanTurn)
        waiting.cancel(); _ = await waiting.value
    }

    // extra · wait short-circuits on an already-concluded child (re-issue race).
    @Test("wait returns immediately if a watched child already concluded")
    func alreadyConcluded() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        try await env.svc.archive(child.id)                      // concludes before any wait
        let conc = await env.svc.wait(watcher: nil, refs: [child.id])
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
    }
}
