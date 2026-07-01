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
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
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
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        #expect(await env.svc.mergeWaiterCount() == 1)   // still blocked — real state, not git
        waiting.cancel(); _ = await waiting.value
    }

    // 3 · cancel.
    @Test("wait returns nil when cancelled")
    func waitCancels() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
    }

    // 4 · subscriber, not git-poll: resolution is driven by the service marking terminal (archive),
    //     and wait blocks until THEN even though nothing about git changed.
    @Test("watcher resolves only off the service's terminal transition, not any git state")
    func resolvesOffLifecycleEvent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(await env.svc.mergeWaiterCount() == 1)          // no premature resolve
        try await env.svc.archive(child.id)                    // the single authority marks terminal
        #expect(await waiting.value?.cardId == child.id)       // now it resolves
    }

    // 5 · transient crash + revive (settled-terminal only).
    @Test("a crash (sessionVanished) that is revived does NOT conclude")
    func crashRevivedNotConcluded() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: child.agentSessionId!)
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }

        env.sessions.setAlive(child.id, false)
        await env.svc.reconcileLiveness()                      // → .dead sessionVanished (NOT a conclusion)
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        #expect(await env.svc.mergeWaiterCount() == 1)         // crash alone did not conclude

        // Revive it.
        async let resumed = env.svc.resume(child.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        try await env.svc.report(child.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        #expect(await env.svc.mergeWaiterCount() == 1)         // revived → still not concluded
        waiting.cancel(); _ = await waiting.value
    }

    // 5b · a CLEAN agent exit IS a settled conclusion (.exited).
    @Test("a clean agent exit (SessionEnd exit) concludes with .exited")
    func cleanExitConcludes() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await env.svc.report(child.id, StatusReport(endReason: "exit"))
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
