import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Agent-terminal ownership ⇄ ControlServer — the acceptance harness", .serialized)
struct TerminalOwnershipRoundTripTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    /// Isolated harness: a hermetic ControlServer+ControlClient over a throwaway UDS socket.
    @Test("available → desktop → phone → desktop; stale release rejected; owner events reach subscribers")
    func acceptance() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Shrink the heartbeat window so the disconnect-staleness assertion doesn't sleep 30s.
        // Start with a window the test cannot outlive, so the "fresh right after" assertion is
        // deterministic at any machine speed; the flip phase SHRINKS the window instead of waiting
        // for wall-clock to cross a 0.2s budget (heartbeatTimeout is read live per computation).
        await env.svc.setOwnershipHeartbeatTimeout(3600)

        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        // Two clients: "desktop" and "phone".
        let desktop = TestEnv.controlClient(path, source: .app)
        try desktop.connect(); defer { desktop.close() }
        let phone = TestEnv.controlClient(path, source: .app)
        try phone.connect(); defer { phone.close() }

        // Subscribe on the desktop to observe owner events. `subscribeWithRev` does NOT auto-issue
        // the RPC, so the awaited `call("subscribe")` is a registration BARRIER — no fixed sleep.
        let box = EventBox()
        let stream = desktop.subscribeWithRev()
        _Concurrency.Task { for await e in stream { await box.add(e.event) } }
        _ = try await desktop.call("subscribe")

        let task = try await desktop.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("own me"), "repo": .string(repo), "branch": .string("feat")]))
            .decode(Task.self)
        let ref = task.shortId
        // Non-blocking spawn: drive the reconciler so the card is live (session up) before terminal takeover.
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == task.id }?.phase.kind == .live
        }

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

        // owner events reached the subscriber (≥ 3 takeovers) — the delivery is async, poll for it
        try await pollUntil("3 owner events delivered") {
            await box.events.compactMap {
                if case .agentTerminalOwner(let s) = $0 { return s } else { return nil }
            }.filter { $0.cardId == task.id }.count >= 3
        }
    }

    @Test("a phone that stops heartbeating goes stale after the window (disconnect staleness)")
    func staleAfterDisconnect() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Start with a window the test cannot outlive, so the "fresh right after" assertion is
        // deterministic at any machine speed; the flip phase SHRINKS the window instead of waiting
        // for wall-clock to cross a 0.2s budget (heartbeatTimeout is read live per computation).
        await env.svc.setOwnershipHeartbeatTimeout(3600)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let phone = TestEnv.controlClient(path, source: .app)
        try phone.connect(); defer { phone.close() }

        let task = try await phone.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("x"), "repo": .string(repo), "branch": .string("b")])).decode(Task.self)
        let ref = task.shortId
        // Non-blocking spawn: drive the reconciler so the card is live (session up) before terminal takeover.
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == task.id }?.phase.kind == .live
        }

        _ = try await phone.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(try await phone.agentTerminalOwner(ref).stale == false)   // fresh: window is 1h
        // Force the flip by shrinking the window below the already-elapsed time — no wall-clock race.
        await env.svc.setOwnershipHeartbeatTimeout(0.000_001)
        try await pollUntil("the heartbeat window lapses and the owner reads stale") {
            (try? await phone.agentTerminalOwner(ref))?.stale == true
        }
        let after = try await phone.agentTerminalOwner(ref)
        #expect(after.stale == true)              // stale — but still the phone owner
        #expect(after.owner?.ownerKind == .phone)
    }
}
