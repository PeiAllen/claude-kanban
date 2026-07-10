import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — agent-terminal ownership", .serialized)
struct TerminalOwnershipServiceTests {

    @Test("drives available → desktop → phone → desktop and emits an owner event each takeOver")
    func driveAndEmit() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let task = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "own me", repo: repo, branch: "feat"), source: .app)
        let ref = task.shortId

        // available
        #expect(try await env.svc.agentTerminalOwner(ref).owner == nil)

        // desktop takeover → epoch 1, returns an attach target for the agent window
        let d = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(d.state.owner?.ownerKind == .desktop)
        #expect(d.state.epoch == 1)
        #expect(d.target.kind == .agent)

        // phone takeover → epoch 2
        let p = try await env.svc.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(p.state.owner?.ownerKind == .phone)
        #expect(p.state.epoch == 2)

        // desktop retake → epoch 3
        let r = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(r.state.epoch == 3)

        // three ownership events reached subscribers
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        let owns = await collector.ownerStates
        #expect(owns.filter { $0.cardId == task.id }.count >= 3)
        #expect(owns.last?.owner?.ownerKind == .desktop)
    }

    @Test("a takeover whose agent window is dead throws WITHOUT stealing the lease (#1 commit-last)")
    func failedTakeoverDoesNotStealLease() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "x", repo: repo, branch: "b"), source: .app)
        let ref = task.shortId

        // The phone legitimately owns it first (epoch 1).
        let held = try await env.svc.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(held.state.epoch == 1)

        // The card's agent window dies — the session is gone, so the next takeover can't resolve an attach
        // target (`agentTarget` throws). Before the commit-order fix that throw came AFTER the CAS + emit,
        // stealing a lease nobody could hold and stranding the desktop on the placeholder.
        try env.sessions.kill(env.sessions.sessionName(task.id))

        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        }

        // The failed takeover committed nothing: the phone still holds it at epoch 1 — no stolen lease,
        // no phantom epoch bump.
        let after = try await env.svc.agentTerminalOwner(ref)
        #expect(after.owner?.clientId == "phone")
        #expect(after.owner?.ownerKind == .phone)
        #expect(after.epoch == 1)
    }

    @Test("a denied heartbeat returns the CURRENT owner snapshot instead of throwing (#3)")
    func deniedHeartbeatReturnsSnapshot() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "x", repo: repo, branch: "b"), source: .app)
        let ref = task.shortId

        // Phone takes over at epoch 1, then the desktop retakes at epoch 2.
        let phone = try await env.svc.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        _ = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)

        // The phone heartbeats at its now-stale epoch 1. The store's CAS denies it — but the daemon returns
        // the LIVE owner (desktop) rather than throwing, so the phone mirror corrects to "lost" instead of
        // `try?`-swallowing the throw and sitting on a stale ".holding" ("You have control").
        let reply = try await env.svc.heartbeatAgentTerminal(ref, clientId: "phone", epoch: phone.state.epoch)
        #expect(reply.owner?.ownerKind == .desktop)
        #expect(reply.owner?.clientId == "desk")
        #expect(reply.epoch == 2)
    }

    @Test("a steady heartbeat re-broadcasts nothing when the owner is unchanged (#4 skip-if-unchanged)")
    func heartbeatSkipsUnchangedEmit() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "x", repo: repo, branch: "b"), source: .app)
        let ref = task.shortId

        let p = try await env.svc.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        let before = await collector.ownerStates.filter { $0.cardId == task.id }.count

        // Several healthy beats at the held epoch — owner/epoch/staleness all unchanged, so the emit is
        // suppressed (no whole-board re-render every 10s), yet each beat still returns the fresh state.
        for _ in 0..<3 {
            let r = try await env.svc.heartbeatAgentTerminal(ref, clientId: "phone", epoch: p.state.epoch)
            #expect(r.owner?.ownerKind == .phone)
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        let after = await collector.ownerStates.filter { $0.cardId == task.id }.count
        #expect(after == before)
    }

    @Test("a stale-epoch release is rejected and leaves the fresh owner intact")
    func staleReleaseRejected() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "x", repo: repo, branch: "b"), source: .app)
        let ref = task.shortId
        let a = try await env.svc.takeOverAgentTerminal(ref, clientId: "phoneA", kind: .phone)
        _ = try await env.svc.takeOverAgentTerminal(ref, clientId: "phoneB", kind: .phone)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.releaseAgentTerminal(ref, clientId: "phoneA", epoch: a.state.epoch)
        }
        #expect(try await env.svc.agentTerminalOwner(ref).owner?.clientId == "phoneB")
    }
}
