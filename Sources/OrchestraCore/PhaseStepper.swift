import Foundation

/// A stateless, idempotent driver for ONE transitional phase. The reconciler (a later PR) dispatches by
/// `Phase.Kind`; verbs never reference steppers. A stepper holds NO per-card state — the card arrives as
/// an argument because crash recovery's whole premise is that phase + persisted fields re-derive
/// everything from disk. The four concrete steppers (Materialize/Launch/Relaunch/Teardown) land in PR4b.
public protocol PhaseStepper: Sendable {
    /// The phase this stepper drives toward its target.
    static var drives: Phase.Kind { get }   // creatingWorktree | launching | relaunching | archivedPending
    /// Advance the card one edge toward the target. MUST be idempotent — re-running from the same
    /// persisted phase produces no additional side effect.
    func step(_ card: Task, _ ctx: ConvergeContext) async throws
    /// Has the target been reached? The crash-convergence oracle (PR4b's matrix tests).
    func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool
}

/// A plain dependency bundle handed to every stepper, so steppers are testable with stubs and steppable
/// off the service actor. Carries no behavior — just references to the real machinery.
public struct ConvergeContext: Sendable {
    public let store: TaskStore
    public let worktrees: WorktreeRegistry
    public let sessions: any SessionManaging
    public let adapters: AgentRegistry
    /// The sole `phase` writer, closed over the service actor. Steppers make progress ONLY through here.
    public let transition: @Sendable (_ id: UUID, _ to: Phase, _ observedEpoch: Int?) async -> TransitionResult

    public init(store: TaskStore, worktrees: WorktreeRegistry, sessions: any SessionManaging,
                adapters: AgentRegistry,
                transition: @escaping @Sendable (UUID, Phase, Int?) async -> TransitionResult) {
        self.store = store; self.worktrees = worktrees; self.sessions = sessions
        self.adapters = adapters; self.transition = transition
    }
}

/// The reconciler-owned `Phase.Kind → PhaseStepper` map. EMPTY in PR4a — the four real steppers plug in
/// here in PR4b. Kept as a single named seam so PR4b is a one-line registration, not a structural change.
enum PhaseSteppers {
    static let byKind: [Phase.Kind: any PhaseStepper] = [:]
}
