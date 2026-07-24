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
        let canStall = !isAttached(c)
        return Attention.ownReasons(
            for: c,
            attached: attachedAgents(of: c),
            descendants: canStall ? descendants(of: c) : [],
            parentOwned: lineageParent(of: c) != nil,
            canStall: canStall,
            // Leaf attachment: an ancestor whose descendants already hold attention reports them via
            // the rollup instead of ambering for the same silence.
            descendantHoldsAttention: canStall ? subtreeAttention(of: c, now: now) > 0 : false,
            now: now)
    }

    /// Whether `c` needs the human at all — the membership test the folds and the eye share.
    public func hasAttention(_ c: Task, now: Date) -> Bool {
        !ownAttention(of: c, now: now).isEmpty
    }

    /// How many DESCENDANTS of `c` hold at least one reason — the L4 "N need you" count.
    ///
    /// Counts CARDS, not reasons: a descendant blocked on permission at 95% context is still one card
    /// that needs you. Self is excluded by construction (`descendants` never contains its root).
    ///
    /// Note the mutual recursion with `ownAttention` (which asks this for its leaf-attachment input).
    /// It terminates because `descendants` strictly shrinks at each hop and `BoardTree.descendants` is
    /// cycle-safe; memoize per render pass if a board ever grows large enough for the repeated walk to
    /// matter.
    public func subtreeAttention(of c: Task, now: Date) -> Int {
        descendants(of: c).filter { !ownAttention(of: $0, now: now).isEmpty }.count
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
