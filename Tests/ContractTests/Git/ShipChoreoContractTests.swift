//
// The real-repo happy path distilled out of the (now unit) ShipChoreoTests: it proves that when a
// parent branch was REALLY advanced by a merge, `shipped` reaches the end-to-end effect over honest
// git — it notifies the live parent card, retargets the shipped child's grandchild onto the
// grandparent in the on-disk `git config`, and CLEARS the shipped child's own lineage on disk. The
// unit suite proves the branching/notify/dedup logic over FakeProc + RepoGraph + GitConfigEmulator;
// this pins that the same code path behaves identically when the S2-2 advancement gate, the lineage
// clear, and the grandchild retarget all run against real `git` and a real on-disk `git config`.

import Foundation
import Testing
@testable import OrchestraCore

@Suite("Contract: shipped over a real git repo (notify + retarget + clear)", .enabled(if: IntegrationSupport.gitAvailable))
struct ShipChoreoContractTests {

    @discardableResult
    private func git(_ repo: String, _ a: String...) throws -> String {
        let r = try Proc.run(["git", "-C", repo] + a)
        #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ repo: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
    }

    @Test("a real merge → shipped notifies the parent, retargets the grandchild, clears lineage on disk")
    func realShipHappyPath() async throws {
        let base = IntegrationSupport.tempDir("ship-choreo-contract")
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        // Real topology: main → parent → child → grandchild, each carrying its own commit.
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t"); try git(repo, "config", "user.name", "t")
        try write(repo, "a.txt", "0\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "base")
        try git(repo, "checkout", "-q", "-b", "parent")
        try write(repo, "p.txt", "p\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "parent work")
        let parentBase = try git(repo, "rev-parse", "parent")     // child's recorded base = parent tip now
        try git(repo, "checkout", "-q", "-b", "child")
        try write(repo, "c.txt", "c\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "child work")
        let childTip = try git(repo, "rev-parse", "child")        // grandchild's recorded base
        try git(repo, "checkout", "-q", "-b", "grandchild")
        try write(repo, "g.txt", "g\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "grandchild work")
        // The parent agent's squash-merge REALLY happened: advance parent past the recorded base (S2-2 gate).
        try git(repo, "checkout", "-q", "parent")
        try write(repo, "merged.txt", "m\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "merge child")
        try git(repo, "checkout", "-q", "main")

        // A real service. Seed live worktree cards directly (this test exercises the shipped RPC, not the
        // spawn/reconcile funnel — `Task`'s default phase is already `.live(.running)`).
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   trust: TrustLedger(path: base + "/trust-ledger.json"),
                                   inbox: Inbox(path: base + "/inbox.json"),
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                   proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        func card(_ branch: String, parent: String?) -> Task {
            Task(title: branch, repo: repo, branch: branch, cwd: repo, model: AgentModel(id: "m1"),
                 startIn: .impl, column: .impl, order: 0, initialPrompt: "", parentBranch: parent)
        }
        let parentCard = card("parent", parent: nil)
        let childCard = card("child", parent: "parent")
        let grandchildCard = card("grandchild", parent: "child")
        _ = try await svc.store.create(parentCard)
        _ = try await svc.store.create(childCard)
        _ = try await svc.store.create(grandchildCard)

        // Real on-disk lineage: child → parent @ parentBase, grandchild → child @ childTip.
        try await svc.lineage.set(repo: repo, branch: "child", link: ParentLink(parent: "parent", base: parentBase))
        try await svc.lineage.set(repo: repo, branch: "grandchild", link: ParentLink(parent: "child", base: childTip))

        try await svc.shipped(ref: childCard.ref())

        // (notify) the live parent card was told its child merged in.
        let parentMsgs = try await svc.inboxPeek(parentCard.id)
        #expect(parentMsgs.contains { $0.text.contains("merged into you") })

        // (clear) the shipped child's own lineage is gone from the real on-disk git config.
        #expect(await svc.lineage.read(repo: repo, branch: "child") == nil)
        #expect(try Proc.run(["git", "-C", repo, "config", "--get", "branch.child.orchestra-parent"]).exitCode == 1)

        // (retarget) the grandchild was repointed onto the grandparent (parent), base KEPT, restackNeeded.
        let gcLink = try #require(await svc.lineage.read(repo: repo, branch: "grandchild"))
        #expect(gcLink.parent == "parent")
        #expect(gcLink.base == childTip)
        #expect(await svc.list().first { $0.id == grandchildCard.id }?.treeStat?.state == .restackNeeded)
    }
}
