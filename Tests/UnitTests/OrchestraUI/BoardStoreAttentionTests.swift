import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The board-level attention folds (slice 3b): OWN over a real constellation, the descendants-only
/// SUBTREE count, and the two eye tiers re-derived from the same registry so amber-eye and amber-chip
/// are one fact. Pure over a hand-built `tasks` array and an injected `now` — no timers, no fs.
@Suite @MainActor struct BoardStoreAttentionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var T: TimeInterval { Attention.Thresholds().stallAfter }
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
                      humanPaced: Bool = false,
                      awaitingFirstPrompt: Bool = false,
                      at: Date? = nil) -> Task {
        Task(id: uuid(id), title: "card-\(id)", awaitingFirstPrompt: awaitingFirstPrompt,
             pendingQuestion: pendingQuestion,
             repo: "/repo", branch: branch, cwd: "/repo/.wt/\(branch)",
             origin: .worktree, access: access, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .impl, column: .impl, order: 0, phase: phase,
             phaseChangedAt: at ?? t0, ctxPct: ctxPct, initialPrompt: id,
             parentBranch: parentBranch, treeStat: treeStat,
             hasPendingDelivery: hasPendingDelivery, humanPaced: humanPaced,
             createdAt: t0, updatedAt: at ?? t0)
    }

    private func board(_ tasks: [Task]) -> BoardModel {
        let m = BoardModel(platform: .noop)
        m.tasks = tasks
        return m
    }

    // MARK: - the human-paced exemption flows from the Task field through the fold

    /// The board fold reads `Task.humanPaced` and threads it into the stall predicate: a quiescent idle
    /// card past `T` emits NOTHING when the bit is set, and still stalls when it is not. This is the wiring
    /// the pure `AttentionTests.stall_humanPacedIsExempt` cannot see (that one passes the flag directly);
    /// here it must travel from the card field, through `ownAttention`, to the row.
    @Test func stall_humanPacedCardFieldIsExemptThroughTheFold() {
        let paced = card("01", branch: "feat/x", humanPaced: true)
        #expect(!board([paced]).ownAttention(of: paced, now: late).contains { $0.reason == .stalled })
        // Same card, agent-paced (the default), still stalls — proving the exemption is the ONLY difference.
        let agentPaced = card("02", branch: "feat/y", humanPaced: false)
        #expect(board([agentPaced]).ownAttention(of: agentPaced, now: late).contains { $0.reason == .stalled })
    }

    /// The fold keys on `humanPaced` alone: a "New agent" card is exempt because the daemon set
    /// `humanPaced` at its promptless launch (a `awaitingFirstPrompt` card carries `humanPaced=true`), NOT
    /// because the fold reads `awaitingFirstPrompt` — a card with `awaitingFirstPrompt=true` but
    /// `humanPaced=false` (an agent-delivered provisional card) still stalls.
    @Test func stall_foldKeysOnHumanPacedNotAwaitingFirstPrompt() {
        let newAgent = card("01", branch: "feat/x", humanPaced: true, awaitingFirstPrompt: true)
        #expect(!board([newAgent]).ownAttention(of: newAgent, now: late).contains { $0.reason == .stalled })
        let agentDelivered = card("02", branch: "feat/y", humanPaced: false, awaitingFirstPrompt: true)
        #expect(board([agentDelivered]).ownAttention(of: agentDelivered, now: late).contains { $0.reason == .stalled })
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

    // MARK: - the flagship case: a parked review pass

    /// The scenario the stall net was built for, end-to-end: a review pair concluded, nobody archived
    /// them, and the whole constellation went quiet. The reviewers can't own it (attached never do), so
    /// the TARGET does — which is the only way an unconsumed review surfaces at all.
    @Test func parkedReviewPair_goesQuiet_theTargetOwnsTheStall() {
        let target = card("01", branch: "feat/x")
        let r1 = card("02", branch: "review/x", parentBranch: "feat/x", access: .readOnly)
        let r2 = card("03", branch: "review/y", parentBranch: "feat/x", access: .readOnly)
        let m = board([target, r1, r2])

        #expect(m.ownAttention(of: target, now: late).contains { $0.reason == .stalled })
        #expect(!m.ownAttention(of: r1, now: late).contains { $0.reason == .stalled })
        #expect(!m.ownAttention(of: r2, now: late).contains { $0.reason == .stalled })
    }

    /// But a DEAD reviewer holds its own reason, so leaf attachment hands the amber to it and the target
    /// reports through the rollup — the same "one fact, one amber" rule, reached via attachment.
    @Test func deadReviewer_ownsTheAmber_andTheTargetDefersToTheRollup() {
        let target = card("01", branch: "feat/x")
        let dead = card("02", branch: "review/x", parentBranch: "feat/x",
                        access: .readOnly, phase: .dead(.agentExited))
        let m = board([target, dead])

        #expect(m.ownAttention(of: dead, now: late).contains { $0.reason == .dead })
        #expect(!m.ownAttention(of: target, now: late).contains { $0.reason == .stalled })
        #expect(m.subtreeAttention(of: target, now: late) == 1)
    }

    // MARK: - row 3 liveness: a dead parent cannot merge for you

    /// `lineageParent` only filters archived, so a dead-but-unarchived parent would otherwise read as
    /// "owned" and silence the child completely — no merge amber AND stall-exempt.
    @Test func mergeRequested_intoADeadParent_ambersForTheHuman() {
        let deadParent = card("01", branch: "feat/root", phase: .dead(.agentExited))
        let child = card("02", branch: "feat/child", parentBranch: "feat/root",
                         treeStat: TreeStat(state: .mergeRequested))
        let m = board([deadParent, child])
        #expect(m.ownAttention(of: child, now: late).contains { $0.reason == .mergeRequested })
    }

    // MARK: - the fold must not blow up on a deep chain

    /// Leaf attachment makes `ownAttention` and `subtreeAttention` mutually recursive. Recomputed
    /// naively the recurrence is T(n) = T(n-1) + … + T(1) — EXPONENTIAL — so a deep PR chain would lock
    /// the board at a 1 Hz render tick. This pins the memoized fold: the chain resolves promptly and
    /// correctly. Depth is kept modest because the assertion is CORRECTNESS, not a stopwatch — but it is
    /// still 2^15 folds without the memo, so a regression doesn't slow this test down, it stops it
    /// finishing at all.
    @Test func deepChain_foldsOncePerCard_andStaysCorrect() {
        let depth = 16
        var chain: [Task] = []
        for i in 0..<depth {
            chain.append(card(String(format: "%02x", i), branch: "feat/n\(i)",
                              parentBranch: i == 0 ? nil : "feat/n\(i - 1)"))
        }
        let m = board(chain)

        // Every card is quiet past T, so ONLY the deepest (which has no descendants to defer to) owns
        // the stall; every ancestor reports it through the rollup.
        let deepest = chain[depth - 1]
        #expect(m.ownAttention(of: deepest, now: late).contains { $0.reason == .stalled })
        #expect(!m.ownAttention(of: chain[0], now: late).contains { $0.reason == .stalled })
        #expect(m.subtreeAttention(of: chain[0], now: late) == 1)
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
