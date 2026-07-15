//
// The license for every RemoteRules-backed unit suite (RemoteRecompute, RemoteWatchLoop, SetParentRemote,
// and the remote-parent portions of the tree tier): it runs the SAME `RemoteRules` rules those suites use
// (imported from TestSupport) AND real `RemoteParents` against a real `--bare` origin over the identical
// reachable / missing-branch / unreachable-path matrix, asserting the two agree on the outcome CLASSES the
// production remote tier branches on — `RemoteParents.fetch` (lands an OID vs throws `.gitIO`) and
// `lsRemoteTip` (`.oid` / `.gone` / `.unavailable`). It also pins the one real-`git remote` wiring the
// converted RemoteParentRefTests.resolvesToPrivateRef could not carry over FakeProc: that a repo's actual
// configured remotes classify `origin/<b>` onto its private ref (O4/S1-1).

import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("Contract: RemoteRules vs real RemoteParents fetch / ls-remote over a --bare origin")
struct RemoteFetchContractTests {

    /// A working repo with a bare `origin` (a real branch `feature-b` + a minted `refs/pull/7/head`) and a
    /// second remote `dead` pointing at a non-existent path (the unreachable case). Mirrors
    /// `RemoteParentTests.makeOriginWithPR` (which lives in another target). Returns the working repo path.
    private func realOrigin() throws -> String {
        let tmp = NSTemporaryDirectory()
        let repo = tmp + "remfetch-contract-\(UUID().uuidString)"
        let bare = tmp + "remfetch-bare-\(UUID().uuidString).git"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ dir: String, _ a: String...) throws {
            let r = try Proc.run(["git", "-C", dir] + a)
            #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
        }
        func oid(_ dir: String, _ ref: String) throws -> String {
            try Proc.run(["git", "-C", dir, "rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t"); try git(repo, "config", "user.name", "t")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "base")
        _ = try Proc.run(["git", "init", "--bare", "-q", bare])
        try git(repo, "remote", "add", "origin", "file://" + bare)
        try git(repo, "push", "-q", "origin", "main")
        try git(repo, "checkout", "-q", "-b", "pr-src")
        try "pr\n".write(toFile: repo + "/p.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "pr")
        try git(repo, "push", "-q", "origin", "pr-src:refs/heads/feature-b")
        let prTip = try oid(repo, "HEAD")
        try git(bare, "update-ref", "refs/pull/7/head", prTip)         // mint the PR head on the bare side
        try git(repo, "checkout", "-q", "main")
        try git(repo, "remote", "add", "dead", "file://" + tmp + "no-such-origin-\(UUID().uuidString).git")
        return repo
    }

    private enum TipClass: Equatable { case oid, gone, unavailable }
    private func tipClass(_ t: RemoteTip) -> TipClass {
        switch t { case .oid: return .oid; case .gone: return .gone; case .unavailable: return .unavailable }
    }
    private enum FetchClass: Equatable { case landed, threw }
    private func fetchClass(_ rp: RemoteParents, repo: String, _ ref: RemoteParentRef) async -> FetchClass {
        do { let oid = try await rp.fetch(repo: repo, ref); return oid.isEmpty ? .threw : .landed }
        catch { return .threw }
    }

    /// The raw command Shape (mirrors GitRevContractTests): the exact fields the production remote tier
    /// branches on — exit code EXACTLY (`r.ok`), whether stdout is empty (`lsRemoteTip`'s gone-vs-oid),
    /// and whether stderr is present. Pinned identical between real git and the RepoScripts rule.
    private struct Shape: Equatable { let exit: Int32; let stdoutNonEmpty: Bool; let hasStderr: Bool }
    private func shape(_ r: ProcResult) -> Shape {
        Shape(exit: r.exitCode,
              stdoutNonEmpty: !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hasStderr: !r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("fetch + ls-remote command Shape AND outcome classes match real git for reachable / missing / unreachable")
    func matrix() async throws {
        let repo = try realOrigin()
        let real = RemoteParents(proc: RealProc())

        // The FakeProc side: the SAME RemoteRules objects the unit suites install, modelling this origin.
        let fake = FakeProc()
        let (_, rules) = RepoScripts.withRemote(on: fake)
        rules.reachable(remote: "origin", src: "refs/heads/feature-b")   // reachable branch
        rules.gone(remote: "origin", src: "refs/heads/nope")             // missing branch
        rules.unreachable(remote: "dead", src: "refs/heads/x")           // unreachable path
        let faked = RemoteParents(proc: fake)

        struct Case {
            let label: String; let ref: RemoteParentRef
            let remote: String; let src: String; let priv: String
            let tip: TipClass; let fetch: FetchClass
        }
        let cases = [
            Case(label: "reachable branch", ref: .branch(remote: "origin", name: "feature-b"),
                 remote: "origin", src: "refs/heads/feature-b", priv: "refs/orch/parents/branch/origin/feature-b",
                 tip: .oid, fetch: .landed),
            Case(label: "missing branch", ref: .branch(remote: "origin", name: "nope"),
                 remote: "origin", src: "refs/heads/nope", priv: "refs/orch/parents/branch/origin/nope",
                 tip: .gone, fetch: .threw),
            Case(label: "unreachable path", ref: .branch(remote: "dead", name: "x"),
                 remote: "dead", src: "refs/heads/x", priv: "refs/orch/parents/branch/dead/x",
                 tip: .unavailable, fetch: .threw),
        ]
        let env = RemoteParents.remoteEnv()
        for c in cases {
            // --- Raw command Shape: ls-remote (run the fetch shape AFTER, so the reachable fetch is a new-ref
            //     fetch on both sides — the deterministic stderr-summary case, matching real git). ---
            let lsArgv = ["git", "-C", repo, "ls-remote", c.remote, c.src]
            let rLs = shape(try Proc.run(lsArgv, env: env, timeout: .seconds(20)))
            let fLs = shape(try await fake.run(lsArgv, cwd: nil, env: env, timeout: nil))
            #expect(fLs == rLs, "\(c.label): ls-remote Shape RepoGraph \(fLs) != real git \(rLs)")

            let fetchArgv = ["git", "-C", repo, "fetch", "--no-tags", c.remote, "+\(c.src):\(c.priv)"]
            let rFe = shape(try Proc.run(fetchArgv, env: env, timeout: .seconds(20)))
            let fFe = shape(try await fake.run(fetchArgv, cwd: nil, env: env, timeout: nil))
            #expect(fFe == rFe, "\(c.label): fetch Shape RepoGraph \(fFe) != real git \(rFe)")

            // --- Semantic outcome classes through RemoteParents (the production seam). The reachable
            //     fetch/ls-remote here run against the ref just landed above (up-to-date), still landing. ---
            let rTip = tipClass(await real.lsRemoteTip(repo: repo, c.ref))
            let fTip = tipClass(await faked.lsRemoteTip(repo: repo, c.ref))
            #expect(rTip == c.tip, "\(c.label): real ls-remote \(rTip) != \(c.tip)")
            #expect(fTip == rTip, "\(c.label): RemoteRules ls-remote \(fTip) != real git \(rTip)")

            let rFetch = await fetchClass(real, repo: repo, c.ref)
            let fFetch = await fetchClass(faked, repo: repo, c.ref)
            #expect(rFetch == c.fetch, "\(c.label): real fetch \(rFetch) != \(c.fetch)")
            #expect(fFetch == rFetch, "\(c.label): RemoteRules fetch \(fFetch) != real git \(rFetch)")
        }
    }

    // The real-`git remote` wiring the converted RemoteParentRefTests.resolvesToPrivateRef could not carry
    // over FakeProc (`gitRemotes` shells real git, not the seam): a repo's ACTUAL configured remotes
    // classify `origin/<b>` onto its private ref, while an unconfigured remote stays a local branch (O4).
    @Test("real `git remote` output classifies origin/<b> onto its private ref (resolvedParentRef wiring)")
    func gitRemoteClassifies() throws {
        let repo = try realOrigin()
        let r = try Proc.run(["git", "-C", repo, "remote"])
        #expect(r.ok)
        let remotes = r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        #expect(remotes.contains("origin"))
        let ref = RemoteParentRef.parse("origin/feature-b", remotes: remotes)
        #expect(ref?.privateRef == "refs/orch/parents/branch/origin/feature-b")
        #expect(ref?.canonical == "origin/feature-b")
        // An unconfigured remote is NOT remote — it stays a local (slashed) branch name (nil).
        #expect(RemoteParentRef.parse("upstream/feat", remotes: remotes) == nil)
    }
}
