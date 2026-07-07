import Foundation
import Testing
@testable import OrchestraCore

@Suite("set-parent move — repoint + restack nudge; adopt unchanged")
struct SetParentMoveTests {

    /// main + `parent` + `other` branches, and a `child` card linked to `parent` at base0.
    static func env() async throws -> (svc: OrchestraService, repo: String, child: Task, base0: String) {
        let e = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(e.base)      // main + parent
        try TreeStatTests.git(repo, "branch", "other")          // a second candidate parent off main
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        // A REAL `child` branch off parent (with its own commit) so adopt's merge-base(child, other) resolves.
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "child", "parent")
        try TreeStatTests.write(repo, "child.txt", "c\n"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "child work")
        try TreeStatTests.git(repo, "checkout", "-q", "main")
        let child = try await TreeStatTests.linkedChild(e, repo: repo, base: base0)  // child → parent @ base0
        return (e.svc, repo, child, base0)
    }

    @Test("move repoints lineage, KEEPS the recorded base, marks restackNeeded, nudges the owner")
    func moveRepointsAndNudges() async throws {
        let (svc, repo, child, base0) = try await Self.env()
        try await svc.setParent(ref: child.ref(), parent: "other", mode: "move")

        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
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
        let (svc, repo, child, _) = try await Self.env()
        try await svc.setParent(ref: child.ref(), parent: "other", mode: "adopt")

        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "other")
        let mb = try TreeStatTests.git(repo, "merge-base", "child", "other")
        #expect(link.base == mb)                       // merge-base, not the old base
        #expect(try await svc.inboxPeek(child.id).isEmpty)   // no nudge on adopt
    }

    @Test("invalid mode throws invalidParams")
    func invalidMode() async throws {
        let (svc, _, child, _) = try await Self.env()
        await #expect(throws: OrchestraError.self) {
            try await svc.setParent(ref: child.ref(), parent: "other", mode: "teleport")
        }
    }

    @Test("move to a nonexistent parent is rejected (even with a prior link)")
    func moveToGhostParentRejected() async throws {
        let (svc, _, child, _) = try await Self.env()   // child already linked to `parent`
        await #expect(throws: OrchestraError.self) {
            try await svc.setParent(ref: child.ref(), parent: "ghost", mode: "move")
        }
    }
}
