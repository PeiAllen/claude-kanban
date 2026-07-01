import Foundation
import Testing
@testable import OrchestraCore

@Suite("C4 · Codex send-keys wake (nudge-only; detect-and-defer)")
struct CodexWakeTests {

    /// A Claude-shaped capability tuple with the send-keys wake transport, so `wake` routes through the
    /// C4 case without dragging in Codex's discovered-session / file-tail launch behavior.
    static let sendKeysCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .sendKeys, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription)

    // Idle + empty composer → the fixed nudge is sent exactly once.
    @Test("wake nudges when the card is idle and the composer is empty")
    func nudgesWhenIdleAndEmpty() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Done.\n\n›\n")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id) == [OrchestraService.sendKeysWakeNudge])
    }

    // A user draft in the composer → defer (no keystroke).
    @Test("wake defers (no nudge) when the composer holds a draft")
    func defersOnDraft() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Done.\n\n› half-written question")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // A turn is streaming → defer even though the composer is empty (idle is a gate; focus is not).
    @Test("wake defers when a turn is in flight (not idle)")
    func defersWhenBusy() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Thinking… (Esc to interrupt)\n\n›\n")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // An unreadable pane (capture empty / no composer marker) → conservative defer.
    @Test("wake defers when the pane can't be parsed")
    func defersWhenPaneUnreadable() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        // No setCapture → StubSessions.capture returns "".

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // NUDGE-ONLY: inbox content is NEVER delivered via keystroke — only the fixed nudge is sent.
    @Test("the nudge carries no inbox content (content rides F3, not keys)")
    func nudgeCarriesNoContent() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let marker = "SECRET-INBOX-PAYLOAD-ac91"
        try await env.svc.send(card.id, marker)          // durable inbox content (F3), not a keystroke
        env.sessions.setCapture(card.id, "● Done.\n\n›\n")

        await env.svc.wake(card.id)

        let sent = env.sessions.keysSent(to: card.id)
        #expect(sent == [OrchestraService.sendKeysWakeNudge])
        #expect(sent.allSatisfy { !$0.contains(marker) })   // content did NOT ride the keystroke
    }
}
