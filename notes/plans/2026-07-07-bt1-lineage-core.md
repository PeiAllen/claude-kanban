# BT1 — Branch-Tree Lineage Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the durable parent-link foundation of the branch-tree feature — a `BranchLineage`
git-config CRUD unit, the `TreeStat`/`SpawnInput.base` model types, the `set-parent` (adopt/clear)
and `tree` commands, and churn-derivation of `Task.parentBranch` at spawn — so every later BT PR
(spawn base, diffs, TreeStat, ship, remote, board) builds on one lineage source of truth.

**Architecture:** Lineage lives **on the branch** in repo git config
(`branch.<child>.orchestra-parent{,-base,-pr,-watch}`), git-town/Graphite style — it survives card
churn and is plain-git readable. `BranchLineage` (a new OrchestraCore actor) is the single writer,
built entirely on the house `Proc.run(["git","-C",repo,"config",…])` idiom (never a shell string).
`Task.parentBranch` (already on the model) becomes a **cache** derived from that config at spawn.
Two new catalog/registry command pairs (`set-parent`, `tree`, exposure `.all`) expose it to
MCP + CLI. This PR is types + CRUD + two read/write commands only — no diff switch, no TreeStat
recompute, no ship choreography, no remote tier (those are BT2–BT7).

**Tech Stack:** Swift 6 (actors, swift-testing `#expect`/`@Test` + a few XCTest suites), real-git
throwaway-repo fixtures (the `DiffProviderTests.makeRepo()` pattern), no git mocking.

## Global Constraints

- **Scope is BT1 only** (per `notes/designs/parent-card-branch-linking/03-implementation.md`
  §Sequencing). IN: `BranchLineage`, Model additions (`TreeStat`/`TreeState`, `Task.treeStat`,
  `SpawnInput.base` — **types only**, no recompute machinery), `set-parent` (**adopt + clear
  only** — `move` mode is BT5's), `tree`, churn derivation in `OrchestraService.spawn`, CLI cases.
  OUT: spawn `base` threading + `WorktreeManager.ensure(base:)` (BT2), diff baseline switch (BT3),
  `TreeStat` recompute/stale nudges/`synced` (BT4), `shipped`/`move`/TreeDocs (BT5), remote tier +
  `GhProbe` (BT6), board UI (BT7).
- **Design for BOTH Claude and Codex** — no `if agent == "claude"` branches in shared code. (BT1
  touches no agent-specific code, so this is automatic here.)
- **Branch base is `plan/parent-card-branch-linking`** — never touch `main` or the plan branch; do
  not modify other cards' work.
- **git idiom:** every git call is `Proc.run(["git","-C",repo, …])` with an `[String]` argv — never
  an interpolated shell string (Proc's security posture). No `git -C` avoidance rule applies here
  (that rule is about the *Bash allowlist*, not in-code `Proc` argv).
- **Lineage keys (verbatim):** `branch.<child>.orchestra-parent` (parent ref string),
  `orchestra-parent-base` (parent tip OID), `orchestra-parent-pr` (Int, optional),
  `orchestra-parent-watch` (`"true"`, optional).
- **Parent ref forms:** plain `name` = local branch; `origin/name` = remote (a `/` whose first
  segment names a configured remote). `refs/orch/parents/…` never appears in config.
- **Error type:** `OrchestraError` has **no `unknownBranch` case**; use `.invalidParams(...)` for
  self-parent, cycles, unknown/merge-base-less parents. (The L2 contract names `unknownBranch`
  aspirationally; L3 §2/§3 both lean on `invalidParams`. Do not widen the error enum in BT1.)
- **TDD:** write the failing test first, watch it fail, minimal implementation, watch it pass,
  commit. Run `swift test` (offline) — it must pass cleanly before each commit.

## File Structure

**New source files**
- `Sources/OrchestraCore/BranchLineage.swift` — `ParentLink` struct + `BranchLineage` actor
  (git-config CRUD, tree queries, cycle guard, canonical parse). The lineage source of truth.
- `Sources/OrchestraCore/OrchestraService+Tree.swift` — `setParent(...)` + `tree(...)` service
  methods + a private `mergeBaseOID` helper. (Named per L3 §6; BT4 later adds `recomputeTreeStat`
  here.)

**Modified source files**
- `Sources/OrchestraKit/Model.swift` — add `TreeState` enum, `TreeStat` struct, `Task.treeStat`
  field, `SpawnInput.base` field (+ its manual `init(from:)`), and `TreeNode`/`TreeSnapshot` wire
  types (the `tree` payload).
- `Sources/OrchestraKit/CommandCatalog.swift` — two `CommandSchema` entries (`set-parent`, `tree`).
- `Sources/OrchestraCore/CommandRegistry.swift` — two handler bindings.
- `Sources/OrchestraCore/OrchestraService.swift` — a `lineage` property + churn derivation in the
  worktree arm of `spawn`.
- `Sources/orchestra/CLIRunner.swift` — `set-parent` + `tree` CLI cases.
- `Sources/orchestra/CLIHelp.swift` — two help lines.

**New test files**
- `Tests/OrchestraCoreTests/LineageTests.swift` — `BranchLineage` unit tests (real git fixtures).
- `Tests/OrchestraCoreTests/LineageModelTests.swift` — model decode/back-compat.
- `Tests/OrchestraCoreTests/TreeCommandTests.swift` — `set-parent`/`tree` service+command tests.
- `Tests/OrchestraCoreTests/LineageSpawnTests.swift` — churn-derivation integration test.

**Modified test files**
- `Tests/OrchestraCoreTests/CommandsTests.swift` — extend the `fullSet` expected list.
- `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` — extend the canonical-set assertion.

---

## Task 1: Model additions — `TreeStat`/`TreeState`, `Task.treeStat`, `SpawnInput.base`, `TreeNode`/`TreeSnapshot`

**Files:**
- Modify: `Sources/OrchestraKit/Model.swift` (add types near `DiffStat` :140-152; `Task.treeStat`
  after :201; `SpawnInput.base` at :655-696; `TreeNode`/`TreeSnapshot` after the command-result shapes)
- Test: `Tests/OrchestraCoreTests/LineageModelTests.swift` (new)

**Interfaces:**
- Produces:
  - `enum TreeState: String, Codable, Sendable { case inSync, stale, restackNeeded, parentMerged }`
  - `struct TreeStat: Codable, Sendable, Equatable { var state: TreeState; var behind: Int; var parentIsRemote: Bool; init(state:behind:parentIsRemote:) }` (defaults `behind: 0`, `parentIsRemote: false`)
  - `Task.treeStat: TreeStat?` (decode-default-nil via synthesized `Codable` — `Task` has no manual `init(from:)`, so an absent key decodes to nil, exactly like `diffStat`)
  - `SpawnInput.base: String?` (decode-default-nil via the manual `init(from:)`)
  - `struct TreeNode: Codable, Sendable, Equatable { let ref: String; let cardId: UUID; let repo: String; let branch: String; let parent: String?; let parentCardId: UUID?; let children: [String]; let treeStat: TreeStat? }`
  - `struct TreeSnapshot: Codable, Sendable, Equatable { let nodes: [TreeNode] }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/LineageModelTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore   // @_exported re-exports OrchestraKit

@Suite("Lineage model additions — decode defaults + back-compat")
struct LineageModelTests {

    /// A Task JSON that predates the tree feature (no `treeStat`) still decodes, with treeStat == nil.
    @Test("Task decodes without treeStat → nil (back-compat)")
    func taskDecodesWithoutTreeStat() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","titleProvisional":false,"desc":"",
         "repo":"/r","branch":"b","cwd":"/r","origin":"worktree","access":"readWrite",
         "agentId":"claude-code","model":{"id":"m","displayName":"m","family":"other"},
         "startIn":"plan","column":"plan","order":0,"status":"running","ctxPct":0,
         "priorSessionIds":[],"initialPrompt":"p","archived":false,
         "createdAt":0,"updatedAt":0}
        """
        let t = try JSONDecoder.orchestra.decode(Task.self, from: Data(json.utf8))
        #expect(t.treeStat == nil)
    }

    @Test("Task round-trips a treeStat")
    func taskRoundTripsTreeStat() throws {
        var t = Task(title: "t", repo: "/r", branch: "b", cwd: "/r",
                     model: AgentModel(id: "m"), startIn: .plan, column: .plan, order: 0,
                     initialPrompt: "p")
        t.treeStat = TreeStat(state: .stale, behind: 2, parentIsRemote: false)
        let data = try JSONEncoder.orchestra.encode(t)
        let back = try JSONDecoder.orchestra.decode(Task.self, from: data)
        #expect(back.treeStat == TreeStat(state: .stale, behind: 2, parentIsRemote: false))
    }

    @Test("SpawnInput decodes with and without base (back-compat)")
    func spawnInputBaseDecode() throws {
        let without = try JSONValue.object(["prompt": .string("p")]).decode(SpawnInput.self)
        #expect(without.base == nil)
        let with = try JSONValue.object(["prompt": .string("p"), "base": .string("feature-a")])
            .decode(SpawnInput.self)
        #expect(with.base == "feature-a")
    }

    @Test("TreeSnapshot round-trips through JSONValue")
    func treeSnapshotRoundTrips() throws {
        let node = TreeNode(ref: "orchestra://task/abc", cardId: UUID(), repo: "/r", branch: "child",
                            parent: "parent", parentCardId: nil, children: ["gc"], treeStat: nil)
        let snap = TreeSnapshot(nodes: [node])
        let back = try JSONValue(encodable: snap).decode(TreeSnapshot.self)
        #expect(back == snap)
    }
}
```

Note: confirm the exact coder names used elsewhere in the codebase (`JSONDecoder.orchestra` /
`JSONEncoder.orchestra`) by grepping `Sources/OrchestraKit/Coders.swift`; if the helpers are named
differently, substitute the real names. If no such helper exists, decode via
`try JSONValue.parse(Data(json.utf8)).decode(Task.self)` instead (JSONValue is the wire codec used
throughout).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LineageModelTests`
Expected: FAIL — `TreeStat`/`TreeNode`/`TreeSnapshot` undefined, `SpawnInput` has no `base`.

- [ ] **Step 3: Add the model types**

In `Sources/OrchestraKit/Model.swift`, immediately after the `DiffBase` enum (~:152), add:

```swift
// MARK: - Tree (branch-tree lineage)

/// A child card's lineage state relative to its parent branch. Daemon-maintained like `DiffStat`;
/// nil until the parent-tree machinery (BT4) computes it. `inSync` = recorded base == parent tip;
/// `stale` = parent advanced (the `↓N` badge); `restackNeeded` = recorded base is no longer the
/// parent tip's ancestor (parent rewrote/shipped); `parentMerged` = parent landed, awaiting restack.
public enum TreeState: String, Codable, Sendable { case inSync, stale, restackNeeded, parentMerged }

/// Per-child tree status for the card face (the `↓N` badge + restack signal). Small + persisted on
/// `Task`, exactly like `DiffStat`.
public struct TreeStat: Codable, Sendable, Equatable {
    public var state: TreeState
    public var behind: Int            // commits the parent is ahead of the recorded base (the ↓N badge)
    public var parentIsRemote: Bool
    public init(state: TreeState, behind: Int = 0, parentIsRemote: Bool = false) {
        self.state = state; self.behind = behind; self.parentIsRemote = parentIsRemote
    }
}
```

In `struct Task`, after the `diffStat` property (:201) add:

```swift
    public var treeStat: TreeStat? // daemon-maintained child lineage status (BT4+); nil = none/uncomputed
```

In `Task.init`, add a parameter (place it right after `diffStat: DiffStat? = nil,`):

```swift
        treeStat: TreeStat? = nil,
```

and in the body, after `self.diffStat = diffStat`:

```swift
        self.treeStat = treeStat
```

After the `BatchSpawnFailure` struct (~:383) — i.e. alongside the other command-result shapes — add:

```swift
// MARK: - Tree snapshot (the `tree` command payload)

/// One card's lineage view: its parent ref (from git config), the derived parent *card* id (active
/// card on that branch, if any), and its child branch names. `treeStat` is nil until BT4 computes it.
public struct TreeNode: Codable, Sendable, Equatable {
    public let ref: String
    public let cardId: UUID
    public let repo: String
    public let branch: String
    public let parent: String?         // parent ref string from lineage config; nil = no parent link
    public let parentCardId: UUID?     // derived: active card whose repo+branch == this parent ref
    public let children: [String]      // child branch names (durable, card-optional)
    public let treeStat: TreeStat?     // nil in BT1
    public init(ref: String, cardId: UUID, repo: String, branch: String, parent: String?,
                parentCardId: UUID?, children: [String], treeStat: TreeStat?) {
        self.ref = ref; self.cardId = cardId; self.repo = repo; self.branch = branch
        self.parent = parent; self.parentCardId = parentCardId
        self.children = children; self.treeStat = treeStat
    }
}

/// The `tree` command result — a lineage snapshot over the requested scope.
public struct TreeSnapshot: Codable, Sendable, Equatable {
    public let nodes: [TreeNode]
    public init(nodes: [TreeNode]) { self.nodes = nodes }
}
```

- [ ] **Step 4: Add `SpawnInput.base`**

In `struct SpawnInput`, after the `seed` property (:674) add:

```swift
    /// Parent ref to branch from when the card's branch is *created* (BT2 threads it into
    /// `WorktreeManager.ensure`). Records lineage at spawn. nil ⇒ today's HEAD behavior. BT1 only
    /// carries the field on the model; the spawn threading lands in BT2.
    public var base: String?
```

In the memberwise `init(...)`, add `base: String? = nil,` to the parameter list (after `seed:`) and
`self.base = base` to the body (after `self.seed = seed`).

In the manual `init(from decoder:)`, after `self.seed = try c.decodeIfPresent(String.self, forKey: .seed)`:

```swift
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
```

(`CodingKeys` is synthesized from the stored properties, so `.base` is available automatically.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LineageModelTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraKit/Model.swift Tests/OrchestraCoreTests/LineageModelTests.swift
git commit -m "feat(bt1): add TreeStat/TreeState, Task.treeStat, SpawnInput.base, Tree snapshot types"
```

---

## Task 2: `BranchLineage` actor + `ParentLink`

**Files:**
- Create: `Sources/OrchestraCore/BranchLineage.swift`
- Test: `Tests/OrchestraCoreTests/LineageTests.swift` (new)

**Interfaces:**
- Consumes: `Proc.run`, `OrchestraError` (both OrchestraCore/OrchestraKit).
- Produces:
  - `struct ParentLink: Sendable, Equatable { var parent: String; var base: String; var prNumber: Int?; var watch: Bool; init(parent:base:prNumber:watch:) }` (defaults `prNumber: nil`, `watch: false`)
  - `actor BranchLineage` with:
    - `init()`
    - `func read(repo: String, branch: String) -> ParentLink?`
    - `func set(repo: String, branch: String, link: ParentLink) throws`  (rejects self-parent + cycle)
    - `func clear(repo: String, branch: String) throws`
    - `func updateBase(repo: String, branch: String, oid: String) throws`
    - `func children(repo: String, of parent: String) -> [String]`
    - `func ancestors(repo: String, of branch: String) -> [String]`
    - `func classify(repo: String, ref: String) -> (isRemote: Bool, shortName: String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/LineageTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("BranchLineage — git-config lineage CRUD + tree queries")
struct LineageTests {

    // MARK: fixtures

    /// A throwaway git repo (empty is fine — lineage is pure config, no branches needed).
    static func makeRepo(withOrigin: Bool = false) throws -> String {
        let dir = NSTemporaryDirectory() + "orch-lineage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "config", "user.email", "t@t")
        try git(dir, "config", "user.name", "t")
        if withOrigin { try git(dir, "remote", "add", "origin", "file:///dev/null") }
        return dir
    }
    @discardableResult
    static func git(_ dir: String, _ args: String...) throws -> ProcResult {
        let r = try Proc.run(["git", "-C", dir] + args)
        #expect(r.ok, "git \(args.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }

    // MARK: CRUD round-trips

    @Test("set/read round-trip — local parent")
    func roundTripLocal() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "feature-a", base: "deadbeef"))
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "feature-a")
        #expect(got.base == "deadbeef")
        #expect(got.prNumber == nil)
        #expect(got.watch == false)
    }

    @Test("set/read round-trip — remote parent with PR + watch keys")
    func roundTripRemote() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "origin/feature-b", base: "cafe", prNumber: 12, watch: true))
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "origin/feature-b")
        #expect(got.prNumber == 12)
        #expect(got.watch == true)
    }

    @Test("clear removes all orchestra-* keys")
    func clearAll() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "p", base: "b", prNumber: 3, watch: true))
        try await lin.clear(repo: repo, branch: "child")
        #expect(await lin.read(repo: repo, branch: "child") == nil)
    }

    @Test("updateBase rewrites only the base OID")
    func updateBaseOnly() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "old"))
        try await lin.updateBase(repo: repo, branch: "child", oid: "new")
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "p")
        #expect(got.base == "new")
    }

    @Test("read of an unlinked branch → nil")
    func readUnlinked() async throws {
        let repo = try Self.makeRepo()
        #expect(await BranchLineage().read(repo: repo, branch: "nope") == nil)
    }

    // MARK: cycle guard

    @Test("self-parent rejected")
    func selfParentRejected() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "x", link: ParentLink(parent: "x", base: "b"))
        }
    }

    @Test("a cycle is rejected — root adopting its own descendant")
    func cycleRejected() async throws {
        // a → b → c  (a.parent=b, b.parent=c). Now try c.parent=a, which closes a→b→c→a.
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "a", base: "1"))
        }
    }

    // MARK: children / ancestors

    @Test("children finds every branch whose parent is the target (fan-out)")
    func childrenFanOut() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        for c in ["c1", "c2", "c3"] {
            try await lin.set(repo: repo, branch: c, link: ParentLink(parent: "p", base: "b"))
        }
        try await lin.set(repo: repo, branch: "other", link: ParentLink(parent: "q", base: "b"))
        #expect(Set(await lin.children(repo: repo, of: "p")) == ["c1", "c2", "c3"])
        #expect(await lin.children(repo: repo, of: "q") == ["other"])
    }

    @Test("ancestors walks the parent chain nearest-first")
    func ancestorsChain() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        #expect(await lin.ancestors(repo: repo, of: "a") == ["b", "c"])
    }

    @Test("foreign git-config keys are untouched by clear + ignored by children")
    func foreignKeysUntouched() async throws {
        let repo = try Self.makeRepo()
        try Self.git(repo, "config", "branch.child.description", "hello")
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "b"))
        try await lin.clear(repo: repo, branch: "child")
        // The non-orchestra key survives.
        let desc = try Self.git(repo, "config", "--get", "branch.child.description").stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(desc == "hello")
        // A branch with only a description (no orchestra-parent) is not a child.
        #expect(await lin.children(repo: repo, of: "p").isEmpty)
    }

    // MARK: canonical parse

    @Test("classify — local vs origin/ remote")
    func classifyRefs() async throws {
        let repo = try Self.makeRepo(withOrigin: true)
        let lin = BranchLineage()
        #expect(await lin.classify(repo: repo, ref: "feature-a") == (false, "feature-a"))
        #expect(await lin.classify(repo: repo, ref: "origin/feature-b") == (true, "feature-b"))
        // A local branch name that merely contains a slash (no remote named `feature`) stays local.
        #expect(await lin.classify(repo: repo, ref: "feature/foo") == (false, "feature/foo"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LineageTests`
Expected: FAIL — `BranchLineage`/`ParentLink` undefined.

- [ ] **Step 3: Write `BranchLineage.swift`**

Create `Sources/OrchestraCore/BranchLineage.swift`:

```swift
import Foundation

/// The durable parent link for one branch, mirrored 1:1 to `branch.<child>.orchestra-*` git-config
/// keys. `parent` is the parent ref string (`feature-a` local / `origin/feature-b` remote); `base` is
/// the parent tip OID recorded at the last sync/restack (the redirect anchor); `prNumber`/`watch`
/// ride the optional remote-parent keys.
public struct ParentLink: Sendable, Equatable {
    public var parent: String
    public var base: String
    public var prNumber: Int?
    public var watch: Bool
    public init(parent: String, base: String, prNumber: Int? = nil, watch: Bool = false) {
        self.parent = parent; self.base = base; self.prNumber = prNumber; self.watch = watch
    }
}

/// git-config CRUD for branch lineage — the single source of truth for the parent link. It survives
/// card churn, is plain-git readable (git-town/Graphite style), and never touches refs or worktrees.
/// Writes happen daemon-side (read-only cards have `git config` blocked at launch), so this is the
/// one writer. Every op is `Proc.run(["git","-C",repo,"config",…])` — the house git idiom.
public actor BranchLineage {
    public init() {}

    private static let kParent = "orchestra-parent"
    private static let kBase   = "orchestra-parent-base"
    private static let kPr     = "orchestra-parent-pr"
    private static let kWatch  = "orchestra-parent-watch"
    private static let allSuffixes = [kParent, kBase, kPr, kWatch]

    private func key(_ branch: String, _ suffix: String) -> String { "branch.\(branch).\(suffix)" }

    private func get(_ repo: String, _ branch: String, _ suffix: String) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "config", "--get", key(branch, suffix)]),
              r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func setKey(_ repo: String, _ branch: String, _ suffix: String, _ value: String) throws {
        let r = try Proc.run(["git", "-C", repo, "config", key(branch, suffix), value])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "git config write failed" : r.stderr) }
    }

    /// `--unset` one key; exit 5 (key absent) is not an error.
    private func unset(_ repo: String, _ branch: String, _ suffix: String) {
        _ = try? Proc.run(["git", "-C", repo, "config", "--unset", key(branch, suffix)])
    }

    // MARK: CRUD

    /// The parent link for `branch`, or nil if it has no `orchestra-parent` key.
    public func read(repo: String, branch: String) -> ParentLink? {
        guard let parent = get(repo, branch, Self.kParent) else { return nil }
        return ParentLink(parent: parent,
                          base: get(repo, branch, Self.kBase) ?? "",
                          prNumber: get(repo, branch, Self.kPr).flatMap(Int.init),
                          watch: get(repo, branch, Self.kWatch) == "true")
    }

    /// Write the link's keys. Rejects self-parent and cycles (via `ancestors`) with `.invalidParams`.
    public func set(repo: String, branch: String, link: ParentLink) throws {
        guard link.parent != branch else {
            throw OrchestraError.invalidParams("a branch cannot be its own parent: \(branch)")
        }
        // If `branch` already sits above the proposed parent, adopting it would close a loop.
        if ancestors(repo: repo, of: link.parent).contains(branch) {
            throw OrchestraError.invalidParams("parent link would create a cycle: \(branch) → \(link.parent)")
        }
        try setKey(repo, branch, Self.kParent, link.parent)
        try setKey(repo, branch, Self.kBase, link.base)
        if let pr = link.prNumber { try setKey(repo, branch, Self.kPr, String(pr)) }
        else { unset(repo, branch, Self.kPr) }
        if link.watch { try setKey(repo, branch, Self.kWatch, "true") }
        else { unset(repo, branch, Self.kWatch) }
    }

    /// Remove every `orchestra-*` lineage key for `branch` (tolerates already-unset keys).
    public func clear(repo: String, branch: String) throws {
        for suffix in Self.allSuffixes { unset(repo, branch, suffix) }
    }

    /// Update just the recorded parent-tip OID (after a sync/restack).
    public func updateBase(repo: String, branch: String, oid: String) throws {
        try setKey(repo, branch, Self.kBase, oid)
    }

    // MARK: tree queries

    /// Child branch names whose recorded parent is `parent` — a fan-out over all lineage keys.
    public func children(repo: String, of parent: String) -> [String] {
        let pattern = "^branch\\..*\\.\(Self.kParent)$"
        guard let r = try? Proc.run(["git", "-C", repo, "config", "--get-regexp", pattern]), r.ok
        else { return [] }
        var out: [String] = []
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard value == parent, name.hasPrefix("branch."), name.hasSuffix(".\(Self.kParent)")
            else { continue }
            let child = String(name.dropFirst("branch.".count).dropLast(".\(Self.kParent)".count))
            if !child.isEmpty { out.append(child) }
        }
        return out
    }

    /// The parent chain above `branch`, nearest first (cycle-safe via a visited set).
    public func ancestors(repo: String, of branch: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [branch]
        var cur = branch
        while let link = read(repo: repo, branch: cur) {
            let p = link.parent
            if seen.contains(p) { break }   // defensive: a pre-existing cycle can't loop us forever
            out.append(p); seen.insert(p); cur = p
        }
        return out
    }

    // MARK: canonical parse

    /// Classify a parent ref: `origin/foo` (first `/`-segment names a configured remote) ⇒ remote;
    /// `shortName` strips the remote prefix. A plain name, or a slashed name whose first segment is
    /// not a remote, stays local.
    public func classify(repo: String, ref: String) -> (isRemote: Bool, shortName: String) {
        guard let slash = ref.firstIndex(of: "/") else { return (false, ref) }
        let first = String(ref[..<slash])
        let remotes = (try? Proc.run(["git", "-C", repo, "remote"]))?.stdout
            .split(separator: "\n").map(String.init) ?? []
        return remotes.contains(first)
            ? (true, String(ref[ref.index(after: slash)...]))
            : (false, ref)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LineageTests`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/BranchLineage.swift Tests/OrchestraCoreTests/LineageTests.swift
git commit -m "feat(bt1): BranchLineage actor — git-config lineage CRUD, cycle guard, canonical parse"
```

---

## Task 3: Churn derivation in `OrchestraService.spawn`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `lineage` property ~:33; worktree arm
  of `spawn` :239-244; `Task(...)` init :283-291)
- Test: `Tests/OrchestraCoreTests/LineageSpawnTests.swift` (new)

**Interfaces:**
- Consumes: `BranchLineage` (Task 2).
- Produces: `OrchestraService.lineage: BranchLineage` (internal `let`); spawning onto a worktree
  branch that already carries an `orchestra-parent` config key sets `Task.parentBranch` from it.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/LineageSpawnTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn churn-derivation — parentBranch re-derived from git config")
struct LineageSpawnTests {

    /// git-init a real repo under the env's reposRoot so `git config` reads succeed (StubWorktrees
    /// still cuts the fake worktree — churn derivation reads config from the repo, not the worktree).
    static func gitRepo(_ base: String, _ name: String = "app") throws -> String {
        let p = TestEnv.repo(base, name)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        return p
    }

    @Test("spawning onto a branch with lineage config derives parentBranch")
    func derivesParentFromConfig() async throws {
        let env = TestEnv.make()
        let repo = try Self.gitRepo(env.base)
        // Pre-seed durable lineage for branch "child" (as if a prior card set it, then archived).
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child"))
        #expect(t.parentBranch == "parent")
    }

    @Test("spawning onto a branch with no lineage config leaves parentBranch nil")
    func noConfigNoParent() async throws {
        let env = TestEnv.make()
        let repo = try Self.gitRepo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LineageSpawnTests`
Expected: FAIL — `derivesParentFromConfig` gets `parentBranch == nil` (churn derivation not wired).

- [ ] **Step 3: Add the `lineage` property**

In `Sources/OrchestraCore/OrchestraService.swift`, among the stored properties (e.g. right after
`let mergeWatch = MergeWatch()` ~:33), add:

```swift
    /// Branch-tree lineage store (git-config parent links). The single writer; `Task.parentBranch`
    /// is a cache derived from it at spawn/set-parent.
    let lineage = BranchLineage()
```

- [ ] **Step 4: Wire churn derivation into `spawn`**

In `spawn`, declare a holder before the scratch/borrowed/worktree `if` chain — add right after the
`let origin: CardOrigin` declaration (~:229):

```swift
        var derivedParentBranch: String? = nil
```

In the worktree arm (the `else` at :239-244), after `origin = .worktree`, add:

```swift
            // Churn derivation: a pre-existing branch may still carry durable lineage in git config
            // (the parent link survives card archival). Re-derive the parentBranch cache from it so
            // a re-spawn onto the same branch is parent-aware without re-passing `base`.
            derivedParentBranch = await lineage.read(repo: realRepo, branch: input.branch)?.parent
```

In the `Task(...)` initializer (:283-291), add the `parentBranch:` argument. Place it after
`priorSessionIds`/before `initialPrompt` is fine — the init is fully keyworded; add:

```swift
            parentBranch: derivedParentBranch,
```

(Confirm the argument slots against the `Task.init` signature — `parentBranch` has a default, so its
position among the keyword args is free; just ensure it appears exactly once.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LineageSpawnTests`
Expected: PASS (2 tests). Also run `swift test --filter CommandsTests` to confirm existing spawn
tests (plain non-git repos) still pass — churn read degrades to nil on a non-git dir.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/LineageSpawnTests.swift
git commit -m "feat(bt1): derive Task.parentBranch from branch lineage config at spawn (churn-proof)"
```

---

## Task 4: `set-parent` command (adopt + clear)

**Files:**
- Create: `Sources/OrchestraCore/OrchestraService+Tree.swift`
- Modify: `Sources/OrchestraKit/CommandCatalog.swift` (add `set-parent` schema)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift` (add `set-parent` handler)
- Modify: `Sources/orchestra/CLIRunner.swift` (add `set-parent` case)
- Modify: `Sources/orchestra/CLIHelp.swift` (help line)
- Modify: `Tests/OrchestraCoreTests/CommandsTests.swift` (add `set-parent` to `fullSet`)
- Modify: `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` (add `set-parent` to the set)
- Test: `Tests/OrchestraCoreTests/TreeCommandTests.swift` (new — shared with Task 5)

**Interfaces:**
- Consumes: `BranchLineage`, `resolveRef`, `store.update`, `emit`, `emitActivity`.
- Produces:
  - `OrchestraService.setParent(ref: String, parent: String?, mode: String = "adopt", source: ActivitySource = .daemon) async throws -> Task`
  - `OrchestraService.tree(ref: String?, repo: String?) async throws -> TreeSnapshot` (defined in this
    file too — Task 5 adds its command wiring)
  - Catalog `set-parent` schema (params `{ref (required), parent?, mode?}`, exposure `.all`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/TreeCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("set-parent / tree commands")
struct TreeCommandTests {

    /// A real git repo under reposRoot with `main`, and two branches (`parent`, `child`) that share
    /// `main`'s base commit — enough for a real `merge-base`. StubWorktrees still cuts the fake
    /// worktree; the merge-base + config all resolve against this repo.
    static func repoWithBranches(_ base: String) throws -> String {
        let p = TestEnv.repo(base)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try "base\n".write(toFile: p + "/a.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "base")
        try git("branch", "parent")
        try git("branch", "child")
        return p
    }

    @Test("set-parent adopt records lineage, base = merge-base, and updates parentBranch")
    func adopt() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child"))
        let updated = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        #expect(updated.parentBranch == "parent")
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        let mb = try Proc.run(["git", "-C", repo, "merge-base", "child", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(link.base == mb)
    }

    @Test("set-parent with no parent clears the link")
    func clear() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        let cleared = try await env.svc.setParent(ref: t.shortId, parent: nil)
        #expect(cleared.parentBranch == nil)
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    @Test("set-parent mode 'move' is rejected in BT1")
    func moveRejected() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child"))
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.setParent(ref: t.shortId, parent: "parent", mode: "move")
        }
    }

    @Test("set-parent dispatches through the registry")
    func setParentViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("set-parent"))
        let out = try await cmd.run(env.svc,
            .object(["ref": .string(t.shortId), "parent": .string("parent")]), .mcp)
        #expect(try out.decode(Task.self).parentBranch == "parent")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TreeCommandTests`
Expected: FAIL — `setParent` / the `set-parent` command undefined.

- [ ] **Step 3: Write `OrchestraService+Tree.swift`**

Create `Sources/OrchestraCore/OrchestraService+Tree.swift` (defines BOTH `setParent` and `tree` +
the `mergeBaseOID` helper — Task 5 only wires `tree`'s command surface):

```swift
import Foundation

extension OrchestraService {

    /// `set-parent` (BT1: adopt + clear). `parent == nil`/empty clears the link; otherwise adopts it
    /// with `base := merge-base(branch, parent)` — a metadata-only relink, history untouched.
    /// `mode` other than "adopt" (i.e. "move", which transplants commits) is deferred to a later PR.
    @discardableResult
    public func setParent(ref: String, parent: String?, mode: String = "adopt",
                          source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a branch to re-parent")
        }
        guard mode == "adopt" else {
            throw OrchestraError.invalidParams("mode must be 'adopt' (move is not yet available)")
        }
        let trimmed = parent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = trimmed, !p.isEmpty {
            guard p != t.branch else {
                throw OrchestraError.invalidParams("a branch cannot be its own parent: \(p)")
            }
            let base = try mergeBaseOID(repo: t.repo, t.branch, p)
            try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: base))
            let updated = try await store.update(t.id) { $0.parentBranch = p }
            emit(.taskUpserted(updated))
            emitActivity(.command, updated, source, "set parent → \(p)")
            return updated
        } else {
            try await lineage.clear(repo: t.repo, branch: t.branch)
            let updated = try await store.update(t.id) { $0.parentBranch = nil }
            emit(.taskUpserted(updated))
            emitActivity(.command, updated, source, "cleared parent link")
            return updated
        }
    }

    /// `tree` — a lineage snapshot for a scope: one card (`ref`), a `repo`, or all active cards.
    /// Feeds MCP/CLI (and BT7's board grouping). `treeStat` rides through as-is (nil in BT1).
    public func tree(ref: String?, repo: String?) async throws -> TreeSnapshot {
        let active = await store.all().filter { !$0.archived }
        var scoped = active
        if let ref {
            scoped = [try await resolveRef(ref)]
        } else if let repo {
            let real = (try? resolver.resolveRepo(repo)) ?? repo
            scoped = active.filter { $0.repo == real }
        }
        var nodes: [TreeNode] = []
        for t in scoped where t.origin == .worktree {
            let link = await lineage.read(repo: t.repo, branch: t.branch)
            let children = await lineage.children(repo: t.repo, of: t.branch)
            let parentCardId = link.flatMap { l in
                active.first { $0.repo == t.repo && $0.branch == l.parent }?.id
            }
            nodes.append(TreeNode(ref: t.ref(), cardId: t.id, repo: t.repo, branch: t.branch,
                                  parent: link?.parent, parentCardId: parentCardId,
                                  children: children, treeStat: t.treeStat))
        }
        return TreeSnapshot(nodes: nodes)
    }

    /// `git merge-base <a> <b>` in `repo`, or `.invalidParams` if there is none (e.g. unknown parent).
    private func mergeBaseOID(repo: String, _ a: String, _ b: String) throws -> String {
        let r = try Proc.run(["git", "-C", repo, "merge-base", a, b])
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !oid.isEmpty else {
            throw OrchestraError.invalidParams(
                "no merge-base between \(a) and \(b)" + (r.stderr.isEmpty ? "" : ": \(r.stderr)"))
        }
        return oid
    }
}
```

- [ ] **Step 4: Add the `set-parent` catalog schema**

In `Sources/OrchestraKit/CommandCatalog.swift`, add to the `all` array (e.g. right after the
`handoff` entry, before `status`):

```swift
        CommandSchema(name: "set-parent",
                      summary: "Set or clear a card branch's parent link. With `parent`: adopt it "
                          + "(records parent + merge-base, history untouched). Omit `parent` to clear.",
                      params: schema([
                          "ref": refProp(),
                          "parent": strProp("Parent branch ref to adopt (local name). Omit to clear the link."),
                          "mode": strProp("'adopt' (default): metadata-only relink; base = merge-base."),
                      ], required: ["ref"])),
```

- [ ] **Step 5: Add the `set-parent` registry handler**

In `Sources/OrchestraCore/CommandRegistry.swift`, add to the `handlers` dictionary:

```swift
            "set-parent": { svc, p, src in
                let updated = try await svc.setParent(
                    ref: try p.string("ref"),
                    parent: p.optString("parent"),
                    mode: p.optString("mode") ?? "adopt",
                    source: src)
                return try JSONValue(encodable: updated)
            },
```

- [ ] **Step 6: Update the two pairing-test command sets**

In `Tests/OrchestraCoreTests/CommandsTests.swift`, `fullSet`, add `"set-parent"` to the `expected`
array. In `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift`,
`testCatalogHasAllCommands`, add `"set-parent"` to the literal set.

- [ ] **Step 7: Add the `set-parent` CLI case + help**

In `Sources/orchestra/CLIRunner.swift`, add a case to the `switch verb`:

```swift
            case "set-parent":
                let ref = flags.positional(0) ?? flags.require("ref")
                var params: [String: JSONValue] = ["ref": .string(ref)]
                if let parent = flags.value("parent") ?? flags.positional(1) {
                    params["parent"] = .string(parent)
                }
                if let mode = flags.value("mode") { params["mode"] = .string(mode) }
                let task = try await client.call("set-parent", .object(params))
                printRef(task)
```

In `Sources/orchestra/CLIHelp.swift`, add under COMMANDS (near `move`):

```
      set-parent <ref> [parent] [--mode adopt]    Set/clear a card branch's parent link (omit parent to clear)
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter TreeCommandTests` → PASS (4 tests).
Run: `swift test --filter CommandsTests` and `swift test --filter CommandRegistryCatalogTests` →
PASS (pairing assertions include `set-parent`).

- [ ] **Step 9: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraKit/CommandCatalog.swift \
        Sources/OrchestraCore/CommandRegistry.swift Sources/orchestra/CLIRunner.swift \
        Sources/orchestra/CLIHelp.swift Tests/OrchestraCoreTests/CommandsTests.swift \
        Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift \
        Tests/OrchestraCoreTests/TreeCommandTests.swift
git commit -m "feat(bt1): set-parent command (adopt/clear) with merge-base base + catalog/registry/CLI"
```

---

## Task 5: `tree` command wiring (catalog + registry + CLI)

**Files:**
- Modify: `Sources/OrchestraKit/CommandCatalog.swift` (add `tree` schema)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift` (add `tree` handler)
- Modify: `Sources/orchestra/CLIRunner.swift` (add `tree` case)
- Modify: `Sources/orchestra/CLIHelp.swift` (help line)
- Modify: `Tests/OrchestraCoreTests/CommandsTests.swift` (add `tree` to `fullSet`)
- Modify: `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` (add `tree` to the set)
- Test: `Tests/OrchestraCoreTests/TreeCommandTests.swift` (extend — the `tree` cases)

**Interfaces:**
- Consumes: `OrchestraService.tree(ref:repo:)` (already defined in Task 4's file), `TreeSnapshot`/`TreeNode`.
- Produces: catalog `tree` schema (params `{ref?, repo?}`, exposure `.all`) + its handler + CLI case.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/OrchestraCoreTests/TreeCommandTests.swift` (inside the suite):

```swift
    @Test("tree reports parent + derived parentCardId + children")
    func treeSnapshot() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: child.shortId, parent: "parent")

        let snap = try await env.svc.tree(ref: nil, repo: nil)
        let childNode = try #require(snap.nodes.first { $0.branch == "child" })
        #expect(childNode.parent == "parent")
        #expect(childNode.parentCardId == parent.id)
        let parentNode = try #require(snap.nodes.first { $0.branch == "parent" })
        #expect(parentNode.children == ["child"])
        #expect(parentNode.parent == nil)
    }

    @Test("tree scoped by ref returns just that card's node")
    func treeScopedByRef() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        let snap = try await env.svc.tree(ref: child.shortId, repo: nil)
        #expect(snap.nodes.map(\.branch) == ["child"])
    }

    @Test("tree dispatches through the registry")
    func treeViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("tree"))
        let out = try await cmd.run(env.svc, .object([:]), .mcp)
        #expect(try out.decode(TreeSnapshot.self).nodes.contains { $0.branch == "child" })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TreeCommandTests`
Expected: FAIL — `reg.command("tree")` is nil (no catalog entry / handler yet). (The direct
`svc.tree(...)` cases may already pass since Task 4 defined `tree`; the registry case fails.)

- [ ] **Step 3: Add the `tree` catalog schema**

In `Sources/OrchestraKit/CommandCatalog.swift`, add right after the `set-parent` entry:

```swift
        CommandSchema(name: "tree",
                      summary: "Lineage snapshot — parent/children per card. Scope by `ref` or `repo`; "
                          + "omit both for all active cards.",
                      params: schema([
                          "ref": refProp(),
                          "repo": strProp("Limit to cards in this repo root."),
                      ], required: [])),
```

- [ ] **Step 4: Add the `tree` registry handler**

In `Sources/OrchestraCore/CommandRegistry.swift`, add to `handlers`:

```swift
            "tree": { svc, p, _ in
                // Read-only lineage query (like `list`): not logged, to keep the activity feed clean.
                let snap = try await svc.tree(ref: p.optString("ref"), repo: p.optString("repo"))
                return try JSONValue(encodable: snap)
            },
```

- [ ] **Step 5: Update the two pairing-test command sets**

Add `"tree"` to `CommandsTests.fullSet`'s `expected` array and to
`CommandRegistryCatalogTests.testCatalogHasAllCommands`'s literal set.

- [ ] **Step 6: Add the `tree` CLI case + help**

In `Sources/orchestra/CLIRunner.swift`:

```swift
            case "tree":
                var params: [String: JSONValue] = [:]
                if let ref = flags.value("ref") ?? flags.positional(0) { params["ref"] = .string(ref) }
                if let repo = flags.value("repo") { params["repo"] = .string(repo) }
                let r = try await client.call("tree", .object(params))
                printJSON(r)
```

In `Sources/orchestra/CLIHelp.swift`, add near `set-parent`:

```
      tree [ref] [--repo <r>]                    Lineage snapshot (parent/children per card, JSON)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter TreeCommandTests` → PASS (7 tests total in the suite).
Run: `swift test --filter CommandsTests` + `swift test --filter CommandRegistryCatalogTests` → PASS.

- [ ] **Step 8: Full suite + commit**

Run the whole suite to confirm nothing regressed (including the `E2EBinaryTests` MCP-tool assertion,
which derives from `CommandCatalog.mcpExposed` and stays consistent automatically):

Run: `swift build && swift test`
Expected: PASS (all suites).

```bash
git add Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift \
        Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift \
        Tests/OrchestraCoreTests/CommandsTests.swift \
        Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift \
        Tests/OrchestraCoreTests/TreeCommandTests.swift
git commit -m "feat(bt1): tree command — lineage snapshot query via catalog/registry/CLI"
```

---

## Self-Review

**Spec coverage (BT1 row of `03-implementation.md` §Sequencing + `04-tests.md` unit table):**
- `BranchLineage` + `ParentLink` (CRUD, cycle guard, children/ancestors, canonical parse) → Task 2;
  tests cover set/read round-trip (local/remote/PR), clear, updateBase, unknown-read→nil, self-parent,
  cycle, children fan-out, ancestors chain, foreign-keys-untouched, canonical parse. ✓ (matches the
  `04-tests.md` "BranchLineage CRUD / Cycle guard / children·ancestors / Canonical parse" rows.)
- Model additions (`TreeStat`/`TreeState`, `Task.treeStat` decode-default-nil, `SpawnInput.base`
  decode-default-nil) → Task 1; back-compat + round-trip tests. ✓ (`04-tests.md` "Spawn param" +
  ModelTests-ext rows.)
- `set-parent` (adopt + clear ONLY; move rejected) → Task 4. ✓ (`04-tests.md` "set-parent" row's
  adopt-base-=-merge-base + no-nudge; move/restack machinery is out of BT1.)
- `tree` snapshot query → Task 5. ✓
- Catalog/registry pairing extends to the 2 new commands → Tasks 4-5 update both pairing tests. ✓
  (`04-tests.md` "Catalog/registry pairing" row.)
- Churn derivation in `spawn` → Task 3. ✓ (`04-tests.md` integration "Churn derivation" — BT1 half:
  parent re-derived from config at spawn; the diff-baseline half is BT3.)
- CLI cases → Tasks 4-5. ✓

**Deliberately out of BT1 (documented, not gaps):** `synced`/`shipped` commands, `set-parent move`,
`TreeStat` recompute + funnel hook + stale nudge, diff baseline switch, `WorktreeManager.ensure(base:)`
+ spawn `base` threading, `RemoteParents`/`GhProbe`, `TreeDocs`, board UI. These are BT2–BT7.

**Placeholder scan:** none — every code step shows complete code; every test step shows the assertions.

**Type consistency check:**
- `ParentLink(parent:base:prNumber:watch:)` — same call shape in Tasks 2, 3, 4, and every test.
- `TreeStat(state:behind:parentIsRemote:)` — Task 1 definition matches Task 1 tests.
- `setParent(ref:parent:mode:source:)` — Task 4 signature matches Task 4/5 tests and the registry handler.
- `tree(ref:repo:)` — defined in Task 4's file, wired in Task 5; tests call the same signature.
- `TreeNode(ref:cardId:repo:branch:parent:parentCardId:children:treeStat:)` — Task 1 init matches the
  `tree(...)` construction in Task 4 and the Task 1/5 tests.
- `lineage.read(repo:branch:)` / `.set(repo:branch:link:)` / `.children(repo:of:)` / `.classify(repo:ref:)`
  — one signature each across Tasks 2, 3, 4, 5.

**Uncertainties to verify during execution (don't block; adjust to the real code):**
1. Coder helper names in Task 1 Step 1 (`JSONDecoder.orchestra`/`JSONEncoder.orchestra`) — grep
   `Coders.swift`; fall back to `JSONValue.parse(...).decode(...)` if absent.
2. The exact insertion slot for `parentBranch:` in the `Task(...)` init inside `spawn` — it is fully
   keyworded, so placement is free; just ensure it appears once and reads `derivedParentBranch`.
3. `emitActivity(.command, …)` — confirm `.command` is the intended `ActivityKind` for a lineage
   change (it is the generic command-log kind); harmless if adjusted.
