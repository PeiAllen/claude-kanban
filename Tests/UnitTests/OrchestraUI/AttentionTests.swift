import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The attention registry (slice 3b): the six rows, their priority, and every stall guard.
///
/// All pure over an INJECTED `now` and hand-built constellations — no store, no timers, no forks. The
/// stall row is the interesting one: it is a conjunction of quiescence conditions plus a timer, and
/// each conjunct gets its own negative test so a future edit can't silently drop one.
@Suite struct AttentionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var T: TimeInterval { Attention.Thresholds().stallAfter }

    private func uuid(_ id: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!   // id: exactly 2 hex chars
    }

    /// A card whose timestamps default to `t0` — so "nothing changed since t0" is the baseline and a
    /// test only states the fields it cares about.
    private func card(_ id: String = "01",
                      phase: Phase = .live(.waiting(.humanTurn)),
                      treeStat: TreeStat? = nil,
                      pendingQuestion: PendingQuestion? = nil,
                      ctxPct: Double = 0,
                      hasPendingDelivery: Bool = false,
                      awaitingFirstPrompt: Bool = false,
                      access: CardAccess = .readWrite,
                      at: Date? = nil) -> Task {
        Task(id: uuid(id), title: "card-\(id)", awaitingFirstPrompt: awaitingFirstPrompt,
             pendingQuestion: pendingQuestion,
             repo: "/repo", branch: "feat/\(id)", cwd: "/repo/.wt/\(id)",
             origin: .worktree, access: access, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .impl, column: .impl, order: 0, phase: phase,
             phaseChangedAt: at ?? t0, ctxPct: ctxPct, initialPrompt: id,
             treeStat: treeStat, hasPendingDelivery: hasPendingDelivery,
             createdAt: t0, updatedAt: at ?? t0)
    }

    private func reasons(_ c: Task, attached: [Task] = [], descendants: [Task] = [],
                         parentOwned: Bool = true, canStall: Bool = true,
                         descendantHoldsAttention: Bool = false,
                         now: Date? = nil, humanPaced: Bool = false,
                         config: Attention.Thresholds = .init()) -> [AttentionSignal] {
        Attention.ownReasons(for: c, attached: attached, descendants: descendants,
                             parentOwned: parentOwned, canStall: canStall,
                             descendantHoldsAttention: descendantHoldsAttention,
                             now: now ?? t0, humanPaced: humanPaced, config: config)
    }

    /// `now` far enough past `t0` that the stall timer has elapsed.
    private var late: Date { t0.addingTimeInterval(T + 80) }

    // MARK: - the six rows

    @Test func deadRow() {
        let r = reasons(card(phase: .dead(.agentExited)))
        #expect(r.first?.reason == .dead)
        #expect(r.first?.label == "dead")
    }

    @Test func permissionRow() {
        let r = reasons(card(phase: .live(.waiting(.permission))))
        #expect(r.first?.reason == .permission)
        #expect(r.first?.label == "permission")
    }

    /// Row 3 fires only when the merge target has NO owning card — the root→main case in practice.
    @Test func mergeRequested_unownedParent_fires() {
        let c = card(treeStat: TreeStat(state: .mergeRequested))
        let r = reasons(c, parentOwned: false)
        #expect(r.contains { $0.reason == .mergeRequested && $0.label == "merge-requested" })
    }

    /// The negative side: a child merge-requesting into an OWNED parent is the owning agent's business
    /// (grey ⏱) — no amber AND exempt from the stall net, so the wait never degrades into "stalled".
    @Test func mergeRequested_ownedParent_noReason_andStallExempt() {
        let c = card(treeStat: TreeStat(state: .mergeRequested))
        let r = reasons(c, parentOwned: true, now: late)
        #expect(!r.contains { $0.reason == .mergeRequested })
        #expect(!r.contains { $0.reason == .stalled })
        #expect(r.isEmpty)
    }

    @Test func questionRow_declared() {
        let c = card(pendingQuestion: PendingQuestion(text: "which db?", declaredAt: t0))
        let r = reasons(c)
        #expect(r.first?.reason == .question)
        #expect(r.first?.label == "question")
    }

    @Test func ctxCriticalRow_rendersPercent() {
        let r = reasons(card(phase: .live(.running), ctxPct: 88))
        #expect(r.first?.reason == .ctxCritical)
        #expect(r.first?.label == "ctx 88%")
    }

    @Test func ctxCritical_belowThreshold_isQuiet() {
        #expect(reasons(card(phase: .live(.running), ctxPct: 84)).isEmpty)
    }

    // MARK: - stall: the happy path + the timer

    @Test func stall_firesAfterT_onAQuietIdleCard() {
        let r = reasons(card(), now: late)
        #expect(r.first?.reason == .stalled)
        #expect(r.first?.label.hasPrefix("stalled ") == true)
    }

    /// The stall duration rolls up into the board's `m`/`h`/`d` units (via `compactDuration`), so a
    /// long-quiet card reads `stalled 2h` / `stalled 1d` like every other time stamp — not a flat
    /// minute count (`130m`). `card()` is quiet since `t0`, so `now - t0` IS the quiet duration.
    @Test func stall_label_rollsQuietDurationIntoHoursAndDays() {
        #expect(reasons(card(), now: t0.addingTimeInterval(45 * 60)).first?.label == "stalled 45m")
        #expect(reasons(card(), now: t0.addingTimeInterval(2 * 3600 + 5)).first?.label == "stalled 2h")
        #expect(reasons(card(), now: t0.addingTimeInterval(25 * 3600)).first?.label == "stalled 1d")
    }

    /// Strictly greater than T — exactly-at-T is still quiet, so a `>`/`>=` slip is caught.
    @Test func stall_timerBoundary_underT_isQuiet_atT_isQuiet_overT_fires() {
        #expect(!reasons(card(), now: t0.addingTimeInterval(T - 1)).contains { $0.reason == .stalled })
        #expect(!reasons(card(), now: t0.addingTimeInterval(T)).contains { $0.reason == .stalled })
        #expect(reasons(card(), now: t0.addingTimeInterval(T + 1)).contains { $0.reason == .stalled })
    }

    /// The clock is the NEWER of `phaseChangedAt` and `updatedAt`: a card touched without a phase change
    /// is not silent. Every other fixture sets the two equal, so this is what stops the `max` collapsing
    /// to `phaseChangedAt` unnoticed.
    @Test func stall_timerTakesTheNewerOfPhaseChangedAndUpdated() {
        var touched = card()                                   // phaseChangedAt stays at t0…
        touched.updatedAt = late.addingTimeInterval(-30)        // …but it was touched 30s ago
        #expect(!reasons(touched, now: late).contains { $0.reason == .stalled })
    }

    /// ...and the card ITSELF is in the constellation, not just its reviewers: a card that moved
    /// recently is not stalled even when every attached agent has been quiet for ages.
    @Test func stall_timerIncludesTheCardItself_notOnlyItsAttachedAgents() {
        let staleReviewer = card("02", access: .readOnly)                    // quiet since t0
        let recentlyMoved = card(at: late.addingTimeInterval(-30))           // but the card just moved
        #expect(!reasons(recentlyMoved, attached: [staleReviewer], now: late)
            .contains { $0.reason == .stalled })
    }

    /// The timer spans the CONSTELLATION — the card plus its attached agents — so a reviewer that
    /// spoke recently keeps its target out of the stall net.
    @Test func stall_timerIncludesAttachedAgentActivity() {
        let recentReviewer = card("02", access: .readOnly, at: late.addingTimeInterval(-60))
        #expect(!reasons(card(), attached: [recentReviewer], now: late).contains { $0.reason == .stalled })
    }

    /// ...but a DESCENDANT's timestamp is not in the constellation: descendants gate the stall by being
    /// active (below), never by moving the clock.
    @Test func stall_timerExcludesDescendantTimestamps() {
        let freshButIdleChild = card("03", at: late.addingTimeInterval(-5))
        #expect(reasons(card(), descendants: [freshButIdleChild], now: late).contains { $0.reason == .stalled })
    }

    // MARK: - stall guards (one negative test per conjunct)

    @Test func stall_requiresIdle_runningNeverStalls() {
        #expect(!reasons(card(phase: .live(.running)), now: late).contains { $0.reason == .stalled })
    }

    @Test func stall_humanPacedIsExempt() {
        #expect(!reasons(card(), now: late, humanPaced: true).contains { $0.reason == .stalled })
    }

    /// A "New agent" card the human made but hasn't prompted yet is human-paced by construction — its
    /// quiet is the human's move, not a fault — so it never stalls however long it idles. (The
    /// screenshot that motivated this: a freeform dock of `awaitingFirstPrompt` cards all ambering.)
    @Test func stall_awaitingFirstPromptIsExempt() {
        #expect(!reasons(card(awaitingFirstPrompt: true), now: late).contains { $0.reason == .stalled })
        // …and a card that HAS been prompted (the default) with no human-pacing still stalls, so the
        // exemption is exactly the never-prompted case, not a blanket off-switch.
        #expect(reasons(card(awaitingFirstPrompt: false), now: late).contains { $0.reason == .stalled })
    }

    @Test func stall_declaredQuestionSuppressesIt() {
        let c = card(pendingQuestion: PendingQuestion(text: "q", declaredAt: t0))
        let r = reasons(c, now: late)
        #expect(r.contains { $0.reason == .question })
        #expect(!r.contains { $0.reason == .stalled })
    }

    @Test func stall_ownPendingDeliveryDefeatsIt() {
        #expect(!reasons(card(hasPendingDelivery: true), now: late).contains { $0.reason == .stalled })
    }

    @Test func stall_activeDescendantDefeatsIt() {
        let busyChild = card("03", phase: .live(.running))
        #expect(!reasons(card(), descendants: [busyChild], now: late).contains { $0.reason == .stalled })
    }

    /// A being-born child is activity too — the transient phases must take the same branch as `.running`.
    @Test func stall_transientDescendantDefeatsIt() {
        for phase: Phase in [.launching, .relaunching, .creatingWorktree] {
            let child = card("03", phase: phase)
            #expect(!reasons(card(), descendants: [child], now: late).contains { $0.reason == .stalled },
                    "descendant in \(phase) should defeat the stall")
        }
    }

    /// A quiet child with queued work is imminently active — an ancestor must not announce "wave done".
    @Test func stall_descendantPendingDeliveryDefeatsIt() {
        let child = card("03", hasPendingDelivery: true)
        #expect(!reasons(card(), descendants: [child], now: late).contains { $0.reason == .stalled })
    }

    @Test func stall_nonIdleAttachedAgentDefeatsIt() {
        let workingReviewer = card("02", phase: .live(.running), access: .readOnly)
        #expect(!reasons(card(), attached: [workingReviewer], now: late).contains { $0.reason == .stalled })
    }

    /// A reviewer that READS idle but has a message queued is about to speak — the delivery bit is part
    /// of "settled", not a separate check, and dropping it from the attached branch must fail here.
    @Test func stall_attachedAgentWithPendingDeliveryDefeatsIt() {
        let armedReviewer = card("02", hasPendingDelivery: true, access: .readOnly)
        #expect(!reasons(card(), attached: [armedReviewer], now: late).contains { $0.reason == .stalled })
    }

    /// Concluded and dead reviewers are both SETTLED, so neither defeats the quiet check — a parked
    /// review pair is exactly what the net exists to catch.
    ///
    /// Scope note: this is the pure predicate, with leaf attachment held at `false`. Through the store a
    /// DEAD reviewer is also a descendant holding `.dead`, so leaf attachment defers the target instead
    /// (the dead reviewer owns the amber). Both end-to-end outcomes are pinned in
    /// `BoardStoreAttentionTests`; this one isolates the settled check.
    @Test func stall_idleOrDeadAttachedAgentsAreSettled_soDoNotDefeatIt() {
        let idleReviewer = card("02", access: .readOnly)
        let deadReviewer = card("03", phase: .dead(.agentExited), access: .readOnly)
        #expect(reasons(card(), attached: [idleReviewer, deadReviewer], now: late).contains { $0.reason == .stalled })
    }

    // MARK: - leaf attachment (one fact, one amber, aggregated once)

    /// When a tree goes quiet the amber attaches at the STOPPED cards; an ancestor whose descendants
    /// already hold attention reports via the L4 rollup only, never its own stall.
    @Test func stall_leafAttachment_ancestorDefersToDescendantsHoldingAttention() {
        let stoppedChild = card("03")
        #expect(!reasons(card(), descendants: [stoppedChild], descendantHoldsAttention: true, now: late)
            .contains { $0.reason == .stalled })
    }

    @Test func stall_leafAttachment_ancestorWithCleanDescendantsStillOwnsIt() {
        let cleanChild = card("03")
        #expect(reasons(card(), descendants: [cleanChild], descendantHoldsAttention: false, now: late)
            .contains { $0.reason == .stalled })
    }

    // MARK: - stall variants: drained nudge + mergeStalled fold-in

    /// A drained root's children merged away, so it has no descendants left and owns the nudge itself.
    @Test func stall_drainedQuiescentRoot_carriesTheWaveDoneNudge() {
        let c = card(treeStat: TreeStat(state: .inSync, drained: true))
        let r = reasons(c, now: late)
        #expect(r.first?.reason == .stalled)
        #expect(r.first?.label == "wave done — move to Review?")
    }

    /// `mergeStalled` is a PRE-COMPUTED input: it fires immediately, without waiting out T, and is not
    /// suppressed by the mergeRequested state it rides alongside.
    @Test func mergeStalled_firesImmediately_bypassingTheTimer() {
        let c = card(treeStat: TreeStat(state: .mergeRequested, mergeStalled: true))
        let r = reasons(c, now: t0)   // no time has passed at all
        #expect(r.first?.reason == .stalled)
        #expect(r.first?.label == "merge stalled")
    }

    /// ...but a card that RESUMED running carrying a stale flag is working, not stalled.
    @Test func mergeStalled_onARunningCard_doesNotFire() {
        let c = card(phase: .live(.running), treeStat: TreeStat(state: .mergeRequested, mergeStalled: true))
        #expect(!reasons(c, now: late).contains { $0.reason == .stalled })
    }

    // MARK: - attached agents never own a stall

    @Test func attachedAgent_neverOwnsAStall_butStillOwnsRealBlocks() {
        let reviewer = card("02", access: .readOnly)
        #expect(!reasons(reviewer, canStall: false, now: late).contains { $0.reason == .stalled })

        let blocked = card("02", phase: .live(.waiting(.permission)), access: .readOnly)
        #expect(reasons(blocked, canStall: false, now: late).contains { $0.reason == .permission })
    }

    /// canStall gates every isStalled path, mergeStalled included.
    @Test func attachedAgent_neverOwnsMergeStalledEither() {
        let reviewer = card("02", treeStat: TreeStat(state: .inSync, mergeStalled: true), access: .readOnly)
        #expect(!reasons(reviewer, canStall: false, now: t0).contains { $0.reason == .stalled })
    }

    // MARK: - priority + overflow

    @Test func priority_isHardBlockedFirst() {
        #expect(Attention.Reason.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])
        #expect(Attention.Reason.dead.rawValue < Attention.Reason.permission.rawValue)
        #expect(Attention.Reason.permission.rawValue < Attention.Reason.mergeRequested.rawValue)
        #expect(Attention.Reason.mergeRequested.rawValue < Attention.Reason.question.rawValue)
        #expect(Attention.Reason.question.rawValue < Attention.Reason.stalled.rawValue)
        #expect(Attention.Reason.stalled.rawValue < Attention.Reason.ctxCritical.rawValue)
    }

    /// Multi-reason cards sort hard-blocked-first, so the L1 chip's top label is the most urgent and
    /// the rest become its "+N".
    @Test func multipleReasons_sortByPriority() {
        let c = card(phase: .live(.waiting(.permission)),
                     pendingQuestion: PendingQuestion(text: "q", declaredAt: t0),
                     ctxPct: 91)
        let r = reasons(c, now: late)
        #expect(r.map(\.reason) == [.permission, .question, .ctxCritical])
    }

    @Test func quietCard_hasNoReasons() {
        #expect(reasons(card(phase: .live(.running))).isEmpty)
    }

    // MARK: - chip text

    @Test func chipText_topLabelThenOverflow() {
        #expect(Attention.chipText([]) == nil)                                   // quiet ⇒ nothing renders
        #expect(Attention.chipText([.init(.permission, "permission")]) == "permission")
        #expect(Attention.chipText([.init(.permission, "permission"),
                                    .init(.ctxCritical, "ctx 91%")]) == "permission +1")
    }

    @Test func subtreeChipText_countsCardsAndAgrees() {
        #expect(Attention.subtreeChipText(0) == nil)
        #expect(Attention.subtreeChipText(1) == "1 needs you")
        #expect(Attention.subtreeChipText(3) == "3 need you")
    }
}
