import Foundation

/// Collaborator protocols so `OrchestraService` can be unit-tested with stubs (no real git/tmux).
/// The concrete `WorktreeManager` / `SessionManager` conform below.

public protocol WorktreeManaging: Sendable {
    func path(repo: String, branch: String) -> String
    /// `branchExisted` = the branch was already present (so the worktree checked it out rather than
    /// cutting a fresh `-b` branch). Lets callers skip work that only applies to pre-existing branches
    /// (e.g. deriving lineage from git config) without a second git query.
    func ensure(repo: String, branch: String) throws -> (worktree: String, created: Bool, branchExisted: Bool)
    func remove(worktree: String, force: Bool) throws
}

public protocol SessionManaging: Sendable {
    func sessionName(_ id: UUID) -> String
    @discardableResult
    func ensure(_ task: Task, argv: [String], env: [String: String]) throws -> (name: String, created: Bool)
    func isAlive(_ name: String) throws -> Bool
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
