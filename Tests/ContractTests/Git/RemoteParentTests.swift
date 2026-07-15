//
// Whole-suite contract candidate (Task 10, remote-git): every case drives `RemoteParents` against a REAL
// bare `file://` origin and asserts on real remote effects — a `fetch` that lands a real OID into
// `refs/orch/parents/…`, a `+` refspec forcing past a real non-ff history rewrite, `ls-remote` returning
// the real tip and `.gone` after a real `update-ref -d`. These ARE the fetch/ls-remote fidelity the new
// RemoteFetchContractTests pins as a matrix; the suite stays real git and relocates verbatim at the flip.
//
// LEGACY real-git fixture: `makeOriginWithPR` / `git` / `write` / `oid` are still consumed by the
// not-yet-converted card-lifecycle suite StepperConvergeTests (and the RemoteSpawnTests mover) — grep
// `RemoteParentTests.` before deleting. They are removed once those areas convert.

import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteParents — fetch/lsRemoteTip over a bare file:// origin (no network)")
struct RemoteParentTests {

    @discardableResult
    static func git(_ dir: String, _ a: String...) throws -> ProcResult {
        let r = try Proc.run(["git", "-C", dir] + a)
        #expect(r.ok, "git \(a.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }
    static func write(_ dir: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: dir + "/" + rel, atomically: true, encoding: .utf8)
    }
    static func oid(_ dir: String, _ ref: String) throws -> String {
        try Proc.run(["git", "-C", dir, "rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A working repo with a bare `origin`, plus a hand-minted `refs/pull/7/head` and a `feature-b`
    /// branch on the bare side. Returns (working repo path, bare path). No network. `repoDir` lets a
    /// caller place the working repo somewhere allowlisted (the real-service tests); the bare origin is
    /// always a sibling temp dir (its location is irrelevant to the allowlist — only fetch reads it).
    static func makeOriginWithPR(repoDir: String? = nil) throws -> (repo: String, bare: String) {
        let tmp = NSTemporaryDirectory()
        let repo = repoDir ?? (tmp + "orch-rem-\(UUID().uuidString)")
        let bare = tmp + "orch-bare-\(UUID().uuidString).git"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t"); try git(repo, "config", "user.name", "t")
        try write(repo, "a.txt", "one\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "base")
        try Proc.run(["git", "init", "--bare", "-q", bare])
        try git(repo, "remote", "add", "origin", "file://" + bare)
        try git(repo, "push", "-q", "origin", "main")
        // A PR head branch pushed under a normal ref, then re-pointed as refs/pull/7/head in the bare repo.
        try git(repo, "checkout", "-q", "-b", "pr-src")
        try write(repo, "p.txt", "pr work\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "pr work")
        try git(repo, "push", "-q", "origin", "pr-src:refs/heads/feature-b")
        let prTip = try oid(repo, "HEAD")
        try git(bare, "update-ref", "refs/pull/7/head", prTip)   // mint the PR ref on the bare side
        try git(repo, "checkout", "-q", "main")
        return (repo, bare)
    }

    @Test("remoteEnv disables credential prompts")
    func envHardened() {
        let e = RemoteParents.remoteEnv()
        #expect(e["GIT_TERMINAL_PROMPT"] == "0")
        #expect(e["GIT_ASKPASS"] == "/usr/bin/false")
    }

    @Test("fetch(pr#7) lands the PR head in refs/orch/parents/pr/7 and returns its OID")
    func fetchPR() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        let prTip = try Self.oid(bare, "refs/pull/7/head")
        let oid = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))
        #expect(oid == prTip)
        #expect(try Self.oid(repo, "refs/orch/parents/pr/7") == prTip)
    }

    @Test("force refspec survives a remote history rewrite")
    func fetchForce() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        _ = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))
        // Rewrite the PR head to an unrelated commit (non-fast-forward), then re-point the PR ref.
        try Self.git(repo, "checkout", "-q", "pr-src")
        try Self.write(repo, "z.txt", "rewrite\n"); try Self.git(repo, "add", "-A")
        try Self.git(repo, "commit", "-q", "--amend", "-m", "rewritten")
        let newTip = try Self.oid(repo, "HEAD")
        // Land the rewritten object in the bare first (update-ref needs the object present there).
        try Self.git(repo, "push", "-q", "-f", "origin", "pr-src:refs/heads/feature-b")
        try Self.git(bare, "update-ref", "refs/pull/7/head", newTip)
        try Self.git(repo, "checkout", "-q", "main")
        let oid2 = try await RemoteParents(proc: RealProc()).fetch(repo: repo, .pullRequest(7))
        #expect(oid2 == newTip)   // the + refspec forced past the non-ff rewrite
        #expect(try Self.oid(repo, "refs/orch/parents/pr/7") == newTip)
    }

    @Test("lsRemoteTip returns the tip OID, and .gone for a deleted branch")
    func lsRemote() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        let tip = try Self.oid(bare, "refs/heads/feature-b")
        #expect(await RemoteParents(proc: RealProc()).lsRemoteTip(repo: repo, .branch(remote: "origin", name: "feature-b")) == .oid(tip))
        try Self.git(bare, "update-ref", "-d", "refs/heads/feature-b")   // delete on the remote
        #expect(await RemoteParents(proc: RealProc()).lsRemoteTip(repo: repo, .branch(remote: "origin", name: "feature-b")) == .gone)
    }
}
