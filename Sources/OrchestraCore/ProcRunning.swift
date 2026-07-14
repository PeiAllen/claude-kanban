import Foundation

/// The seam production code forks subprocesses through. `Proc` remains the mechanism; this is
/// the injectable boundary — components that shell out (BranchLineage, RemoteParents, the tree/
/// parent-ref git probes) take a `ProcRunning` so unit tests substitute a scripted, gateable fake.
///
/// **Async on purpose:** `BranchLineage` and `RemoteParents` are actors calling this seam from
/// isolated methods. A blocking gate there would wedge the actor's cooperative-pool thread and
/// deadlock any test that next awaits the same actor; an async seam lets the fake SUSPEND at a
/// gate while `RealProc` runs blocking `Proc.run` inline — today's thread semantics exactly.
///
/// **Timeout contract:** `nil` means truly unbounded, exactly like `Proc.run` (see Proc.swift's
/// timeout note). Call sites converted from `Proc.run`'s implicit default pass `.seconds(120)`
/// explicitly.
///
/// Launch-time forks (Launcher, adapters, SessionManager, daemon lifecycle) stay on `Proc`
/// directly: unit tests never reach them — they are stubbed at their own protocol seams
/// (SessionManaging, the adapter registry), and their real behavior is contract/e2e territory.
public protocol ProcRunning: Sendable {
    @discardableResult
    func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult
}

/// Production implementation — a pass-through to `Proc.run`, preserving its blocking semantics
/// (the calling thread blocks for the child's lifetime, exactly as before this seam existed)
/// and its `nil == unbounded` timeout contract.
public struct RealProc: ProcRunning {
    public init() {}
    @discardableResult
    public func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
        try Proc.run(argv, cwd: cwd, env: env, timeout: timeout)
    }
}
