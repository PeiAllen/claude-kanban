import Foundation

/// Collaborator protocols so `OrchestraService` can be unit-tested with stubs (no real git/tmux).
/// The concrete `WorktreeManager` / `SessionManager` conform below.

public protocol WorktreeManaging: Sendable {
    func path(repo: String, branch: String) -> String
    /// `branchExisted` = the branch was already present (so the worktree checked it out rather than
    /// cutting a fresh `-b` branch). Lets callers skip work that only applies to pre-existing branches
    /// (e.g. deriving lineage from git config) without a second git query. `base` (BT2) is git's
    /// start-point for a NEWLY-created branch (`git worktree add -b <branch> <wt> <base>`); it is
    /// **ignored** when the branch already exists. nil ⇒ today's HEAD behavior.
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool)
    func remove(worktree: String, force: Bool) throws
    // O3: bare-parent borrow lifecycle.
    func borrowPath(repo: String, branch: String) -> String
    func borrow(repo: String, branch: String) throws -> String
    func pruneOrphanBorrows(repo: String)
}

public extension WorktreeManaging {
    /// Convenience for callers that never branch-from-a-base (recovery/rebuild): defaults `base` to nil.
    @discardableResult
    func ensure(repo: String, branch: String) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        try ensure(repo: repo, branch: branch, base: nil)
    }
}

/// Liveness of a card's `agent` pane — finer-grained than session presence. `.dead` (the pane's process
/// exited but the tmux session persists) is only observable when `remain-on-exit` is ON; it is the signal
/// that distinguishes a startup abort (a launch that exited immediately, with its stderr still on the
/// pane) from a genuine mid-run session vanish (`.gone`).
public enum PaneLiveness: Sendable { case alive, dead, gone }

public protocol SessionManaging: Sendable {
    func sessionName(_ id: UUID) -> String
    @discardableResult
    func ensure(_ task: Task, argv: [String], env: [String: String]) throws -> (name: String, created: Bool)
    func isAlive(_ name: String) throws -> Bool
    /// Liveness of the card's `agent` pane (see `PaneLiveness`).
    func agentPaneState(_ name: String) throws -> PaneLiveness
    /// Toggle a window's `remain-on-exit` so an exiting process leaves its dead pane (+ final output) in
    /// place instead of tmux tearing the session down — armed on the `agent` window during the spawn grace.
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws
    @discardableResult
    func newShellWindow(_ name: String, cwd: String) throws -> String
    @discardableResult
    func ensureShellWindow(_ name: String, window: String, cwd: String) throws -> String
    func closeShellWindow(_ name: String, window: String) throws
    func windows(_ name: String) throws -> [TmuxTarget]
    func list() throws -> [SessionInfo]
    func sendKeys(_ name: String, text: String, window: String) throws
    func sendChord(_ name: String, tokens: [KeyToken], window: String) throws
    func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult
    func kill(_ name: String) throws
    func detachAgentViewClients(_ base: String) throws
}

public extension SessionManaging {
    /// Default: session-presence only (never reports `.dead`) — a conformer without pane introspection.
    /// The real `SessionManager` overrides with a `#{pane_dead}` query; `StubSessions` models it in tests.
    func agentPaneState(_ name: String) throws -> PaneLiveness {
        (try? isAlive(name)) == true ? .alive : .gone
    }
    /// Default no-op so conformers/mocks needn't implement it; `SessionManager` overrides with tmux.
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws {}
    // Default so test stubs needn't implement it; the real `SessionManager` overrides.
    func closeShellWindow(_ name: String, window: String) throws {}
    /// Default so test stubs needn't implement it; the real `SessionManager` overrides with an
    /// idempotent tmux create-or-reuse. The default just echoes the requested window name.
    @discardableResult
    func ensureShellWindow(_ name: String, window: String, cwd: String) throws -> String { window }
    // Default no-op so mocks/conformers needn't implement it; `SessionManager` overrides with a
    // best-effort tmux detach. Belt-and-suspenders behind the D5 desktop unmount.
    func detachAgentViewClients(_ base: String) throws {}
    /// Convenience: launch with no extra environment (keep-alive shells + existing callers/tests).
    @discardableResult
    func ensure(_ task: Task, argv: [String]) throws -> (name: String, created: Bool) {
        try ensure(task, argv: argv, env: [:])
    }
}

extension WorktreeManager: WorktreeManaging {}
extension SessionManager: SessionManaging {}
