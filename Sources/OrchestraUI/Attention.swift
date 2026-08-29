import Foundation
import OrchestraKit

/// ONE definition of "needs you" (board-hierarchy slice 3b) — a pure registry over broadcast card
/// state, shared by every surface (L1/L4 chips, peek rows, the drill banner, the eye tint, and the
/// iOS Needs You tab when it adopts this).
///
/// **Membership contract:** a card emits a reason IFF a HUMAN ACTION is required for work to proceed
/// (or to stop waste). Not "interesting", not "in progress". Every future row must pass that test —
/// it is the whole reason amber stays trustworthy enough to scan for.
///
/// **Two layers:** done-ness is DECLARED (merge-request, move-to-Review, an agent concluding its
/// turn); only the stall row is DETECTED, and it doubles as the safety net — a card that finishes but
/// forgets to declare goes quiescent and ambers within `T`, so no completion is silently lost.
///
/// Everything here is a pure static over an INJECTED `now`: no store, no clock, no I/O, so each row
/// and each stall conjunct is unit-testable in isolation. The board lookups the predicates need
/// (attached agents, descendants, whether the merge target has an owning card) are supplied by the
/// caller — see `BoardStore+Attention`.
public struct AttentionSignal: Equatable, Sendable {
    public let reason: Attention.Reason
    /// The rendered chip text. Static for most rows; the stall row computes it (elapsed minutes, the
    /// sharper "merge stalled", or the drained-wave nudge), so the label travels WITH the reason
    /// rather than being re-derived per surface.
    public let label: String
    public init(_ reason: Attention.Reason, _ label: String) {
        self.reason = reason
        self.label = label
    }
}

public enum Attention {
    /// The registry, in priority order — declaration order IS the order, ascending `rawValue` = more
    /// hard-blocked. The L1 chip renders the first one and folds the rest into a "+N".
    public enum Reason: Int, CaseIterable, Sendable, Equatable, Hashable {
        case dead = 0        // the session is gone — nothing proceeds until it's recovered
        case humanRequired   // either provider observation or a durable declared question needs a person
        case mergeRequested  // merge-requested into a branch NO card owns ⇒ only a human can merge it
        case stalled         // quiescent past T, or a pre-computed merge give-up
        case ctxCritical     // context near-full — hand off soon
    }

    public struct Thresholds: Sendable, Equatable {
        /// How long a constellation must be quiet before it ambers. A UI constant (not daemon state):
        /// long enough that a thinking pause never trips it, short enough to catch a dead wave.
        public var stallAfter: TimeInterval
        /// Context-usage percentage at/above which a card wants a handoff.
        public var ctxCriticalPct: Double
        public init(stallAfter: TimeInterval = 12 * 60, ctxCriticalPct: Double = 85) {
            self.stallAfter = stallAfter
            self.ctxCriticalPct = ctxCriticalPct
        }
    }

    // MARK: - quiescence primitives

    /// The provider owns no further work: an ordinary wait with no automatic resume. Running,
    /// unavailable, and auto-resuming waits cannot satisfy the quiet predicate.
    public static func isIdle(_ t: Task) -> Bool { t.workInFlight == false }

    /// "Nothing more is going to happen here on its own": concluded or dead, AND with no queued work.
    /// A card with a pending delivery is imminently active even while it reads idle, which is why the
    /// delivery bit belongs in this predicate rather than beside it.
    public static func isSettled(_ t: Task) -> Bool {
        (isIdle(t) || t.phase.kind == .dead) && !t.hasPendingDelivery
    }

    // MARK: - the fold

    /// Every reason `c` owns right now, most-urgent first.
    ///
    /// - `parentOwned`: does a live card own `c`'s merge target? (owned ⇒ the owning agent merges, so
    ///   the wait is quiet business, not the human's).
    /// - `canStall`: false for ATTACHED agents — a reviewer never owns a stall, it surfaces through its
    ///   target's constellation. This gates the whole `isStalled` call, `mergeStalled` included.
    /// - `descendantHoldsAttention`: leaf attachment — see `isStalled`.
    public static func ownReasons(for c: Task,
                                  attached: [Task],
                                  descendants: [Task],
                                  parentOwned: Bool,
                                  canStall: Bool,
                                  descendantHoldsAttention: Bool,
                                  now: Date,
                                  humanPaced: Bool = false,
                                  config: Thresholds = .init()) -> [AttentionSignal] {
        var out: [AttentionSignal] = []

        if c.phase.kind == .dead { out.append(.init(.dead, "dead")) }
        if c.requiresHuman {
            out.append(.init(.humanRequired, humanRequiredLabel(for: c)))
        }
        if c.treeStat?.state == .mergeRequested, !parentOwned {
            out.append(.init(.mergeRequested, "merge-requested"))
        }
        if canStall, let stall = isStalled(c, attached: attached, descendants: descendants,
                                           descendantHoldsAttention: descendantHoldsAttention,
                                           now: now, humanPaced: humanPaced, config: config) {
            out.append(stall)
        }
        if case .live = c.phase, c.ctxPct >= config.ctxCriticalPct {
            out.append(.init(.ctxCritical, "ctx \(Int(c.ctxPct))%"))
        }

        return out.sorted { $0.reason.rawValue < $1.reason.rawValue }
    }

    private static func humanRequiredLabel(for task: Task) -> String {
        switch task.agentState?.humanNeed {
        case .permission: return "permission"
        case .input: return "input needed"
        case .unspecified: return "action needed"
        case nil: return "question"
        }
    }

    // MARK: - chip text (pure, so the strings are testable without a view)

    /// The OWN chip's text: the top-priority label, with the rest folded into a "+N". nil ⇒ the card is
    /// quiet and NOTHING renders — absence is the information, so there is no empty-chip state.
    public static func chipText(_ signals: [AttentionSignal]) -> String? {
        guard let top = signals.first else { return nil }
        return signals.count > 1 ? "\(top.label) +\(signals.count - 1)" : top.label
    }

    /// The SUBTREE chip's text — how many descendant CARDS need you. nil below 1, same reason.
    public static func subtreeChipText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 needs you" : "\(count) need you"
    }

    /// The stall row: the generic detector AND the safety net. A conjunction — every guard below is a
    /// separate way for the quiet to be EXPLAINED, and an explained quiet is not a stall.
    ///
    /// Order is deliberate; the numbered steps mirror the design doc's conjunction.
    public static func isStalled(_ c: Task,
                                 attached: [Task],
                                 descendants: [Task],
                                 descendantHoldsAttention: Bool,
                                 now: Date,
                                 humanPaced: Bool,
                                 config: Thresholds) -> AttentionSignal? {
        // 1. Only a concluded card can stall, and never one the human is pacing. `humanPaced` carries BOTH
        //    forms of that as one bit: the human DROVE it last (typed/sent), or it is a card awaiting the
        //    human's first move (a promptless "New agent" card — the daemon sets the bit at that launch, and
        //    migrates legacy `awaitingFirstPrompt` cards on decode). A seed-spawned or agent-delivered card
        //    is NOT human-paced, so it stays stall-eligible — which is what keeps an agent-driven card that
        //    never cleared `awaitingFirstPrompt` (e.g. a Codex provisional card given work) in the net. This
        //    gate also keeps a card that RESUMED running while carrying a stale `mergeStalled` flag out of
        //    step 2.
        guard isIdle(c), !humanPaced else { return nil }

        // 2. `mergeStalled` is a PRE-COMPUTED daemon input, not an emergent quiet: the merge-request
        //    loop already gave up on the parent, so it fires immediately with a sharper label —
        //    ahead of the declared-state suppression below, since it rides ALONGSIDE the very
        //    `mergeRequested` state that would otherwise exempt it.
        if c.treeStat?.mergeStalled == true { return .init(.stalled, "merge stalled") }

        // 3. A DECLARED state explains the quiet, including the non-amber one: a child merge-requested
        //    into an owned parent wears a grey ⏱ and is the owning agent's business (rot there is
        //    step 2's job, not this row's). A pending question likewise — and if the agent forgets to
        //    re-declare, the question clears and the card falls through to the net next pass.
        guard !c.requiresHuman,
              c.treeStat?.state != .mergeRequested
        else { return nil }

        // 4. The constellation (the card + its attached agents) must be quiet, and nothing in the
        //    subtree may still be moving. Descendants gate by ACTIVITY only — their timestamps never
        //    move this card's clock (step 6).
        guard !c.hasPendingDelivery else { return nil }
        guard attached.allSatisfy(isSettled) else { return nil }
        guard descendants.allSatisfy(isSettled) else { return nil }

        // 5. LEAF ATTACHMENT — one fact, one amber, aggregated once. When a whole tree goes quiet the
        //    amber attaches at the cards that actually stopped; an ancestor whose descendants already
        //    hold attention reports them through its L4 rollup instead of adding a second amber for
        //    the same silence. (A drained root's children merged away, so it has none left and still
        //    owns its own "wave done" nudge.)
        guard !descendantHoldsAttention else { return nil }

        // 6. The timer, over the CONSTELLATION: this card and its attached agents. `phaseChangedAt`
        //    alone would miss a card touched without a phase change, so take the newer of the two.
        let newest = ([c] + attached).map { max($0.phaseChangedAt, $0.updatedAt) }.max() ?? c.phaseChangedAt
        let quietFor = now.timeIntervalSince(newest)
        guard quietFor > config.stallAfter else { return nil }

        // 7. A drained tree that has gone quiet is a NUDGE — reason plus proposal. It never acts on
        //    its own; moving the card is always the human's call.
        if c.treeStat?.drained == true { return .init(.stalled, "wave done — move to Review?") }
        return .init(.stalled, "stalled \(compactDuration(quietFor))")
    }
}
