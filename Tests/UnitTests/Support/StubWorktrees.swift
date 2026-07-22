import Foundation
import TestSupport
@testable import OrchestraCore

/// In-memory worktree stub — never touches git.
final class StubWorktrees: WorktreeManaging, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private(set) var removed: [String] = []
    private(set) var ensured: [String] = []   // repo+branch pairs ensure() was called for
    private var existingBranches: Set<String> = []   // branches ensure() should report as pre-existing
    /// Deterministic rendezvous inside `ensure` (`git worktree add`), so concurrent-`ensure` tests can
    /// genuinely contend on the actor: the stub PARKS (blocking, bounded — the same thread semantics as
    /// the sleep knob it replaced) until the test `release()`s it. Sync seam ⇒ `SyncGate`, not `Gate`.
    var ensureGate: SyncGate? = nil
    init(root: String) { self.root = root }

    /// A test-armed gate proving an RPC can return WHILE `ensure` is still provisioning: `blockEnsure`
    /// parks the next `ensure` call on a semaphore (bounded by a safety timeout so a mis-armed test can't
    /// hang the suite); `releaseEnsure` opens it. Distinct from `ensureGate` (a test-scheduled rendezvous).
    private let blockEnsureSem = DispatchSemaphore(value: 0)
    private var ensureBlocked = false
    func blockEnsure() { lock.lock(); ensureBlocked = true; lock.unlock() }
    func releaseEnsure() {
        lock.lock(); let wasBlocked = ensureBlocked; ensureBlocked = false; lock.unlock()
        if wasBlocked { blockEnsureSem.signal() }
    }

    /// Mark a branch as pre-existing so `ensure` reports `branchExisted = true` (the churn scenario:
    /// re-spawn onto a branch whose worktree was removed but whose branch + lineage config remain).
    func markBranchExists(_ branch: String) {
        lock.lock(); existingBranches.insert(branch); lock.unlock()
    }

    func path(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/\(branch)"
    }
    private(set) var ensuredBases: [String: String?] = [:]   // branch -> base ensure() saw
    /// When set, `ensure` throws it (drives the materialize failure-classification tests). An error whose
    /// description contains "timed out" exercises the explicit timeout wording.
    var ensureError: Error?
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        lock.lock()
        ensured.append("\(repo)#\(branch)")
        ensuredBases[branch] = base
        let existed = existingBranches.contains(branch)
        let blocked = ensureBlocked
        let err = ensureError
        lock.unlock()
        if let err { throw err }
        if let g = ensureGate { g.parkBlocking() }
        if blocked { _ = blockEnsureSem.wait(timeout: .now() + .seconds(30)) }   // parked until releaseEnsure (safety-bounded)
        let wt = path(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return (wt, true, existed)
    }
    /// `(path, force)` pairs, in call order — the rollback-routing test discriminates old `force:true`
    /// callers from new `force:false` callers.
    private(set) var removedForce: [(path: String, force: Bool)] = []
    func remove(worktree: String, force: Bool) throws {
        lock.lock(); removed.append(worktree); removedForce.append((worktree, force)); lock.unlock()
        try? FileManager.default.removeItem(atPath: worktree)
    }
    // O3 borrow stub — mkdir a fake borrow dir; real git behavior is covered by the real-git
    // BorrowLifecycleTests in the contract tier.
    func borrowPath(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/orch-borrow-\(branch.replacingOccurrences(of: "/", with: "-"))"
    }
    func borrow(repo: String, branch: String) throws -> String {
        let wt = borrowPath(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return wt
    }

    /// Controllable dirty set, driven by `WorktreeRegistryTests` via `setDirty`.
    private var dirtyPaths: Set<String> = []
    func setDirty(_ path: String, _ v: Bool) { lock.lock(); if v { dirtyPaths.insert(path) } else { dirtyPaths.remove(path) }; lock.unlock() }
    func isDirty(worktree: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirtyPaths.contains(worktree) }

    /// Controllable unsaved-work set — the RELEASE-path predicate, independent of `isDirty` (which the
    /// ensure path still consults). Default clean, mirroring the old dirty default.
    private var unsavedPaths: Set<String> = []
    func setUnsavedWork(_ path: String, _ v: Bool) { lock.lock(); if v { unsavedPaths.insert(path) } else { unsavedPaths.remove(path) }; lock.unlock() }
    func hasUnsavedWork(worktree: String) -> Bool { lock.lock(); defer { lock.unlock() }; return unsavedPaths.contains(worktree) }

    private(set) var prunedRepos: [String] = []
    func pruneRegistrations(repo: String) { lock.lock(); prunedRepos.append(repo); lock.unlock() }

    func orphanBorrowPaths(repo: String) -> [String] {
        let dir = "\(root)/\((repo as NSString).lastPathComponent)"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.filter { $0.hasPrefix("orch-borrow-") }.map { "\(dir)/\($0)" }
    }
}

// (`WorktreeManaging` no longer declares `pruneOrphanBorrows` — Task 3.5 dropped it; the registry's
// `sweepOrphanBorrows(cards:)` guarded loop replaced its only caller.)
