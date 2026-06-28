import Foundation

/// Collaborator protocols so `OrchestraService` can be unit-tested with stubs (no real git/tmux).
/// The concrete `WorktreeManager` / `SessionManager` conform below.

public protocol WorktreeManaging: Sendable {
    func path(repo: String, branch: String) -> String
    func ensure(repo: String, branch: String) throws -> (worktree: String, created: Bool)
    func remove(worktree: String, force: Bool) throws
}

public protocol SessionManaging: Sendable {
    func sessionName(_ id: UUID) -> String
    @discardableResult
    func ensure(_ task: Task, argv: [String]) throws -> (name: String, created: Bool)
    func isAlive(_ name: String) throws -> Bool
    @discardableResult
    func newShellWindow(_ name: String, cwd: String) throws -> String
    func closeShellWindow(_ name: String, window: String) throws
    func windows(_ name: String) throws -> [TmuxTarget]
    func list() throws -> [SessionInfo]
    func capture(_ name: String, window: String) throws -> String
    func sendKeys(_ name: String, text: String, window: String) throws
    func kill(_ name: String) throws
}

public extension SessionManaging {
    // Default so test stubs needn't implement it; the real `SessionManager` overrides.
    func closeShellWindow(_ name: String, window: String) throws {}
}

extension WorktreeManager: WorktreeManaging {}
extension SessionManager: SessionManaging {}
