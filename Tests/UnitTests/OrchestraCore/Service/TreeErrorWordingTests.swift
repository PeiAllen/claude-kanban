import Foundation
import Testing
import TestSupport
@testable import OrchestraCore
import OrchestraKit

/// Wording pass over the branch-tree command surface: every failure an agent reads must carry WHAT
/// failed, WHY, and a runnable NEXT STEP. These lock the improved key messages so a future edit can't
/// silently drop the recovery command. Unit-converted (Task 10, branch-tree) over FakeProc/RepoGraph.
@Suite("Branch-tree error wording — WHAT · WHY · runnable NEXT STEP")
struct TreeErrorWordingTests {

    @Test("branchInUse description names the other worktree AND both runnable recoveries")
    func branchInUseWording() {
        let d = OrchestraError.branchInUse("feature-x").description
        #expect(d.contains("feature-x"))
        #expect(d.contains("another worktree"))
        #expect(d.contains("spawn onto a new branch"))
        #expect(d.contains("existing card"))
    }

    @Test("gitIO frames object + git cause + runnable recovery")
    func gitIOFraming() {
        let e = OrchestraError.gitIO("could not fetch remote parent pr#7",
                                     stderr: "fatal: could not read Username",
                                     recovery: "check the remote/PR exists and you have access")
        guard case let .io(m) = e else { Issue.record("expected .io"); return }
        #expect(m.contains("could not fetch remote parent pr#7"))
        #expect(m.contains("(git: fatal: could not read Username)"))
        #expect(m.contains("— check the remote/PR exists and you have access"))
    }

    @Test("gitIO drops the cause clause when git said nothing, and the recovery clause when none given")
    func gitIOOptionalClauses() {
        let e = OrchestraError.gitIO("could not create worktree for feat", stderr: "")
        guard case let .io(m) = e else { Issue.record("expected .io"); return }
        #expect(m == "could not create worktree for feat")
    }

    @Test("synced on a deleted parent names the deletion cause and both runnable recoveries")
    func syncedParentGoneWording() async throws {
        let (env, fake, graph, repo) = TreeStatTests.setup()
        let tip = graph.tip("parent")!
        let card = try await TreeStatTests.linkedChild(env, fake: fake, repo: repo, base: tip)
        graph.deleteBranch("parent")

        await #expect { _ = try await env.svc.synced(ref: card.ref()) } throws: { error in
            guard case let OrchestraError.invalidParams(m) = error else { return false }
            return m.contains("parent branch was deleted")
                && m.contains("orchestra set-parent \(card.shortId)")
                && m.contains("orchestra shipped \(card.shortId)")
        }
    }

    @Test("merge-request / borrow with no parent link name the runnable set-parent recovery")
    func noParentLinkWording() async throws {
        let (env, _, _, repo) = TreeStatTests.setup()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "solo", repo: repo, branch: "solo"))

        await #expect { _ = try await env.svc.mergeRequest(ref: card.ref()) } throws: { error in
            guard case let OrchestraError.invalidParams(m) = error else { return false }
            return m.contains("orchestra set-parent \(card.shortId)")
        }
        await #expect { _ = try await env.svc.borrow(ref: card.ref()) } throws: { error in
            guard case let OrchestraError.invalidParams(m) = error else { return false }
            return m.contains("orchestra set-parent \(card.shortId)")
        }
    }
}
