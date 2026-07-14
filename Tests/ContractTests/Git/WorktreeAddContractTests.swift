//
// The real-worktree fidelity pin for the card-lifecycle movers (Task 10, card-lifecycle). The unit tier
// cuts NO worktree — `StubWorktrees.ensure` records a fake path and `RepoGraph` models the commit DAG —
// so the behaviors those stubs stand in for are pinned here against real `git worktree add`/`remove`:
//
//   - `add -b <branch> <path>`            → a worktree dir on disk + a NEW branch at HEAD (the plain spawn).
//   - `add -b <branch> <path> <base>`     → the new branch starts AT <base>'s tip (HEAD == base tip): the
//                                           real effect behind every mover's "child worktree HEAD == the
//                                           base/fetched tip" assertion (SpawnBase / RemoteSpawn movers).
//   - `add -b <branch> <path> <bad-base>` → FAILS, leaving NO worktree dir and NO `refs/heads/<branch>`:
//                                           the on-disk half of SpawnBaseValidation's bad-base rejection
//                                           (its throw half is unit-tested; the branch-not-created-on-disk
//                                           half lives here).
//   - `add -b <branch> <path> <base>` where a same-named TAG also exists → starts at the BRANCH, not the
//                                           tag (local-branch-preferred base resolution).
//   - `remove <path>`                     → the dir is gone but `refs/heads/<branch>` survives (the release
//                                           policy the TeardownStepper's stub `remove` stands in for).
//
// Subsumes today's WorktreeRegistryIntegrationTests worktree-add/remove essence (that file is retired by
// the flip task, not here).

import Foundation
import Testing
@testable import OrchestraCore

@Suite("Contract: git worktree add / remove / bad-base", .enabled(if: IntegrationSupport.gitAvailable))
struct WorktreeAddContractTests {

    /// A real repo on `main` (one base commit) plus a `base` branch carrying an EXTRA commit, so its tip
    /// differs from main's. Returns the repo dir, a worktrees dir, and `base`'s tip OID.
    private func realRepo() throws -> (repo: String, wt: String, baseTip: String) {
        let root = NSTemporaryDirectory() + "wtadd-contract-\(UUID().uuidString)"
        let repo = root + "/repo"
        let wt = root + "/worktrees"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        func git(_ a: String...) throws -> String {
            let r = try Proc.run(["git", "-C", repo] + a)
            #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ s: String, _ rel: String) throws { try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8) }
        _ = try git("init", "-q", "-b", "main")
        _ = try git("config", "user.email", "t@t"); _ = try git("config", "user.name", "t")
        try write("0\n", "a.txt"); _ = try git("add", "-A"); _ = try git("commit", "-q", "-m", "base")
        _ = try git("branch", "base")
        _ = try git("checkout", "-q", "base")
        try write("1\n", "b.txt"); _ = try git("add", "-A"); _ = try git("commit", "-q", "-m", "on base")
        let baseTip = try git("rev-parse", "refs/heads/base")
        _ = try git("checkout", "-q", "main")
        return (repo, wt, baseTip)
    }

    private func head(_ dir: String) throws -> String {
        try Proc.run(["git", "-C", dir, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func branchExists(_ repo: String, _ branch: String) throws -> Bool {
        try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
    }

    @Test("add -b <branch> <path> creates a worktree dir and a new branch at HEAD")
    func addNewBranch() throws {
        let (repo, wt, _) = try realRepo()
        let mainTip = try Proc.run(["git", "-C", repo, "rev-parse", "refs/heads/main"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = wt + "/feature"
        let r = try Proc.run(["git", "-C", repo, "worktree", "add", "-b", "feature", path])
        #expect(r.ok, "\(r.stderr)")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try branchExists(repo, "feature"))
        #expect(try head(path) == mainTip)   // a fresh -b branch starts at HEAD (main's tip)
    }

    @Test("add -b <branch> <path> <base> starts the branch AT the base's tip")
    func addAtBase() throws {
        let (repo, wt, baseTip) = try realRepo()
        let path = wt + "/child"
        let r = try Proc.run(["git", "-C", repo, "worktree", "add", "-b", "child", path, "base"])
        #expect(r.ok, "\(r.stderr)")
        #expect(try head(path) == baseTip)   // HEAD == base tip — the movers' "started at the base" pin
        #expect(try branchExists(repo, "child"))
    }

    @Test("add -b <branch> <path> <bad-base> fails, leaving no worktree dir and no branch")
    func addBadBaseRejected() throws {
        let (repo, wt, _) = try realRepo()
        let path = wt + "/child"
        let r = try Proc.run(["git", "-C", repo, "worktree", "add", "-b", "child", path, "does-not-exist"])
        #expect(!r.ok)                                        // git refuses an unresolvable start-point
        #expect(!FileManager.default.fileExists(atPath: path))   // no half-created worktree dir
        #expect(try branchExists(repo, "child") == false)        // and no orphan branch a retry could adopt
    }

    @Test("add -b starting at a base that is ALSO a tag name resolves to the local branch")
    func addBasePrefersLocalBranchOverTag() throws {
        let (repo, wt, baseTip) = try realRepo()
        // A TAG named `base` at main's tip (a DIFFERENT OID than the `base` branch's tip). Real git's
        // start-point resolution prefers the branch, so the child must start at the branch tip.
        _ = try Proc.run(["git", "-C", repo, "tag", "base-tag-alias", "main"])   // sanity: main != baseTip
        let r0 = try Proc.run(["git", "-C", repo, "tag", "base", "main"])
        #expect(r0.ok, "\(r0.stderr)")
        let path = wt + "/child"
        let r = try Proc.run(["git", "-C", repo, "worktree", "add", "-b", "child", path, "refs/heads/base"])
        #expect(r.ok, "\(r.stderr)")
        #expect(try head(path) == baseTip)   // the BRANCH tip, not the tag's (main) OID
    }

    @Test("remove <path> deletes the worktree dir but keeps the branch")
    func removeKeepsBranch() throws {
        let (repo, wt, _) = try realRepo()
        let path = wt + "/feature"
        #expect(try Proc.run(["git", "-C", repo, "worktree", "add", "-b", "feature", path]).ok)
        let r = try Proc.run(["git", "-C", repo, "worktree", "remove", path])
        #expect(r.ok, "\(r.stderr)")
        #expect(!FileManager.default.fileExists(atPath: path))   // dir reclaimed
        #expect(try branchExists(repo, "feature"))               // branch survives the worktree removal
    }
}
