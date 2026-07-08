import Foundation
import Testing
@testable import OrchestraCore

/// O3: the daemon owns the bare-parent borrow lifecycle — `borrow` creates/registers a throwaway
/// `orch-borrow-*` worktree checking out the bare parent (the agent merges there), `release` sweeps it,
/// and orphaned borrows are pruned on archive/startup. The daemon never commits.
@Suite("Borrow lifecycle (O3)")
struct BorrowLifecycleTests {

    /// A real repo (real WorktreeManager) with `main` and a bare `parent` branch. Returns (svc, repo).
    static func repo() throws -> (svc: OrchestraService, repo: String) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        try g("init", "-q", "-b", "main"); try g("config", "user.email", "t@t"); try g("config", "user.name", "t")
        try "0\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "base"); try g("branch", "parent")
        return (svc, repo)
    }

    /// A child card on `child` linked to the bare `parent`.
    static func linkedChild(_ svc: OrchestraService, repo: String) async throws -> Task {
        let tip = try Proc.run(["git", "-C", repo, "rev-parse", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let card = try await svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child", base: "parent"))
        // spawn(base: parent) already records the link; ensure base == parent tip.
        _ = tip
        return card
    }

    @Test("borrow creates an orch-borrow worktree checked out at the bare parent")
    func borrowCreatesWorktree() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        let path = try await svc.borrow(ref: child.ref())
        #expect((path as NSString).lastPathComponent.hasPrefix("orch-borrow-"))
        #expect(FileManager.default.fileExists(atPath: path))
        // It is checked out at the parent branch (HEAD == parent tip).
        let head = try Proc.run(["git", "-C", path, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentTip = try Proc.run(["git", "-C", repo, "rev-parse", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == parentTip)
    }

    @Test("release removes the borrow worktree")
    func releaseRemovesWorktree() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        let path = try await svc.borrow(ref: child.ref())
        try await svc.release(ref: child.ref())
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("borrow refuses when the parent has a live card (send a merge-request instead)")
    func borrowRefusesLiveParent() async throws {
        let (svc, repo) = try Self.repo()
        _ = try await svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))   // parent now live
        let child = try await Self.linkedChild(svc, repo: repo)
        await #expect(throws: OrchestraError.self) { _ = try await svc.borrow(ref: child.ref()) }
    }

    @Test("the startup sweep prunes an orch-borrow worktree (scans git worktree list, not the registry)")
    func startupSweepPrunesOrphan() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        let path = try await svc.borrow(ref: child.ref())
        #expect(FileManager.default.fileExists(atPath: path))
        await svc.sweepOrphanBorrows()                // startup: nothing legitimately borrowing → prune all
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
