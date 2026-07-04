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

        let task = try await env.svc.spawn(
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

    @Test("a stale-epoch release is rejected and leaves the fresh owner intact")
    func staleReleaseRejected() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(
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
