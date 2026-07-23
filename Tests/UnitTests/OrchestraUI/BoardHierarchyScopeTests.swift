import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// Slice 2b scope model: the desktop `BoardUX` scope-aware embedding gate (roots-only top level,
/// drill to a root's subtree), the attached-vs-lineage split, cycle fail-open, and the drill-scope
/// reaper. Pure over `tasks` — no daemon. Mirrors `BoardUX.isEmbedded`/`drillInto`/`reapDrillScope`.
@Suite @MainActor struct BoardHierarchyScopeTests {
    private func card(_ id: String, _ col: Column = .impl, repo: String = "/r", branch: String? = nil,
                      parent: String? = nil, access: CardAccess = .readWrite,
                      origin: CardOrigin = .worktree, cwd: String? = nil, archived: Bool = false) -> Task {
        var t = Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                     title: id, repo: origin == .worktree ? repo : "",
                     branch: origin == .worktree ? (branch ?? id) : "",
                     cwd: cwd ?? "\(repo)/\(id)", origin: origin, access: access,
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col, order: 0,
                     phase: .live(.running), initialPrompt: id, parentBranch: parent)
        t.archived = archived
        return t
    }
    private func ids(_ ts: [Task]) -> Set<UUID> { Set(ts.map(\.id)) }

    // MARK: top level — roots only

    @Test func topLevelShowsRootsOnly() {
        let m = TestModel.make()
        let root = card("01")
        let child = card("02", .plan, parent: "01")            // read-write PR child
        m.tasks = [root, child]
        #expect(m.visibleTasks.map(\.id) == [root.id])          // child embedded, root a citizen
        #expect(m.isEmbedded(child))
        #expect(!m.isEmbedded(root))
    }

    @Test func standaloneCardIsACitizen() {
        let m = TestModel.make()
        let solo = card("01")                                   // no parent, no reviewer
        m.tasks = [solo]
        #expect(!m.isEmbedded(solo))
    }

    // MARK: drill — a root's direct lineage children become citizens

    @Test func drillShowsLineageChildrenOfRoot() {
        let m = TestModel.make()
        let root = card("01"), child = card("02", .plan, parent: "01")
        let grand = card("03", .review, parent: "02"), other = card("04")   // other forest root
        m.tasks = [root, child, grand, other]
        m.drillInto(root.id)
        #expect(m.drillScope == root.id)
        #expect(m.visibleTasks.map(\.id) == [child.id])         // direct child only
        #expect(m.isEmbedded(root))                             // the root itself → the banner, not a card
        #expect(m.isEmbedded(grand))                            // grandchild → peek under child
        #expect(m.isEmbedded(other))                            // a different subtree → out of scope
    }

    @Test func attachedReviewerStaysEmbeddedInTargetDrill() {
        // THE plan-review BLOCKER: drilling a root must NOT promote its attached reviewer to a column card.
        let m = TestModel.make()
        let root = card("01"), child = card("02", .plan, parent: "01")
        let reviewer = card("05", .impl, parent: "01", access: .readOnly)   // RO reviewer of root, base=01
        m.tasks = [root, child, reviewer]
        #expect(m.isEmbedded(reviewer))                         // embedded at top level (peek under root)
        m.drillInto(root.id)
        #expect(m.isEmbedded(reviewer))                         // STILL embedded in the root's drill
        #expect(m.visibleTasks.map(\.id) == [child.id])         // only the lineage child is a column card
    }

    @Test func drillIntoReviewerOnlyRootIsNoOp() {
        let m = TestModel.make()
        let root = card("01")
        let reviewer = card("05", .impl, parent: "01", access: .readOnly)
        m.tasks = [root, reviewer]
        m.drillInto(root.id)                                    // no lineage child ⇒ nothing to scope to
        #expect(m.drillScope == nil)
    }

    @Test func drillIntoLeafIsNoOp() {
        let m = TestModel.make()
        let leaf = card("01")
        m.tasks = [leaf]
        m.drillInto(leaf.id)
        #expect(m.drillScope == nil)
    }

    // MARK: cycle fail-open — never strand the board

    @Test func cycleKeepsBothCitizens_visibleTasksNonEmpty() {
        let m = TestModel.make()
        let a = card("01", parent: "02"), b = card("02", parent: "01")   // A→B→A
        m.tasks = [a, b]
        #expect(ids(m.visibleTasks) == ids([a, b]))             // both rendered, board not empty
        #expect(!m.isEmbedded(a))
        #expect(!m.isEmbedded(b))
    }

    // MARK: drill out — climbs one scope level at a time

    @Test func drillOutClimbsOneLevel() {
        let m = TestModel.make()
        let root = card("01"), child = card("02", .plan, parent: "01"), grand = card("03", parent: "02")
        m.tasks = [root, child, grand]
        m.drillInto(child.id)                                   // child has a lineage child (grand)
        #expect(m.drillScope == child.id)
        m.drillOut()
        #expect(m.drillScope == root.id)                        // up to the parent scope
        m.drillOut()
        #expect(m.drillScope == nil)                            // forest root → top level
    }

    // MARK: reaper — survive card succession, clear on removal

    @Test func reapRetargetsScopeToNewOwner() {
        let m = TestModel.make()
        let planning = card("01", branch: "feat/x")
        let child = card("02", .plan, parent: "feat/x")
        m.tasks = [planning, child]
        m.drillInto(planning.id)
        // Succession: the planning card is replaced by an orchestrator on the SAME branch (new id).
        let orchestrator = card("09", branch: "feat/x")
        m.tasks = [orchestrator, child]
        m.reapDrillScope()
        #expect(m.drillScope == orchestrator.id)                // retargeted to the new owner
        #expect(m.visibleTasks.map(\.id) == [child.id])         // child still scoped correctly
    }

    @Test func reapClearsWhenRootArchived() {
        let m = TestModel.make()
        let root = card("01", branch: "feat/x"), child = card("02", .plan, parent: "feat/x")
        m.tasks = [root, child]
        m.drillInto(root.id)
        m.tasks = [child]                                       // root gone (archived/merged away)
        m.reapDrillScope()
        #expect(m.drillScope == nil)                            // scope cleared to top level
    }

    // MARK: cardLevelAnchor climbs the unified relation

    @Test func cardLevelAnchorClimbsToVisibleRoot() {
        let m = TestModel.make()
        let root = card("01"), child = card("02", .plan, parent: "01")
        m.tasks = [root, child]
        #expect(m.cardLevelAnchor(child.id) == root.id)         // embedded child anchors to its visible root
    }

    // MARK: repo prefix is scope-aware (drops inside a drill)

    @Test func repoPrefixDropsInsideDrill() {
        let m = TestModel.make()
        let a = card("01", repo: "/code/orchestra", branch: "feat/a")
        let ac = card("02", .plan, repo: "/code/orchestra", branch: "feat/a-child", parent: "feat/a")
        let b = card("03", repo: "/code/site", branch: "feat/b")   // second repo → prefix at top level
        m.tasks = [a, ac, b]
        #expect(m.showsRepoPrefix)                              // multi-repo board
        m.drillInto(a.id)                                       // scope = orchestra subtree (single repo)
        #expect(m.showsRepoPrefix == false)                     // prefix drops
        #expect(m.repoPrefix(of: ac) == nil)
    }
}
