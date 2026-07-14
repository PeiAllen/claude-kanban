import Foundation
import Testing
@testable import OrchestraCore

/// A card the user drags / keyboard-carries on the board (`source: .app`) is told it moved via an inbox
/// message; a card moving ITSELF (`.cli` / `.mcp` / `.agent`), or a no-op drop back into its own column,
/// is not. All cases use a `.running` card so `send`'s wake defers (no relaunch) and the notification
/// simply stays durable in the inbox, where `inboxPeek` can assert on it deterministically.
@Suite("move · a UI move notifies the card, a self-move does not")
struct MoveNotifyTests {

    /// A running card spawned into `.plan` (the default `startIn`), the state a board move acts on.
    private func running(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))   // .running, .plan
        env.adapter.writeTranscript(for: t.agentSessionId!)                                     // resumable
        return t
    }

    @Test("a UI move (.app) queues a from→to notification onto the card")
    func appMoveNotifies() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await running(env, branch: "b")

        _ = try await env.svc.move(card.id, to: .review, source: .app)

        #expect(try await env.svc.inboxPeek(card.id).map(\.text)
            == ["You were moved from Plan to Review by the user (via the board UI)."])
    }

    @Test("a self-move (.mcp / .cli / .agent) notifies nothing")
    func selfMoveDoesNotNotify() async throws {
        for src in [ActivitySource.mcp, .cli, .agent] {
            let env = TestEnv.make(grace: 2)
            let card = try await running(env, branch: "b")

            _ = try await env.svc.move(card.id, to: .review, source: src)

            #expect(try await env.svc.inboxPeek(card.id).isEmpty, "\(src) move must not notify")
        }
    }

    @Test("a no-op UI move (dropped back into its own column) notifies nothing")
    func noOpAppMoveDoesNotNotify() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await running(env, branch: "b")       // already in .plan

        _ = try await env.svc.move(card.id, to: .plan, source: .app)

        #expect(try await env.svc.inboxPeek(card.id).isEmpty)
    }
}
