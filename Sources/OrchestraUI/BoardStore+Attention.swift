import Foundation
import OrchestraKit

/// The board-level attention folds (slice 3b) — the bridge between the pure `Attention` registry and
/// the flat `tasks` array. `Attention` owns the RULES; this extension owns the LOOKUPS (which agents
/// are attached, what the subtree is, whether the merge target has an owning card), so the registry
/// stays store-free and per-row testable.
///
/// Two folds, one registry:
/// - **OWN** — the reasons a card holds itself → the L1 chip, the peek-row action label, the drill chip.
/// - **SUBTREE** — how many DESCENDANTS hold at least one reason (self excluded) → the L4 rollup chip.
///
/// The eye tint is re-derived here too, from the same `ownAttention`, so an amber eye and an amber
/// chip are the same fact rather than two predicates that can drift apart.
extension BoardStore {

    /// Every reason `c` owns right now, most-urgent first.
    ///
    /// Attached agents (read-only reviewers) pass `canStall: false` — a reviewer never owns a stall,
    /// it surfaces through its target's constellation. That also short-circuits the descendant walk
    /// and the leaf-attachment recursion, which only the stall row consumes.
    public func ownAttention(of c: Task, now: Date) -> [AttentionSignal] {
        var memo: [UUID: [AttentionSignal]] = [:]
        return ownAttention(of: c, now: now, memo: &memo)
    }

    /// Whether `c` needs the human at all — the membership test the folds and the eye share.
    public func hasAttention(_ c: Task, now: Date) -> Bool {
        !ownAttention(of: c, now: now).isEmpty
    }

    /// How many DESCENDANTS of `c` hold at least one reason — the L4 "N need you" count.
    ///
    /// Counts CARDS, not reasons: a descendant blocked on permission at 95% context is still one card
    /// that needs you. Self is excluded by construction (`descendants` never contains its root).
    public func subtreeAttention(of c: Task, now: Date) -> Int {
        var memo: [UUID: [AttentionSignal]] = [:]
        return subtreeAttention(of: c, now: now, memo: &memo)
    }

    // MARK: - the memoized core
    //
    // `ownAttention` and `subtreeAttention` are MUTUALLY recursive: leaf attachment asks "does any
    // descendant hold attention?", which is every descendant's own fold, which asks the same of ITS
    // descendants. Terminating isn't the hard part (`descendants` strictly shrinks and is cycle-safe) —
    // the cost is. Recomputed naively on a depth-n chain the recurrence is T(n) = T(n-1) + … + T(1),
    // i.e. EXPONENTIAL, not quadratic: each card re-derives every suffix below it from scratch. At a
    // 1 Hz render tick a deep PR chain would lock the board.
    //
    // One memo per top-level call collapses that to each card being folded at most once, because a
    // card's reasons depend only on the board and `now`, both fixed for the duration of the call.

    private func ownAttention(of c: Task, now: Date, memo: inout [UUID: [AttentionSignal]]) -> [AttentionSignal] {
        if let cached = memo[c.id] { return cached }
        // Eligible to OWN a stall: not an attached reviewer (they surface through their target), and
        // idle — `isStalled` gates on both anyway, so folding them in here is behaviour-preserving and
        // skips the whole subtree walk for the running/dead/transient majority of a live board.
        let canStall = !isAttached(c) && Attention.isIdle(c)
        // ONE subtree walk, reused for both the stall guard and leaf attachment — `descendants` is
        // itself an O(n) filter per node, so walking it twice per card is the difference between a
        // cheap fold and a visible hitch on a deep chain.
        let kids = canStall ? descendants(of: c) : []
        // Leaf attachment: an ancestor whose descendants already hold attention reports them via the
        // rollup instead of ambering for the same silence. `contains` short-circuits on the first one —
        // the guard is a Bool, so counting the rest would be wasted work.
        let holds = canStall && kids.contains { !ownAttention(of: $0, now: now, memo: &memo).isEmpty }
        let signals = Attention.ownReasons(
            for: c,
            attached: attachedAgents(of: c),
            descendants: kids,
            // "Owned" means a card that will actually DO the merge. A dead parent won't — it is itself
            // ambering for recovery — so its child must route to the human rather than wait on a card
            // that cannot act. (`lineageParent` only filters archived, so the liveness test is here.)
            parentOwned: lineageParent(of: c).map { $0.phase.kind != .dead } ?? false,
            canStall: canStall,
            descendantHoldsAttention: holds,
            now: now,
            // The human-paced exemption: a card whose last driving turn was a direct human interaction
            // never stalls, however long it idles. The daemon computes the bit (`Task.humanPaced`); the
            // stall row just honours it.
            humanPaced: c.humanPaced)
        memo[c.id] = signals
        return signals
    }

    private func subtreeAttention(of c: Task, now: Date, memo: inout [UUID: [AttentionSignal]]) -> Int {
        descendants(of: c).filter { !ownAttention(of: $0, now: now, memo: &memo).isEmpty }.count
    }

    /// The eye tier for ONE attached agent — what a peek row draws.
    ///
    /// `now`-free on purpose: an attached agent never stalls, so every reason it can hold (dead,
    /// permission, question, context) is time-independent. That keeps the eye off the render clock
    /// entirely.
    ///
    /// Amber whenever the agent holds ANY reason — which is strictly more than the phase-only tint it
    /// replaces (it now also catches a reviewer that asked a question or is nearly out of context),
    /// and is exactly what the subtree chip counts, so the two can never disagree.
    public func attentionTier(of agent: Task) -> AttachedLiveness {
        if hasAttention(agent, now: .distantPast) { return .needsAttention }
        // A concluded reviewer is QUIET, not attention — the invariant the three-tier eye established.
        // Anything not settled (running, being born, or holding queued work) is still live.
        return Attention.isSettled(agent) ? .idle : .running
    }

    /// The roll-up eye for `target`'s attached agents, or nil when none are attached (badge hidden).
    /// A genuine block dominates; an active reviewer keeps it green even while a sibling has concluded;
    /// all-concluded is the quiet floor.
    public func attentionLiveness(of target: Task) -> AttachedLiveness? {
        let agents = attachedAgents(of: target)
        guard !agents.isEmpty else { return nil }
        let tiers = agents.map { attentionTier(of: $0) }
        if tiers.contains(.needsAttention) { return .needsAttention }
        if tiers.contains(.running) { return .running }
        return .idle
    }
}
