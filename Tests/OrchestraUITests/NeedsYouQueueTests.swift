import XCTest
import OrchestraKit
@testable import OrchestraUI

/// The Needs You attention queue (mobile design §6): reason derivation, background-wait exclusion,
/// urgency sort, and the send-keys gate chords. Pure logic — no daemon, no iOS Simulator.
final class NeedsYouQueueTests: XCTestCase {

    private func card(_ title: String,
                      status: AgentStatus,
                      wait: WaitReason? = nil,
                      dead: DeadReason? = nil,
                      ctx: Double = 0,
                      archived: Bool = false,
                      updatedAt: Date = Date()) -> Task {
        Task(title: title, repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
             status: status, deadReason: dead, waitReason: wait, ctxPct: ctx,
             initialPrompt: title, archived: archived, updatedAt: updatedAt)
    }

    // MARK: reason derivation

    func testReasonMapsEachDaemonSignal() {
        XCTAssertEqual(NeedsYouQueue.reason(for: card("p", status: .waiting, wait: .permission)), .permission)
        XCTAssertEqual(NeedsYouQueue.reason(for: card("h", status: .waiting, wait: .humanTurn)), .humanTurn)
        XCTAssertEqual(NeedsYouQueue.reason(for: card("d", status: .dead, dead: .agentExited)), .died)
        XCTAssertEqual(NeedsYouQueue.reason(for: card("c", status: .running, ctx: 92)), .contextFull)
    }

    func testRunningCardWithNoSignalNeedsNothing() {
        // A plain running card (the common case, incl. background-waits which stay .running) never surfaces.
        XCTAssertNil(NeedsYouQueue.reason(for: card("r", status: .running)))
        XCTAssertNil(NeedsYouQueue.reason(for: card("r", status: .running, ctx: 40)))
    }

    func testDoneCardIsNeverDraggedInByStaleContext() {
        // Context-full is gated to live (running/waiting) cards — a finished card isn't "needing you".
        XCTAssertNil(NeedsYouQueue.reason(for: card("done", status: .done, ctx: 99)))
    }

    func testPermissionOutranksContextWhenBoth() {
        // A waiting-on-permission card that is also near-full surfaces for the stronger reason.
        let t = card("both", status: .waiting, wait: .permission, ctx: 99)
        XCTAssertEqual(NeedsYouQueue.reason(for: t), .permission)
    }

    func testContextThresholdBoundary() {
        XCTAssertNil(NeedsYouQueue.reason(for: card("just-under", status: .running, ctx: 84)))
        XCTAssertEqual(NeedsYouQueue.reason(for: card("at", status: .running, ctx: 85)), .contextFull)
    }

    // MARK: build — filtering + sort

    func testArchivedCardsAreExcluded() {
        let t = card("archived-dead", status: .dead, dead: .agentExited, archived: true)
        XCTAssertTrue(NeedsYouQueue.build(from: [t]).isEmpty)
    }

    func testBackgroundWaitCardNeverAppears() {
        // A card paused on a background task is reported .running by the adapters, so it is simply a
        // running card here — excluded. (The exclusion is by construction, not a special case.)
        let bg = card("bg-loop", status: .running)
        let real = card("blocked", status: .waiting, wait: .permission)
        let q = NeedsYouQueue.build(from: [bg, real])
        XCTAssertEqual(q.map(\.task.title), ["blocked"])
    }

    func testSortIsMostUrgentFirstThenLongestWaiting() {
        let now = Date()
        let old = now.addingTimeInterval(-600)   // waiting longer
        let new = now.addingTimeInterval(-60)
        let perm   = card("perm",    status: .waiting, wait: .permission, updatedAt: new)
        let died   = card("died",    status: .dead,    dead: .agentExited, updatedAt: new)
        let humanA = card("human-old", status: .waiting, wait: .humanTurn, updatedAt: old)
        let humanB = card("human-new", status: .waiting, wait: .humanTurn, updatedAt: new)
        let ctx    = card("ctx",     status: .running, ctx: 95, updatedAt: new)

        let order = NeedsYouQueue.build(from: [ctx, humanB, humanA, died, perm]).map(\.task.title)
        // permission > died > humanTurn (oldest-first within reason) > context
        XCTAssertEqual(order, ["perm", "died", "human-old", "human-new", "ctx"])
    }

    // MARK: gate chords — now agent-capability facts, not neutral-layer constants (#4)

    func testGateChordsLiveOnAgentCapabilities() {
        // The Claude TUI layout: Enter accepts the pre-highlighted "Yes", Esc cancels. These moved OFF
        // the provider-neutral NeedsYouQueue ONTO the capability so each adapter states its own gate keys.
        XCTAssertEqual(AgentCapabilities.claudeCode.approveChord, [.named(.enter)])
        XCTAssertEqual(AgentCapabilities.claudeCode.denyChord, [.named(.esc)])
    }

    // MARK: permission gate — state guard + per-adapter chord routing (#4)

    @MainActor
    private func modelWith(_ tasks: [Task], agents: [AgentInfo] = []) -> BoardModel {
        let m = BoardModel(platform: .noop)
        m.tasks = tasks
        m.agents = agents
        return m
    }

    @MainActor
    func testGateFiresOnlyWhileWaitingOnPermission() {
        // Only a card STILL blocked on a permission prompt yields a chord; anything else is a no-op so an
        // approve/deny keystroke can't land in a now-live REPL and submit the composer.
        let perm = card("perm", status: .waiting, wait: .permission)
        let humanTurn = card("human", status: .waiting, wait: .humanTurn)
        let running = card("run", status: .running)
        let dead = card("dead", status: .dead, dead: .agentExited)
        let m = modelWith([perm, humanTurn, running, dead])

        XCTAssertEqual(m.permissionGateChord(perm.id, \.approveChord), [.named(.enter)])
        XCTAssertEqual(m.permissionGateChord(perm.id, \.denyChord), [.named(.esc)])
        XCTAssertNil(m.permissionGateChord(humanTurn.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(running.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(dead.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(UUID(), \.approveChord))   // unknown card
    }

    @MainActor
    func testGateChordComesFromTheCardsAgentCapability() {
        // Prove the chord is routed per-adapter: a card whose agent advertises a DIFFERENT chord uses it,
        // not a hardcoded Enter/Esc. (An empty chord means "no send-keys gate" → no-op.)
        let tabCaps = AgentCapabilities(
            sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
            wakeTransport: .nativeReinvoke, inboxDrain: .stopHook, readOnlyEnforcement: .sandboxed,
            authMode: .subscription, approveChord: [.named(.tab)], denyChord: [])
        let agent = AgentInfo(id: "tabber", name: "Tabber", icon: "sparkle",
                              models: [AgentModel(id: "m")], capabilities: tabCaps)
        var t = card("perm", status: .waiting, wait: .permission)
        t.agentId = "tabber"
        let m = modelWith([t], agents: [agent])

        XCTAssertEqual(m.permissionGateChord(t.id, \.approveChord), [.named(.tab)])
        XCTAssertNil(m.permissionGateChord(t.id, \.denyChord))   // empty chord → no send-keys gate
    }
}
