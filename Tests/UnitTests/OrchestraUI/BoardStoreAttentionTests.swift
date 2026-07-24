import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The board-level attention folds (slice 3b): OWN over a real constellation, the descendants-only
/// SUBTREE count, and the two eye tiers re-derived from the same registry so amber-eye and amber-chip
/// are one fact. Pure over a hand-built `tasks` array and an injected `now` — no timers, no fs.
@Suite @MainActor struct BoardStoreAttentionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var T: TimeInterval { Attention.Config().stallAfter }
    private var late: Date { t0.addingTimeInterval(T + 80) }

    private func uuid(_ id: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!
    }

    private func card(_ id: String, branch: String, parentBranch: String? = nil,
                      access: CardAccess = .readWrite,
                      phase: Phase = .live(.waiting(.humanTurn)),
                      ctxPct: Double = 0,
                      pendingQuestion: PendingQuestion? = nil,
                      treeStat: TreeStat? = nil,
                      hasPendingDelivery: Bool = false,
                      at: Date? = nil) -> Task {
        Task(id: uuid(id), title: "card-\(id)", pendingQuestion: pendingQuestion,
             repo: "/repo", branch: branch, cwd: "/repo/.wt/\(branch)",
             origin: .worktree, access: access, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .impl, column: .impl, order: 0, phase: phase,
             phaseChangedAt: at ?? t0, ctxPct: ctxPct, initialPrompt: id,
             parentBranch: parentBranch, treeStat: treeStat,
             hasPendingDelivery: hasPendingDelivery, createdAt: t0, updatedAt: at ?? t0)
    }

    private func board(_ tasks: [Task]) -> BoardModel {
        let m = BoardModel(platform: .noop)
        m.tasks = tasks
        return m
    }

    // MARK: - attached agents never own a stall

    @Test func attachedReviewer_quietPastT_neverOwnsAStall() {
        let target = card("01", branch: "feat/x")
        let reviewer = card("02", branch: "review/x", parentBranch: "feat/x", access: .readOnly)
        let m = board([target, reviewer])
        #expect(m.isAttached(reviewer))
        #expect(!m.ownAttention(of: reviewer, now: late).contains { $0.reason == .stalled })
    }

    // MARK: - leaf attachment, end-to-end through the store

    /// The whole point of the rule: the stopped CHILD owns the amber, and its idle parent reports it
    /// through the rollup instead of ambering for the same silence.
    @Test func leafAttachment_childOwnsTheStall_parentReportsViaRollup() {
        let root = card("01", branch: "feat/root")
        let child = card("02", branch: "feat/child", parentBranch: "feat/root")
        let m = board([root, child])

        #expect(m.ownAttention(of: child, now: late).contains { $0.reason == .stalled })
        #expect(!m.ownAttention(of: root, now: late).contains { $0.reason == .stalled })
        #expect(m.subtreeAttention(of: root, now: late) == 1)
    }

    /// With nothing below it, the same quiet root DOES own its stall — the rule defers to descendants,
    /// it doesn't exempt ancestors unconditionally.
    @Test func leafAttachment_rootWithNoDescendants_stillOwnsItsStall() {
        let root = card("01", branch: "feat/root")
        #expect(board([root]).ownAttention(of: root, now: late).contains { $0.reason == .stalled })
    }

    // MARK: - the SUBTREE fold

    @Test func subtree_excludesSelf() {
        let root = card("01", branch: "feat/root", phase: .live(.waiting(.permission)))
        let m = board([root])
        #expect(!m.ownAttention(of: root, now: late).isEmpty)   // root itself needs you
        #expect(m.subtreeAttention(of: root, now: late) == 0)    // but it is not its own descendant
    }

    @Test func subtree_countsAPermissionBlockedAttachedReviewer() {
        let target = card("01", branch: "feat/x", phase: .live(.running))
        let reviewer = card("02", branch: "review/x", parentBranch: "feat/x",
                            access: .readOnly, phase: .live(.waiting(.permission)))
        #expect(board([target, reviewer]).subtreeAttention(of: target, now: late) == 1)
    }

    /// A descendant with SEVERAL reasons is still one card that needs you — the fold counts cards, not
    /// reasons, so it must not double-count.
    @Test func subtree_multiReasonDescendant_countsOnce() {
        let root = card("01", branch: "feat/root", phase: .live(.running))
        let child = card("02", branch: "feat/child", parentBranch: "feat/root",
                         access: .readOnly, phase: .live(.waiting(.permission)), ctxPct: 95)
        let m = board([root, child])
        #expect(m.ownAttention(of: child, now: late).count == 2)      // permission + ctx-critical
        #expect(m.subtreeAttention(of: root, now: late) == 1)          // ...one card
    }

    /// The count is `now`-derived through the stall row: the same board reads 0 before T and 1 after.
    @Test func subtree_reflectsADescendantCrossingT() {
        let root = card("01", branch: "feat/root", phase: .live(.running))
        let child = card("02", branch: "feat/child", parentBranch: "feat/root")
        let m = board([root, child])
        #expect(m.subtreeAttention(of: root, now: t0.addingTimeInterval(T - 1)) == 0)
        #expect(m.subtreeAttention(of: root, now: t0.addingTimeInterval(T + 1)) == 1)
    }

    // MARK: - the eye, re-derived from the fold

    @Test func attentionTier_ambersOnABlockedOrDeadReviewer() {
        let target = card("01", branch: "feat/x")
        for phase: Phase in [.live(.waiting(.permission)), .dead(.agentExited)] {
            let reviewer = card("02", branch: "review/x", parentBranch: "feat/x",
                                access: .readOnly, phase: phase)
            let m = board([target, reviewer])
            #expect(m.attentionTier(of: reviewer) == .needsAttention, "\(phase) should amber the eye")
        }
    }

    /// The strict improvement over the phase-only eye: a reviewer that needs you for a NON-phase
    /// reason ambers too, so the eye and the chip can never disagree.
    @Test func attentionTier_ambersOnAQuestionOrContextCriticalReviewer() {
        let target = card("01", branch: "feat/x")
        let asking = card("02", branch: "review/x", parentBranch: "feat/x", access: .readOnly,
                          pendingQuestion: PendingQuestion(text: "which?", declaredAt: t0))
        let full = card("03", branch: "review/y", parentBranch: "feat/x", access: .readOnly,
                        phase: .live(.running), ctxPct: 92)
        let m = board([target, asking, full])
        #expect(m.attentionTier(of: asking) == .needsAttention)
        #expect(m.attentionTier(of: full) == .needsAttention)
    }

    /// The owner-established invariant: a CONCLUDED reviewer is quiet, not attention.
    @Test func attentionTier_concludedReviewerIsIdle_neverAmber() {
        let target = card("01", branch: "feat/x", phase: .live(.running))
        let done = card("02", branch: "review/x", parentBranch: "feat/x", access: .readOnly)
        let m = board([target, done])
        #expect(m.attentionTier(of: done) == .idle)
    }

    @Test func attentionLiveness_isNilWithNoAttachedAgents() {
        let solo = card("01", branch: "feat/x")
        #expect(board([solo]).attentionLiveness(of: solo) == nil)
    }

    /// A running sibling keeps the roll-up green even though another reviewer has concluded — the
    /// parked-reviewer leak lands on the target's own stall, not on the eye.
    @Test func attentionLiveness_runningSiblingKeepsItGreen() {
        let target = card("01", branch: "feat/x", phase: .live(.running))
        let working = card("02", branch: "review/x", parentBranch: "feat/x",
                           access: .readOnly, phase: .live(.running))
        let done = card("03", branch: "review/y", parentBranch: "feat/x", access: .readOnly)
        #expect(board([target, working, done]).attentionLiveness(of: target) == .running)
    }

    @Test func attentionLiveness_needsAttentionDominatesRunning() {
        let target = card("01", branch: "feat/x", phase: .live(.running))
        let working = card("02", branch: "review/x", parentBranch: "feat/x",
                           access: .readOnly, phase: .live(.running))
        let blocked = card("03", branch: "review/y", parentBranch: "feat/x",
                           access: .readOnly, phase: .live(.waiting(.permission)))
        #expect(board([target, working, blocked]).attentionLiveness(of: target) == .needsAttention)
    }

    @Test func attentionLiveness_allConcludedIsIdle() {
        let target = card("01", branch: "feat/x", phase: .live(.running))
        let a = card("02", branch: "review/x", parentBranch: "feat/x", access: .readOnly)
        let b = card("03", branch: "review/y", parentBranch: "feat/x", access: .readOnly)
        #expect(board([target, a, b]).attentionLiveness(of: target) == .idle)
    }

    // MARK: - row 3 through the real lineage seam

    /// root→main: no card owns `main`, so the merge is the human's to do.
    @Test func mergeRequested_rootIntoMain_ambers() {
        let root = card("01", branch: "feat/root", parentBranch: "main",
                        treeStat: TreeStat(state: .mergeRequested))
        #expect(board([root]).ownAttention(of: root, now: late)
            .contains { $0.reason == .mergeRequested })
    }

    /// ...but a child merging into a branch a live card owns is that agent's business, and stays quiet.
    @Test func mergeRequested_intoAnOwnedParent_staysQuiet() {
        let parent = card("01", branch: "feat/root", phase: .live(.running))
        let child = card("02", branch: "feat/child", parentBranch: "feat/root",
                         treeStat: TreeStat(state: .mergeRequested))
        let m = board([parent, child])
        #expect(m.ownAttention(of: child, now: late).isEmpty)
    }
}
