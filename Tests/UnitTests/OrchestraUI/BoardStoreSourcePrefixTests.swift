import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The identity line's repo prefix: shown only while the board is ambiguous (>1 repo), naming a
/// worktree card's repo by the shortest suffix that distinguishes it. Freeform cards are never
/// prefixed. Mirrors `BoardStore.showsRepoPrefix` / `repoPrefix(of:)`.
@Suite @MainActor struct BoardStoreSourcePrefixTests {

    private func worktreeCard(_ title: String, repo: String, branch: String = "feat/x",
                              access: CardAccess = .readWrite, parentBranch: String? = nil) -> Task {
        Task(title: title, repo: repo, branch: branch, cwd: "\(repo)/.worktrees/\(branch)",
             origin: .worktree, access: access, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .impl, column: .impl, order: 0, initialPrompt: title, parentBranch: parentBranch)
    }

    private func freeformCard(_ title: String, cwd: String) -> Task {
        Task(title: title, repo: "", branch: "", cwd: cwd, origin: .borrowed,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
             order: 0, initialPrompt: title)
    }

    /// One repo ⇒ nothing to disambiguate, so no card wears a prefix.
    @Test func test_singleRepoBoardShowsNoPrefix() {
        let model = TestModel.make()
        model.tasks = [worktreeCard("a", repo: "/code/orchestra"),
                       worktreeCard("b", repo: "/code/orchestra", branch: "feat/y")]
        #expect(model.showsRepoPrefix == false)
        #expect(model.repoPrefix(of: model.tasks[0]) == nil)
    }

    /// Two repos with distinct basenames ⇒ each card names its repo by that basename.
    @Test func test_multiRepoBoardPrefixesWithRepoName() {
        let model = TestModel.make()
        let a = worktreeCard("a", repo: "/code/orchestra")
        let b = worktreeCard("b", repo: "/code/site")
        model.tasks = [a, b]
        #expect(model.showsRepoPrefix)
        #expect(model.repoPrefix(of: a) == "orchestra")
        #expect(model.repoPrefix(of: b) == "site")
    }

    /// Two repos that SHARE a basename must not both render "client" — the prefix would open the gate
    /// and still leave L2 ambiguous. It grows leftward to the shortest suffix that distinguishes them.
    @Test func test_basenameCollisionGrowsThePrefixUntilUnique() {
        let model = TestModel.make()
        let a = worktreeCard("a", repo: "/work/alpha/client")
        let b = worktreeCard("b", repo: "/work/beta/client")
        let c = worktreeCard("c", repo: "/code/orchestra")   // distinct basename — stays a basename
        model.tasks = [a, b, c]
        #expect(model.showsRepoPrefix)
        #expect(model.repoPrefix(of: a) == "alpha/client")
        #expect(model.repoPrefix(of: b) == "beta/client")
        #expect(model.repoPrefix(of: c) == "orchestra")
    }

    /// A freeform card never gets a board prefix — not even when the gate is open. Gating its cwd on
    /// the WORKTREE cards' repo count would sprout a prefix on it (and, symmetrically, would make a
    /// lone scratch card flip prefixes onto every worktree card) for reasons unrelated to the
    /// freeform card itself. Its location lives in the inspector; its title is its board identity.
    @Test func test_freeformCardNeverGetsABoardPrefix() {
        let model = TestModel.make()
        let scratch = freeformCard("notes", cwd: "/Users/a/vault")
        model.tasks = [worktreeCard("a", repo: "/code/orchestra"), scratch]
        #expect(model.showsRepoPrefix == false)          // one repo — a freeform card adds none
        #expect(model.repoPrefix(of: scratch) == nil)

        model.tasks.append(worktreeCard("b", repo: "/code/site"))
        #expect(model.showsRepoPrefix)                   // the two REPOS opened the gate…
        #expect(model.repoPrefix(of: scratch) == nil)    // …but the freeform card still shows nothing
    }

    /// A board of only freeform cards is never ambiguous BY REPO — none of them has one — so the gate
    /// stays shut and no card is prefixed, whatever their directories.
    @Test func test_freeformOnlyBoardShowsNoPrefix() {
        let model = TestModel.make()
        model.tasks = [freeformCard("notes", cwd: "/Users/a/vault"),
                       freeformCard("scratch", cwd: "/Users/a/scratch")]
        #expect(model.showsRepoPrefix == false)
        #expect(model.repoPrefix(of: model.tasks[0]) == nil)
        #expect(model.repoPrefix(of: model.tasks[1]) == nil)
    }

    /// Archived cards have left the board and must not hold the prefix open behind them.
    @Test func test_archivedCardsDoNotOpenTheGate() {
        let model = TestModel.make()
        var gone = worktreeCard("old", repo: "/code/site")
        gone.archived = true
        model.tasks = [worktreeCard("a", repo: "/code/orchestra"), gone]
        #expect(model.showsRepoPrefix == false)
    }

    /// An EMBEDDED reviewer never flips the gate. It can't: a worktree reviewer attaches to its
    /// lineage parent, which is same-repo by construction — so the answer is identical whether the
    /// predicate reads `tasks` or the board's own `visibleTasks` projection.
    @Test func test_embeddedReviewerCannotFlipTheGate() {
        let model = TestModel.make()
        let target = worktreeCard("target", repo: "/code/orchestra", branch: "feat/x")
        let reviewer = worktreeCard("review", repo: "/code/orchestra", branch: "review/x",
                                    access: .readOnly, parentBranch: "feat/x")
        model.tasks = [target, reviewer]
        #expect(model.isAttached(reviewer))                       // it IS embedded…
        #expect(model.visibleTasks.count == 1)                    // …and off the board
        #expect(model.showsRepoPrefix == false)                   // …and contributes no repo
    }
}
