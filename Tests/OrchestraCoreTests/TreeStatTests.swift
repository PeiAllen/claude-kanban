import Foundation
import Testing
@testable import OrchestraCore

@Suite("TreeStat compute — child lineage state vs a real parent branch")
struct TreeStatTests {

    // MARK: shared fixtures (also used by StaleNudgeTests)

    /// A real repo on `main` (one base commit) with a `parent` branch at the same tip. Returns the path.
    static func repoWithParent(_ base: String) throws -> String {
        let repo = TestEnv.repo(base)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t")
        try git(repo, "config", "user.name", "t")
        try write(repo, "a.txt", "0\n")
        try git(repo, "add", "-A")
        try git(repo, "commit", "-q", "-m", "base")
        try git(repo, "branch", "parent")
        return repo
    }

    /// Add `n` commits to `parent` (leaves `main` checked out afterwards). Returns the new `parent` tip.
    @discardableResult
    static func advanceParent(_ repo: String, _ n: Int) throws -> String {
        try git(repo, "checkout", "-q", "parent")
        for i in 0..<n {
            try write(repo, "p\(i)-\(UUID().uuidString).txt", "x")
            try git(repo, "add", "-A")
            try git(repo, "commit", "-q", "-m", "p\(i)")
        }
        let tip = try git(repo, "rev-parse", "parent")
        try git(repo, "checkout", "-q", "main")
        return tip
    }

    @discardableResult
    static func git(_ repo: String, _ a: String...) throws -> String {
        let r = try Proc.run(["git", "-C", repo] + a)
        #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ repo: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
    }

    /// Spawn a `.worktree` card on `child` linked to `parent` with the given recorded base.
    static func linkedChild(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                            repo: String, base recorded: String) async throws -> Task {
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: recorded))
        return card
    }

    private func treeStat(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                          _ id: UUID) async -> TreeStat? {
        await env.svc.list().first { $0.id == id }?.treeStat
    }

    // MARK: compute cases

    @Test("base == parent tip ⇒ inSync, behind 0")
    func inSync() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let tip = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: tip)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .inSync)
        #expect(ts.behind == 0)
    }

    @Test("parent 2 commits ahead of the recorded base ⇒ stale, behind 2")
    func staleBehindTwo() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let base0 = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: base0)
        try Self.advanceParent(repo, 2)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .stale)
        #expect(ts.behind == 2)
    }

    @Test("recorded base no longer an ancestor (amended parent) ⇒ restackNeeded")
    func restackOnAmend() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        try Self.advanceParent(repo, 1)
        let base1 = try Self.git(repo, "rev-parse", "parent")      // record this tip
        let card = try await Self.linkedChild(env, repo: repo, base: base1)
        // Rewrite the parent's tip so base1 is orphaned (no longer an ancestor).
        try Self.git(repo, "checkout", "-q", "parent")
        try Self.write(repo, "amended.txt", "y")
        try Self.git(repo, "add", "-A")
        try Self.git(repo, "commit", "-q", "--amend", "-m", "amended")
        try Self.git(repo, "checkout", "-q", "main")
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("parent branch deleted ⇒ restackNeeded")
    func restackOnDeletedParent() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let tip = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: tip)
        try Self.git(repo, "branch", "-D", "parent")               // main is already checked out
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("a card with no parent link stays treeStat nil")
    func noLinkNoStat() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "solo", repo: repo, branch: "solo"))
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id) == nil)
    }
}
