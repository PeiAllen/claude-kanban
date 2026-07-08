import Foundation
import Testing
@testable import OrchestraCore

@Suite("Agent-terminal ownership ⇄ ControlServer — the acceptance harness", .serialized)
struct TerminalOwnershipRoundTripTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    /// Isolated harness: a hermetic ControlServer+ControlClient over a throwaway UDS socket.
    @Test("available → desktop → phone → desktop; stale release rejected; owner events reach subscribers")
    func acceptance() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Shrink the heartbeat window so the disconnect-staleness assertion doesn't sleep 30s.
        await env.svc.setOwnershipHeartbeatTimeout(0.2)

        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        // Two clients: "desktop" and "phone".
        let desktop = ControlClient(socketPath: path, source: .app)
        try desktop.connect(); defer { desktop.close() }
        let phone = ControlClient(socketPath: path, source: .app)
        try phone.connect(); defer { phone.close() }

        // Subscribe on the desktop to observe owner events.
        let box = EventBox()
        let stream = desktop.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))

        let task = try await desktop.call("spawn", .object([
            "prompt": .string("own me"), "repo": .string(repo), "branch": .string("feat")]))
            .decode(Task.self)
        let ref = task.shortId

        // available
        #expect(try await desktop.agentTerminalOwner(ref).owner == nil)

        // desktop takeover (epoch 1)
        let d = try await desktop.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(d.state.epoch == 1)
        #expect(d.target.kind == .agent)

        // phone takeover (epoch 2)
        let p = try await phone.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(p.state.owner?.ownerKind == .phone)
        #expect(p.state.epoch == 2)

        // desktop retake (epoch 3)
        let r = try await desktop.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(r.state.epoch == 3)
        #expect(r.state.owner?.ownerKind == .desktop)

        // a stale-epoch release (phone's old epoch 2) is REJECTED
        await #expect(throws: (any Error).self) {
            _ = try await phone.releaseAgentTerminal(ref, clientId: "phone", epoch: p.state.epoch)
        }
        #expect(try await desktop.agentTerminalOwner(ref).owner?.ownerKind == .desktop)

        // owner events reached the subscriber (≥ 3 takeovers)
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        let owners = await box.events.compactMap {
            if case .agentTerminalOwner(let s) = $0 { return s } else { return nil }
        }
        #expect(owners.filter { $0.cardId == task.id }.count >= 3)
    }

    @Test("a phone that stops heartbeating goes stale after the window (disconnect staleness)")
    func staleAfterDisconnect() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        await env.svc.setOwnershipHeartbeatTimeout(0.2)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let phone = ControlClient(socketPath: path, source: .app)
        try phone.connect(); defer { phone.close() }

        let task = try await phone.call("spawn", .object([
            "prompt": .string("x"), "repo": .string(repo), "branch": .string("b")])).decode(Task.self)
        let ref = task.shortId

        _ = try await phone.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(try await phone.agentTerminalOwner(ref).stale == false)   // fresh right after
        try await _Concurrency.Task.sleep(for: .milliseconds(300))        // let the 0.2s window lapse
        let after = try await phone.agentTerminalOwner(ref)
        #expect(after.stale == true)              // stale — but still the phone owner
        #expect(after.owner?.ownerKind == .phone)
    }
}
