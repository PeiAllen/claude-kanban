import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, remote-git). The five `parse` cases were already pure (they pass `remotes:`
/// explicitly — no git, no service). `resolvesToPrivateRef` converts to FakeProc: `resolvedParentRef`'s
/// routing for a PR parent (`pr#N` — classified BEFORE any remotes lookup) and a local parent is
/// seam-independent, so it runs over `TestEnv.make(proc:)` with `gitRemotes` harmlessly empty against the
/// fake repo. The one sub-assertion that genuinely needs real `git remote` (an `origin/<b>` parent
/// classified via the repo's configured remotes — `gitRemotes` shells real git, not the seam) moves to
/// ContractTests/Git/RemoteFetchContractTests.gitRemoteClassifies. No real git in this file.
@Suite("RemoteParentRef — remote-aware parsing + disjoint namespaces (O4, S4)")
struct RemoteParentRefTests {
    @Test("pr#N parses to a pull-request ref in the pr/ sub-namespace")
    func parsesPR() throws {
        let r = try #require(RemoteParentRef.parse("pr#12", remotes: ["origin"]))
        #expect(r == .pullRequest(12))
        #expect(r.remoteName == "origin")
        #expect(r.remoteSrc == "refs/pull/12/head")
        #expect(r.privateName == "pr/12")                         // disjoint from branch/… (S4)
        #expect(r.privateRef == "refs/orch/parents/pr/12")
        #expect(r.canonical == "pr#12")
        // S3-2: a human-typed `PR#12` is teachable (case-insensitive prefix), canonicalized to `pr#12`.
        #expect(RemoteParentRef.parse("PR#12", remotes: ["origin"]) == .pullRequest(12))
    }

    @Test("<remote>/<branch> parses to a remote branch, threading the remote (O4)")
    func parsesBranch() throws {
        let r = try #require(RemoteParentRef.parse("origin/feature/foo", remotes: ["origin"]))
        #expect(r == .branch(remote: "origin", name: "feature/foo"))
        #expect(r.remoteName == "origin")
        #expect(r.remoteSrc == "refs/heads/feature/foo")
        #expect(r.privateName == "branch/origin/feature/foo")     // includes the remote (S4)
        #expect(r.privateRef == "refs/orch/parents/branch/origin/feature/foo")
        #expect(r.canonical == "origin/feature/foo")
    }

    @Test("a non-origin remote works when it's configured (O4 generalization)")
    func parsesNonOriginRemote() throws {
        let r = try #require(RemoteParentRef.parse("upstream/feat", remotes: ["origin", "upstream"]))
        #expect(r == .branch(remote: "upstream", name: "feat"))
        #expect(r.remoteName == "upstream")
        #expect(r.privateRef == "refs/orch/parents/branch/upstream/feat")
    }

    @Test("pr#7 and a branch named pr-7 land on disjoint private refs (S4 collision fix)")
    func disjointNamespaces() throws {
        let pr = try #require(RemoteParentRef.parse("pr#7", remotes: ["origin"]))
        let br = try #require(RemoteParentRef.parse("origin/pr-7", remotes: ["origin"]))
        #expect(pr.privateRef != br.privateRef)
        #expect(pr.privateRef == "refs/orch/parents/pr/7")
        #expect(br.privateRef == "refs/orch/parents/branch/origin/pr-7")
    }

    @Test("a slashed local branch and an unknown remote stay LOCAL (nil)")
    func localIsNil() {
        #expect(RemoteParentRef.parse("feature-a", remotes: ["origin"]) == nil)
        #expect(RemoteParentRef.parse("feature/foo", remotes: ["origin"]) == nil)   // local slashed branch
        #expect(RemoteParentRef.parse("upstream/feat", remotes: ["origin"]) == nil) // remote not configured
        #expect(RemoteParentRef.parse("", remotes: ["origin"]) == nil)
        #expect(RemoteParentRef.parse("pr#", remotes: ["origin"]) == nil)
        #expect(RemoteParentRef.parse("pr#abc", remotes: ["origin"]) == nil)
        #expect(RemoteParentRef.parse("pr#0", remotes: ["origin"]) == nil)
        #expect(RemoteParentRef.parse("origin/", remotes: ["origin"]) == nil)       // empty branch
    }

    // resolvedParentRef routing over FakeProc: a PR parent (classified before any remotes lookup) maps to
    // its private ref; a local parent pins refs/heads/ (O1/S3-6); nil stays nil. The `origin/<b>` remote
    // case (needs real `git remote`) is pinned by RemoteFetchContractTests.gitRemoteClassifies.
    @Test("resolvedParentRef maps a PR form to its private fetch ref; local pins refs/heads/; nil stays nil")
    func resolvesToPrivateRef() async throws {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(base)
        var t = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "c1"))
        t.parentBranch = "pr#7"
        #expect(await svc.resolvedParentRef(t) == "refs/orch/parents/pr/7")
        t.parentBranch = "feature-a"   // local (no such remote) → pins refs/heads/ (O1/S3-6)
        #expect(await svc.resolvedParentRef(t) == "refs/heads/feature-a")
        t.parentBranch = nil
        #expect(await svc.resolvedParentRef(t) == nil)
    }
}
