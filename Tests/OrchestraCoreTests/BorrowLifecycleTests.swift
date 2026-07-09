import Foundation
import Testing
@testable import OrchestraCore

/// O3: the daemon owns the bare-parent borrow lifecycle — `borrow` creates/registers a throwaway
/// `orch-borrow-*` worktree checking out the bare parent (the agent merges there), `release` sweeps it,
/// and orphaned borrows are pruned on archive/startup. The daemon never commits.
@Suite("Borrow lifecycle (O3)")
struct BorrowLifecycleTests {

    /// A real repo (real worktree manager, via the registry) with `main` and a bare `parent` branch.
    /// Returns (svc, repo).
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

    /// A second sibling child on `branch`, also linked to the bare `parent`.
    static func sibling(_ svc: OrchestraService, repo: String, branch: String) async throws -> Task {
        try await svc.spawn(SpawnInput(prompt: branch, repo: repo, branch: branch, base: "parent"))
    }

    // MARK: exactly-one-borrower (OrchestraService.borrow ownership)

    @Test("the same child re-borrowing its own parent is idempotent — same path, no error")
    func sameChildReborrowIsIdempotent() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        let p1 = try await svc.borrow(ref: child.ref())
        let p2 = try await svc.borrow(ref: child.ref())   // idempotent — must not refuse itself
        #expect(p1 == p2)
        #expect(FileManager.default.fileExists(atPath: p2))
    }

    @Test("a second child borrowing the same bare parent is refused with actionable guidance (no shared tree)")
    func siblingBorrowRefused() async throws {
        let (svc, repo) = try Self.repo()
        let b = try await Self.linkedChild(svc, repo: repo)
        let held = try await svc.borrow(ref: b.ref())
        let c = try await Self.sibling(svc, repo: repo, branch: "child2")
        do {
            _ = try await svc.borrow(ref: c.ref())
            Issue.record("expected the sibling borrow to be refused, not handed the shared worktree")
        } catch let e as OrchestraError {
            let msg = "\(e)"
            #expect(msg.contains("already borrowed"), "not classified: \(msg)")
            #expect(msg.contains("retry your ship"), "no actionable next step: \(msg)")
        }
        #expect(FileManager.default.fileExists(atPath: held))            // B's tree untouched
        #expect(try Proc.run(["git", "-C", held, "rev-parse", "HEAD"]).ok)
    }

    @Test("release by a non-holder is a no-op — it never removes the borrow another child holds")
    func releaseByNonHolderIsNoop() async throws {
        let (svc, repo) = try Self.repo()
        let b = try await Self.linkedChild(svc, repo: repo)
        let held = try await svc.borrow(ref: b.ref())
        let c = try await Self.sibling(svc, repo: repo, branch: "child2")   // never borrowed
        try await svc.release(ref: c.ref())                                 // must not touch B's tree
        #expect(FileManager.default.fileExists(atPath: held))
    }

    @Test("borrow refuses a stray, unregistered borrow dir (post-restart; the sweep is the recovery)")
    func borrowRefusesUnregisteredStrayDir() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        // A crashed / pre-sweep borrow: the canonical orch-borrow dir is checked out on disk, but the
        // daemon holds no registration for it (as right after a restart, before the startup sweep runs).
        let path = await svc.worktrees.borrowPath(repo: repo, branch: "parent")
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(try Proc.run(["git", "-C", repo, "worktree", "add", path, "parent"]).ok)
        do {
            _ = try await svc.borrow(ref: child.ref())
            Issue.record("expected borrow to refuse a stray, unregistered borrow dir")
        } catch let e as OrchestraError {
            #expect("\(e)".contains("already borrowed"))
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // MARK: WorktreeRegistry / manager `borrow` error classification (defense-in-depth wording)

    @Test("borrow classifies a rival orch-borrow checkout into actionable guidance, not a raw git error")
    func worktreeBorrowClassifiesRival() async throws {
        let (svc, repo) = try Self.repo()
        // The bare parent is checked out in an `orch-borrow-*` worktree at a path distinct from ours, so
        // the borrow reaches `git worktree add` and git refuses the checkout. Drive the registry's
        // `ensureBorrow` directly (bypassing the `OrchestraService.borrow(ref:)` ownership layer, which
        // needs a linked child card) — with no registration for the canonical path yet, it reaches the
        // manager's raw classification just like the pre-privatization direct-manager call did.
        let landing = await svc.worktrees.borrowPath(repo: repo, branch: "parent") + "-landing"
        try FileManager.default.createDirectory(
            atPath: (landing as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(try Proc.run(["git", "-C", repo, "worktree", "add", landing, "parent"]).ok)
        do {
            _ = try await svc.worktrees.ensureBorrow(repo: repo, parentBranch: "parent", borrowerCardId: UUID())
            Issue.record("expected borrow to throw while the parent is already borrowed")
        } catch let e as OrchestraError {
            let msg = "\(e)"
            #expect(msg.contains("already borrowed"), "not classified: \(msg)")
            #expect(msg.contains("retry your ship"), "no actionable next step: \(msg)")
        }
    }

    @Test("borrow keeps the plain branchInUse wording when the parent sits in a non-borrow worktree")
    func worktreeBorrowFallsBackToBranchInUse() async throws {
        let (svc, repo) = try Self.repo()
        // Parent checked out in an ordinary (non `orch-borrow-*`) worktree ⇒ no landing-sibling guidance.
        let other = (repo as NSString).deletingLastPathComponent + "/sib-normal"
        #expect(try Proc.run(["git", "-C", repo, "worktree", "add", other, "parent"]).ok)
        do {
            _ = try await svc.worktrees.ensureBorrow(repo: repo, parentBranch: "parent", borrowerCardId: UUID())
            Issue.record("expected borrow to throw while the parent is checked out elsewhere")
        } catch let e as OrchestraError {
            let msg = "\(e)"
            #expect(!msg.contains("already borrowed"), "should not claim a borrow: \(msg)")
            #expect(msg.contains("already checked out"), "lost the plain branchInUse wording: \(msg)")
        }
    }

    @Test("the startup sweep prunes an unregistered stray orch-borrow worktree (crashed borrow, no registration)")
    func startupSweepPrunesOrphan() async throws {
        // Task 3.4/3.5: `sweepOrphanBorrows` is now LIVENESS-GUARDED (routed through the registry) — a
        // borrow whose borrower card is still live is KEPT, not blindly pruned (that used to be a real
        // bug: a blunt "nothing is legitimately borrowing" sweep could yank a tree out from under an
        // in-flight squash-merge). So the orphan this sweep reclaims is the REALISTIC post-crash case: a
        // canonical `orch-borrow-*` dir checked out on disk with no registration for it (as right after a
        // restart, before any daemon-side `borrow` re-registers it) — mirrors `borrowRefusesUnregisteredStrayDir`.
        let (svc, repo) = try Self.repo()
        _ = try await Self.linkedChild(svc, repo: repo)   // a live .worktree card in this repo, so the repo gets swept
        let path = await svc.worktrees.borrowPath(repo: repo, branch: "parent")
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(try Proc.run(["git", "-C", repo, "worktree", "add", path, "parent"]).ok)
        #expect(FileManager.default.fileExists(atPath: path))
        await svc.sweepOrphanBorrows()                // stray + unregistered ⇒ pruned
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("the startup sweep KEEPS a registered borrow whose borrower card is still live")
    func startupSweepKeepsLiveBorrow() async throws {
        let (svc, repo) = try Self.repo()
        let child = try await Self.linkedChild(svc, repo: repo)
        let path = try await svc.borrow(ref: child.ref())
        #expect(FileManager.default.fileExists(atPath: path))
        await svc.sweepOrphanBorrows()                // child is live ⇒ referenced ⇒ kept
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
