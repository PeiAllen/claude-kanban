import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// The identity line's source prefix: shown only while the board is ambiguous (>1 repo), naming a
/// worktree card's repo and a freeform card's directory. Mirrors `BoardStore.showsRepoPrefix` /
/// `repoPrefix(of:)`.
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

    /// Two repos ⇒ every card names its source: the repo's last path component.
    @Test func test_multiRepoBoardPrefixesWithRepoName() {
        let model = TestModel.make()
        let a = worktreeCard("a", repo: "/code/orchestra")
        let b = worktreeCard("b", repo: "/code/site")
        model.tasks = [a, b]
        #expect(model.showsRepoPrefix)
        #expect(model.repoPrefix(of: a) == "orchestra")
        #expect(model.repoPrefix(of: b) == "site")
    }

    /// A freeform card has no repo, so it names its directory instead — but under the same gate, so
    /// it stays prefixless on an unambiguous board.
    @Test func test_freeformCardNamesItsDirectoryUnderTheSameGate() {
        let model = TestModel.make()
        let scratch = freeformCard("notes", cwd: "/Users/a/vault")
        model.tasks = [worktreeCard("a", repo: "/code/orchestra"), scratch]
        #expect(model.showsRepoPrefix == false)          // one repo — a freeform card adds none
        #expect(model.repoPrefix(of: scratch) == nil)

        model.tasks.append(worktreeCard("b", repo: "/code/site"))
        #expect(model.showsRepoPrefix)
        #expect(model.repoPrefix(of: scratch) == "vault")
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
