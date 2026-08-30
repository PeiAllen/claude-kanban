import XCTest
import OrchestraKit
@testable import OrchestraUI

/// The Needs You attention queue (BT slice 5), re-homed onto the 3b `ownAttention` fold: membership is
/// now the ONE contract (a card appears IFF a human action is required), the top signal drives the row,
/// and the send-keys gate chords are unchanged. Pure logic over a hand-built `tasks` array + an injected
/// `now` — no daemon, no iOS Simulator. (The per-reason derivation itself is covered in
/// `BoardStoreAttentionTests`/`AttentionTests`; this pins the BUILDER — filter, sort, signal passthrough.)
@MainActor
final class NeedsYouQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var T: TimeInterval { Attention.Thresholds().stallAfter }
    private var late: Date { t0.addingTimeInterval(T + 80) }

    private func card(_ title: String,
                      parentBranch: String? = nil,
                      phase: Phase = .live(.running),
                      dead: DeadReason? = nil,
                      ctx: Double = 0,
                      pendingQuestion: PendingQuestion? = nil,
                      treeStat: TreeStat? = nil,
                      archived: Bool = false,
                      at: Date? = nil) -> Task {
        Task(title: title, pendingQuestion: pendingQuestion, repo: "/repo", branch: "feat/\(title)",
             cwd: "/repo/.wt/\(title)", origin: .worktree, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .impl, column: .impl, order: 0, deadReason: dead, phase: phase,
             phaseChangedAt: at ?? t0, ctxPct: ctx, initialPrompt: title, parentBranch: parentBranch,
             treeStat: treeStat, archived: archived,
             updatedAt: at ?? t0)
    }

    @MainActor
    private func modelWith(_ tasks: [Task], agents: [AgentInfo] = []) -> BoardModel {
        let m = BoardModel(platform: .noop)
        m.tasks = tasks
        m.agents = agents
        return m
    }

    // MARK: membership — the ONE contract (ownAttention non-empty)

    func testMembershipIsOwnAttention() {
        // A plain running card holds no reason → absent. A permission-blocked card and a dead card each
        // hold one → present, top reason = that reason.
        let m = modelWith([card("run", phase: .live(.running)),
                           card("perm", phase: .live(.init(turnStatus: .running, humanNeed: .permission))),
                           card("dead", phase: .dead(.agentExited), dead: .agentExited)])
        let rows = m.needsYouRows(now: t0)
        XCTAssertEqual(Set(rows.map(\.task.title)), ["perm", "dead"])
        XCTAssertEqual(rows.first(where: { $0.task.title == "perm" })?.topReason, .humanRequired)
        XCTAssertEqual(rows.first(where: { $0.task.title == "dead" })?.topReason, .dead)
    }

    func testDetectedInputUsesHumanRequiredReason() {
        let input = AgentState(
            turnStatus: .running,
            humanNeed: .input
        )
        let rows = modelWith([card("input", phase: .live(input))]).needsYouRows(now: t0)
        XCTAssertEqual(rows.first?.topReason, .humanRequired)
        XCTAssertEqual(rows.first?.signals.map(\.label), ["input needed"])
    }

    /// The membership SHIFT this slice introduces: a bare idle `humanTurn` card no longer qualifies just
    /// for being done — it enters the queue ONLY once it goes quiescent past the stall threshold.
    func testBareIdleHumanTurnEntersOnlyOnStall() {
        let idle = card("idle", phase: .live(.waiting), at: t0)
        let m = modelWith([idle])
        XCTAssertTrue(m.needsYouRows(now: t0).isEmpty, "a fresh idle card must not be in the queue")
        let late = m.needsYouRows(now: late)
        XCTAssertEqual(late.map(\.task.title), ["idle"])
        XCTAssertEqual(late.first?.topReason, .stalled, "it enters only via the stall net")
    }

    func testArchivedExcluded() {
        let m = modelWith([card("archived-dead", phase: .dead(.agentExited), dead: .agentExited, archived: true)])
        XCTAssertTrue(m.needsYouRows(now: t0).isEmpty)
    }

    func testBackgroundWaitCardNeverAppears() {
        // A card paused on provider-owned background work has no open turn but will resume automatically,
        // so it must not enter the stall queue even after the ordinary-wait threshold passes.
        let autoResume = AgentState(turnStatus: .waiting(.init(resume: .init())))
        let m = modelWith([card("bg-loop", phase: .live(autoResume)),
                           card("blocked", phase: .live(.init(turnStatus: .running, humanNeed: .permission)))])
        XCTAssertEqual(m.needsYouRows(now: late).map(\.task.title), ["blocked"])
    }

    // MARK: signals — labels + the multi-reason row

    func testSignalsCarryTheirLabels() {
        let m = modelWith([card("perm", phase: .live(.init(turnStatus: .running, humanNeed: .permission)))])
        let row = m.needsYouRows(now: t0).first
        XCTAssertEqual(row?.signals.map(\.label), ["permission"])
    }

    func testMultiSignalRowTopReasonDrivesIt() {
        // A card blocked on permission AND nearly out of context holds BOTH reasons; the row lists both,
        // and the top (most hard-blocked) is permission.
        let m = modelWith([card("both", phase: .live(.init(turnStatus: .running, humanNeed: .permission)), ctx: 92)])
        let row = m.needsYouRows(now: t0).first
        XCTAssertEqual(row?.topReason, .humanRequired)
        XCTAssertEqual(row?.signals.map(\.reason), [.humanRequired, .ctxCritical])
    }

    // MARK: sort — most-urgent-first, then longest-waiting within a reason

    func testSortByTopReasonThenOldest() {
        let old = t0.addingTimeInterval(-600)
        let new = t0.addingTimeInterval(-60)
        let perm = card("perm", phase: .live(.init(turnStatus: .running, humanNeed: .permission)), at: new)
        let died = card("died", phase: .dead(.agentExited), dead: .agentExited, at: new)
        let ctx  = card("ctx", phase: .live(.running), ctx: 95, at: new)
        // Two same-reason (permission) rows to prove the oldest-first tiebreak within a bucket.
        let permOld = card("perm-old", phase: .live(.init(turnStatus: .running, humanNeed: .permission)), at: old)

        let order = modelWith([ctx, perm, died, permOld]).needsYouRows(now: t0).map(\.task.title)
        // dead(0) < permission(1) [oldest first] < ctxCritical(5)
        XCTAssertEqual(order, ["died", "perm-old", "perm", "ctx"])
    }

    // MARK: gate chords — agent-capability facts, not neutral-layer constants (unchanged by slice 5)

    private let standardGateCapabilities = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription, approveChord: [.named(.enter)], denyChord: [.named(.esc)])

    private var standardGateAgent: AgentInfo {
        AgentInfo(id: "claude-code", name: "Claude", icon: "sparkle",
                  models: [AgentModel(id: "m")], capabilities: standardGateCapabilities)
    }

    func testGateChordsLiveOnAgentCapabilities() {
        XCTAssertEqual(standardGateCapabilities.approveChord, [.named(.enter)])
        XCTAssertEqual(standardGateCapabilities.denyChord, [.named(.esc)])
    }

    func testUnknownAgentHasNoCapabilityProfile() {
        XCTAssertNil(modelWith([]).capabilities(for: "future-agent"))
    }

    func testUnknownAgentCannotBorrowClaudePermissionKeys() {
        var unknown = card("permission", phase: .live(.init(turnStatus: .running, humanNeed: .permission)))
        unknown.agentId = "future-agent"
        let m = modelWith([unknown])
        XCTAssertNil(m.permissionGateChord(unknown.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(unknown.id, \.denyChord))
    }

    func testGateFiresOnlyWhileWaitingOnPermission() {
        let perm = card("perm", phase: .live(.init(turnStatus: .running, humanNeed: .permission)))
        let humanTurn = card("human", phase: .live(.waiting))
        let running = card("run", phase: .live(.running))
        let dead = card("dead", phase: .dead(.agentExited))
        let m = modelWith([perm, humanTurn, running, dead], agents: [standardGateAgent])

        XCTAssertEqual(m.permissionGateChord(perm.id, \.approveChord), [.named(.enter)])
        XCTAssertEqual(m.permissionGateChord(perm.id, \.denyChord), [.named(.esc)])
        XCTAssertNil(m.permissionGateChord(humanTurn.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(running.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(dead.id, \.approveChord))
        XCTAssertNil(m.permissionGateChord(UUID(), \.approveChord))
    }

    func testGateChordComesFromTheCardsAgentCapability() {
        let tabCaps = AgentCapabilities(
            sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
            readOnlyEnforcement: .sandboxed,
            authMode: .subscription, approveChord: [.named(.tab)], denyChord: [])
        let agent = AgentInfo(id: "tabber", name: "Tabber", icon: "sparkle",
                              models: [AgentModel(id: "m")], capabilities: tabCaps)
        var t = card("perm", phase: .live(.init(turnStatus: .running, humanNeed: .permission)))
        t.agentId = "tabber"
        let m = modelWith([t], agents: [agent])
        XCTAssertEqual(m.permissionGateChord(t.id, \.approveChord), [.named(.tab)])
        XCTAssertNil(m.permissionGateChord(t.id, \.denyChord))
    }
}
