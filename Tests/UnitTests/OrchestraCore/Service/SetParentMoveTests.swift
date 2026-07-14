import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, branch-tree). RepoGraph models main + parent + other + a real `child`
/// branch (so `merge-base(child, other)` resolves); lineage lives in GitConfigEmulator. No real git.
@Suite("set-parent move — repoint + restack nudge; adopt unchanged")
struct SetParentMoveTests {

    /// main + `parent` + `other` branches, and a `child` card linked to `parent` at base0.
    static func env() async throws -> (svc: OrchestraService, fake: FakeProc, repo: String, child: Task, base0: String) {
        let (e, fake, graph, repo) = TreeStatTests.setup()
        graph.branch("other", at: "main")                // a second candidate parent off main
        graph.branch("child", at: "parent")              // a real child off parent…
        graph.commit(on: "child")                        // …with its own commit (adopt's merge-base(child,other))
        let base0 = graph.tip("parent")!
        let child = try await TreeStatTests.linkedChild(e, fake: fake, repo: repo, base: base0)  // child → parent @ base0
        return (e.svc, fake, repo, child, base0)
    }

    @Test("move repoints lineage, KEEPS the recorded base, marks restackNeeded, nudges the owner")
    func moveRepointsAndNudges() async throws {
        let (svc, fake, repo, child, base0) = try await Self.env()
        try await svc.setParent(ref: child.ref(), parent: "other", mode: "move")

        let link = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "child"))
        #expect(link.parent == "other")
        #expect(link.base == base0)   // recorded base KEPT (the rebase anchor)
        #expect(await svc.list().first { $0.id == child.id }?.treeStat?.state == .restackNeeded)
        let nudges = try await svc.inboxPeek(child.id)
        #expect(nudges.count == 1)
        #expect(nudges.first?.text.contains("rebase --onto other \(base0)") == true)
        #expect(nudges.first?.text.contains("orchestra synced") == true)
    }

    @Test("adopt sets base = merge-base and does NOT nudge (BT1 behavior unchanged)")
    func adoptUnchanged() async throws {
        let (svc, fake, repo, child, _) = try await Self.env()
        try await svc.setParent(ref: child.ref(), parent: "other", mode: "adopt")

        let link = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "child"))
        #expect(link.parent == "other")
        // merge-base(child, other): child forked from parent(=main), other is at main ⇒ the base commit.
        let mb = try await fake.run(["git", "-C", repo, "merge-base", "refs/heads/child", "refs/heads/other"],
                                    cwd: nil, env: [:], timeout: nil).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(link.base == mb)                       // merge-base, not the old base
        #expect(try await svc.inboxPeek(child.id).isEmpty)   // no nudge on adopt
    }

    @Test("invalid mode throws invalidParams")
    func invalidMode() async throws {
        let (svc, _, _, child, _) = try await Self.env()
        await #expect(throws: OrchestraError.self) {
            try await svc.setParent(ref: child.ref(), parent: "other", mode: "teleport")
        }
    }

    @Test("move to a nonexistent parent is rejected (even with a prior link)")
    func moveToGhostParentRejected() async throws {
        let (svc, _, _, child, _) = try await Self.env()   // child already linked to `parent`
        await #expect(throws: OrchestraError.self) {
            try await svc.setParent(ref: child.ref(), parent: "ghost", mode: "move")
        }
    }
}
