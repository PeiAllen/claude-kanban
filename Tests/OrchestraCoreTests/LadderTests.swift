import Foundation
import Testing
@testable import OrchestraCore

/// Scriptable gh double: a fixed PrState (or nil), an availability flag, and a recorded editBase call.
final class FakeGh: GhClient, @unchecked Sendable {
    let available: Bool
    private let lock = NSLock()
    var state: PrState?
    var headPR: Int?
    private(set) var editedBase: (number: Int, base: String)?
    init(available: Bool = true, state: PrState? = nil, headPR: Int? = nil) {
        self.available = available; self.state = state; self.headPR = headPR
    }
    private(set) var prStateCalls = 0
    func prState(repo: String, number: Int) async -> PrState? {
        lock.withLock { prStateCalls += 1; return state }
    }
    func prNumber(repo: String, head: String) async -> Int? { lock.withLock { headPR } }
    func editBase(repo: String, number: Int, base: String) async -> Bool {
        lock.withLock { editedBase = (number, base) }; return true
    }
    var recordedEdit: (number: Int, base: String)? { lock.withLock { editedBase } }
    var stateCallCount: Int { lock.withLock { prStateCalls } }
}

@Suite("Detection ladder — remote merge decision with FakeGh (no network, no gh)")
struct LadderTests {

    /// A spawned remote-parent card over a real bare origin, watch enabled. Returns (svc, repo, card).
    static func remoteChild() async throws -> (svc: OrchestraService, repo: String, card: Task) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        return (svc, repo, card)   // watch loop wired in Task 8; here we drive remoteMergeStep directly
    }

    // S1-5: only a PR parent should pay for `gh pr view`. A plain `origin/<b>` parent carries no PR
    // number, so the tick must never consult gh (no wasted network round-trip on the actor).
    @Test("S1-5: a plain origin/<b> parent never consults gh")
    func branchParentSkipsGh() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childB",
                                                  base: "origin/feature-b"))
        let fake = FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main"))
        await svc.setGh(fake)
        _ = await svc.remoteMergeStep(cardId: card.id)
        #expect(fake.stateCallCount == 0)   // no prNumber ⇒ tier (a) skipped ⇒ gh untouched
    }

    @Test("gh MERGED ⇒ redirect fires with the PR baseRefName; child PR base repaired")
    func mergedRedirect() async throws {
        let (svc, repo, card) = try await Self.remoteChild()
        await svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: .init(oid: "x"), baseRefName: "main"),
            headPR: 42))
        let outcome = await svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .redirected(grandparent: "main"))
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "origin/main")          // retargeted onto the remote base branch
        #expect(link.prNumber == nil)                  // no longer a PR parent
        let updated = try #require(await svc.store.get(card.id))
        #expect(updated.parentBranch == "origin/main")
        #expect(updated.treeStat?.state == .restackNeeded)
        #expect(try await svc.inboxPeek(card.id).count >= 1)   // restack nudge enqueued
    }

    @Test("gh unavailable + branch gone ⇒ warning tier, no redirect")
    func goneWarning() async throws {
        let (svc, repo, card) = try await Self.remoteChild()
        await svc.setGh(FakeGh(available: false))
        // Delete the PR head on the bare side so lsRemoteTip → .gone.
        let url = try Proc.run(["git", "-C", repo, "remote", "get-url", "origin"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "file://", with: "")
        try Proc.run(["git", "-C", url, "update-ref", "-d", "refs/pull/7/head"])
        let outcome = await svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .warnedGone)
        let link = try #require(await svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "pr#7")   // unchanged — no authoritative merge signal
    }

    @Test("squash merge (ancestry false) but gh MERGED ⇒ treated as merged")
    func squashMergedByGh() async throws {
        let (svc, _, card) = try await Self.remoteChild()
        await svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main")))
        let outcome = await svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .redirected(grandparent: "main"))
    }

    @Test("merge-commit landing (child contained in a fresh parent tip) + no gh ⇒ warnedAncestry")
    func mergeCommitAncestry() async throws {
        let (svc, repo, card) = try await Self.remoteChild()
        await svc.setGh(FakeGh(available: false))
        // Child commits its OWN work → its branch advances past the recorded base.
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", card.cwd] + a).ok) }
        try "child\n".write(toFile: card.cwd + "/c.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "child work")
        let childTip = try Proc.run(["git", "-C", card.cwd, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Land the child's object in the bare, then advance the PR head to CONTAIN it (a merge landing).
        try git("push", "-q", "-f", "origin", "HEAD:refs/heads/pr-src")
        let url = try Proc.run(["git", "-C", repo, "remote", "get-url", "origin"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "file://", with: "")
        try Proc.run(["git", "-C", url, "update-ref", "refs/pull/7/head", childTip])
        let outcome = await svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .warnedAncestry)   // proof-positive ancestry, but no gh to name the base
    }
}
