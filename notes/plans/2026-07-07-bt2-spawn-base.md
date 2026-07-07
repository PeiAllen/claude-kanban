# BT2 — Spawn-with-Base Threading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thread a `base` parameter end-to-end so a card can be spawned **on top of an existing local
branch** — the new worktree branch starts at that base's tip, and the parent link is recorded in
lineage config at creation (`branch.<child>.orchestra-parent` = base, `-base` = base tip OID) so the
card is parent-aware from spawn.

**Architecture:** `SpawnInput.base` (already on the model from BT1) flows: CommandCatalog `spawn`
(+`batch-spawn`) param → CommandRegistry handler → `OrchestraService.spawn`. In spawn, when a **new**
branch is cut with a `base`, `WorktreeManager.ensure(repo:branch:base:)` passes the base as git's
start-point (`git worktree add -b <branch> <wt> <base>`), and a new `recordSpawnBase` helper
(OrchestraService+Tree.swift) writes lineage via `BranchLineage.set` (parent = base, recorded base OID
= base tip) and returns the canonical parent for `Task.parentBranch`. Spawning onto a **pre-existing**
branch ignores `base` and keeps BT1's churn derivation (parent re-read from config). CLI, `BoardStore`,
and both spawn sheets grow a base picker sourced from the existing branch list.

**Tech Stack:** Swift 6 (actors, swift-testing `#expect`/`@Test`), real-git throwaway-repo fixtures
(the `WorktreeManagerTests.makeRepo()` / `DiffProviderTests.makeRepo()` pattern), no git mocking.

## Global Constraints

- **Scope is BT2 only** (per `notes/designs/parent-card-branch-linking/03-implementation.md`
  §Sequencing, BT2 row). IN: `WorktreeManager.ensure(base:)` start-point on the new-branch arm only;
  `base` param across catalog (`spawn`+`batch-spawn`) / registry / CLI / `BoardStore.spawn`; lineage
  recording in `OrchestraService.spawn`; base picker in both spawn sheets (**local** branches, with an
  extension point for BT6's remote entries). OUT: remote/PR bases + `RemoteParents.fetch` (BT6); diff
  baseline switch (BT3); `TreeStat` recompute / `synced` / stale nudge / `scheduleTreeStat` (BT4);
  `shipped` / `set-parent move` / TreeDocs (BT5). **Do not touch diff code or TreeStat recompute.**
- **Build on BT1, do not re-create it.** `BranchLineage` (`Sources/OrchestraCore/BranchLineage.swift`),
  `ParentLink`, `SpawnInput.base` (`Model.swift:727`), `TreeStat`/`TreeState`, `set-parent`/`tree`
  commands, `OrchestraService.lineage`, and the `spawn` churn-derivation block
  (`OrchestraService.swift:249-255`) all already exist and are merged.
- **Coordination:** BT4 runs in parallel and also touches CommandCatalog / CommandRegistry /
  OrchestraService. Keep every edit **minimal and additive** — new params/entries/helpers only, no
  refactors of shared blocks. The orchestrator resolves merge conflicts.
- **Design for BOTH Claude and Codex** — no `if agent == "claude"` branches. `base` is agent-agnostic
  (worktree + git-config only), so this is automatic here.
- **Branch base is `plan/parent-card-branch-linking`** — never touch `main` or the plan branch; do not
  modify other cards' work.
- **git idiom:** every git call is `Proc.run(["git","-C",repo, …])` with an `[String]` argv — never an
  interpolated shell string.
- **Error type:** unknown base ⇒ `OrchestraError.invalidParams(...)` (no `unknownBranch` case exists).
- **Behavioral contract (verbatim from L2 §Spawn threading):** `base` applies only when the branch is
  *created*; spawning onto an existing branch **ignores** `base` and derives `parentBranch` from
  `lineage.read`. Unknown base ⇒ `invalidParams`, **no half-created worktree**. Default (no `base`) =
  today's HEAD behavior, byte-for-byte.

## File Structure

**Modified source files**
- `Sources/OrchestraCore/Protocols.swift` — `WorktreeManaging.ensure` gains a `base: String?` param;
  a convenience extension keeps the no-base callsite (recovery) working.
- `Sources/OrchestraCore/WorktreeManager.swift` — `ensure(repo:branch:base:)`: validate + pass the
  start-point on the new-branch arm only.
- `Sources/OrchestraCore/OrchestraService.swift` — `spawn`'s worktree arm passes `base` to `ensure`
  and, for a newly-created branch with a base, records lineage (one added `else if`).
- `Sources/OrchestraCore/OrchestraService+Tree.swift` — new `recordSpawnBase(repo:branch:base:)` +
  private `revParseOID` helper (lineage-adjacent logic lives here, minimizing spawn's diff surface).
- `Sources/OrchestraKit/CommandCatalog.swift` — `"base"` param on `spawn`; `batch-spawn` summary note.
- `Sources/OrchestraCore/CommandRegistry.swift` — `spawn` + `batch-spawn` handlers thread `base`.
- `Sources/orchestra/CLIRunner.swift` — `--base` merged into the `spawn` params.
- `Sources/orchestra/CLIHelp.swift` — `--base` help line under `spawn`.
- `Sources/OrchestraUI/BoardStore.swift` — `spawn(...)` gains a `base: String?` param, forwarded as
  the `base` field.
- `App/Views/SpawnSheet.swift` — desktop base picker (reuses the branch combo pattern).
- `App-iOS/Views/SpawnSheet.swift` — iOS base picker (reuses `SpawnPickerField`).

**Modified test files**
- `Tests/IntegrationTests/WorktreeManagerTests.swift` — three `ensure(base:)` cases (real git).

**New test files**
- `Tests/OrchestraCoreTests/SpawnBaseTests.swift` — service-level spawn-with-base integration.

---

## Task 1: `WorktreeManager.ensure(repo:branch:base:)` — start-point on the new-branch arm

**Files:**
- Modify: `Sources/OrchestraCore/Protocols.swift:6-13` (protocol + convenience extension)
- Modify: `Sources/OrchestraCore/WorktreeManager.swift:20-49` (`ensure`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift:22-27` (`StubWorktrees.ensure`)
- Test: `Tests/IntegrationTests/WorktreeManagerTests.swift` (append 3 cases)

**Interfaces:**
- Consumes: `Proc.run`, `OrchestraError`, `branchExists` (existing).
- Produces:
  - `WorktreeManaging.ensure(repo: String, branch: String, base: String?) throws -> (worktree: String, created: Bool, branchExisted: Bool)` (protocol requirement).
  - `WorktreeManaging.ensure(repo:branch:)` convenience (extension) — forwards `base: nil`.
  - `WorktreeManager.ensure(repo: String, branch: String, base: String? = nil)` (concrete).

- [ ] **Step 1: Write the failing tests**

Append these three tests inside the `WorktreeManagerTests` suite in
`Tests/IntegrationTests/WorktreeManagerTests.swift` (they reuse the file's `makeRepo()`):

```swift
    @Test("ensure with a base starts a NEW branch at the base's tip")
    func ensureNewBranchAtBase() throws {
        let (repo, config) = try makeRepo()
        // A second commit on a `base` branch so its tip differs from main's first commit.
        try Proc.checked(["git", "-C", repo, "branch", "base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "base"])
        try "more".write(toFile: repo + "/B.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "on base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "main"])
        let baseTip = try Proc.checked(["git", "-C", repo, "rev-parse", "base"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wm = WorktreeManager(config: config)
        let (wt, created, branchExisted) = try wm.ensure(repo: repo, branch: "child", base: "base")
        #expect(created)
        #expect(!branchExisted)   // child is a fresh -b branch
        let childTip = try Proc.checked(["git", "-C", wt, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childTip == baseTip)   // started AT the base tip, not main
    }

    @Test("ensure on an EXISTING branch ignores base")
    func ensureExistingIgnoresBase() throws {
        let (repo, config) = try makeRepo()
        // `existing` sits at main's tip; `base` has an extra commit ahead of it.
        try Proc.checked(["git", "-C", repo, "branch", "existing"])
        let existingTip = try Proc.checked(["git", "-C", repo, "rev-parse", "existing"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Proc.checked(["git", "-C", repo, "branch", "base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "base"])
        try "x".write(toFile: repo + "/C.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "ahead"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "main"])

        let wm = WorktreeManager(config: config)
        let (wt, _, branchExisted) = try wm.ensure(repo: repo, branch: "existing", base: "base")
        #expect(branchExisted)
        let head = try Proc.checked(["git", "-C", wt, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == existingTip)   // still at existing's own tip — base was ignored
    }

    @Test("ensure with an unknown base throws and leaves no worktree dir")
    func ensureUnknownBaseThrows() throws {
        let (repo, config) = try makeRepo()
        let wm = WorktreeManager(config: config)
        let wt = wm.path(repo: repo, branch: "child")
        #expect(throws: OrchestraError.self) {
            try wm.ensure(repo: repo, branch: "child", base: "nope")
        }
        #expect(!FileManager.default.fileExists(atPath: wt))   // no half-created worktree
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --filter WorktreeManagerTests`
Expected: FAIL — `ensure` has no `base:` parameter yet (compile error).

- [ ] **Step 3: Add `base` to the `WorktreeManaging` protocol + a convenience overload**

In `Sources/OrchestraCore/Protocols.swift`, replace the `ensure` requirement (currently line 11) with
the base-carrying form, and add a convenience extension so no-base callers (recovery) stay unchanged:

```swift
    /// `branchExisted` = the branch was already present (so the worktree checked it out rather than
    /// cutting a fresh `-b` branch). Lets callers skip work that only applies to pre-existing branches
    /// (e.g. deriving lineage from git config) without a second git query. `base` (BT2) is git's
    /// start-point for a NEWLY-created branch (`git worktree add -b <branch> <wt> <base>`); it is
    /// **ignored** when the branch already exists. nil ⇒ today's HEAD behavior.
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool)
```

Then, immediately after the `WorktreeManaging` protocol's closing brace (before the `SessionManaging`
protocol), add:

```swift
public extension WorktreeManaging {
    /// Convenience for callers that never branch-from-a-base (recovery/rebuild): defaults `base` to nil.
    @discardableResult
    func ensure(repo: String, branch: String) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        try ensure(repo: repo, branch: branch, base: nil)
    }
}
```

- [ ] **Step 4: Implement the start-point in `WorktreeManager.ensure`**

In `Sources/OrchestraCore/WorktreeManager.swift`, change the `ensure` signature and the new-branch arm.
Replace lines 20-49 (the whole `ensure` method) with:

```swift
    /// Ensure a worktree exists for repo + branch. Idempotent. Returns (worktree, created, branchExisted).
    /// `base` (BT2) is the start-point for a NEWLY-created branch only — an existing branch ignores it.
    /// An unknown `base` throws `.invalidParams` *before* any worktree is cut (no half-created dir).
    @discardableResult
    public func ensure(repo: String, branch: String, base: String? = nil)
        throws -> (worktree: String, created: Bool, branchExisted: Bool) {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = path(repo: realRepo, branch: branch)
        try resolver.assertAllowed(wt)

        if FileManager.default.fileExists(atPath: wt) {
            return (wt, false, true)   // a live worktree implies the branch already exists
        }
        try FileManager.default.createDirectory(
            atPath: (wt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Does the branch already exist?
        let exists = branchExists(repo: realRepo, branch: branch)
        let argv: [String]
        if exists {
            argv = ["git", "-C", realRepo, "worktree", "add", wt, branch]   // existing branch ignores `base`
        } else {
            var a = ["git", "-C", realRepo, "worktree", "add", "-b", branch, wt]
            if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                // Validate the start-point BEFORE `worktree add`, so an unknown base leaves no dir.
                guard branchExists(repo: realRepo, branch: base) else {
                    throw OrchestraError.invalidParams("base branch not found: \(base)")
                }
                a.append(base)
            }
            argv = a
        }
        let r = try Proc.run(argv)
        if !r.ok {
            let msg = r.stderr.lowercased()
            if msg.contains("already checked out") || msg.contains("is already used by worktree") {
                throw OrchestraError.branchInUse(branch)
            }
            throw OrchestraError.io(r.stderr.isEmpty ? "git worktree add failed" : r.stderr)
        }
        return (wt, true, exists)
    }
```

- [ ] **Step 5: Update the `StubWorktrees` stub to the new signature**

In `Tests/OrchestraCoreTests/Stubs.swift`, replace the `ensure` method (lines 22-27) with the
base-carrying signature. The stub never touches git, so `base` is recorded for assertions but doesn't
change the fake worktree:

```swift
    private(set) var ensuredBases: [String: String?] = [:]   // branch -> base ensure() saw
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        lock.lock()
        ensured.append("\(repo)#\(branch)")
        ensuredBases[branch] = base
        let existed = existingBranches.contains(branch)
        lock.unlock()
        let wt = path(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return (wt, true, existed)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter WorktreeManagerTests`
Expected: PASS (existing cases + the 3 new base cases).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Protocols.swift Sources/OrchestraCore/WorktreeManager.swift \
        Tests/OrchestraCoreTests/Stubs.swift Tests/IntegrationTests/WorktreeManagerTests.swift
git commit -m "feat(bt2): WorktreeManager.ensure(base:) — start-point on the new-branch arm"
```

---

## Task 2: Thread `base` through spawn — catalog / registry / service + lineage recording

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (add `recordSpawnBase` + `revParseOID`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift:246-255` (spawn worktree arm)
- Modify: `Sources/OrchestraKit/CommandCatalog.swift:37-52` (`spawn` `"base"` param) and `:191-195`
  (`batch-spawn` summary note)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift:37-50` (`spawn`) and `:254-268` (`batch-spawn`)
- Test: `Tests/OrchestraCoreTests/SpawnBaseTests.swift` (new)

**Interfaces:**
- Consumes: `BranchLineage.set` / `.read`, `ParentLink`, `Proc.run`, `OrchestraService.lineage`.
- Produces:
  - `OrchestraService.recordSpawnBase(repo: String, branch: String, base: String) async throws -> String`
    — writes `ParentLink(parent: base, base: <base tip OID>)` and returns the canonical parent (`base`,
    the local branch name in BT2). Throws `.invalidParams` if the base can't be resolved.
  - `OrchestraService.spawn` records lineage when a **new** branch is cut with a non-empty `base`, and
    sets `Task.parentBranch` to the canonical parent.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/SpawnBaseTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn with base — lineage recorded at branch creation (local parents)")
struct SpawnBaseTests {

    /// A real git repo under reposRoot with `main` + a base commit + a `parent` branch. StubWorktrees
    /// still cuts the fake worktree; the base tip + lineage config resolve against this real repo.
    static func repoWithParent(_ base: String) throws -> String {
        let p = TestEnv.repo(base)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try "base\n".write(toFile: p + "/a.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "base")
        try git("branch", "parent")
        return p
    }

    @Test("spawn(base:) records lineage and sets parentBranch to the base")
    func spawnWithBaseRecordsLineage() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "parent")

        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        // Recorded base OID = the parent branch's tip at creation.
        let parentTip = try Proc.run(["git", "-C", repo, "rev-parse", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(link.base == parentTip)
    }

    @Test("spawn(base:) passes the base into WorktreeManager.ensure")
    func spawnThreadsBaseToEnsure() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        _ = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(env.worktrees.ensuredBases["child"] == "parent")
    }

    @Test("spawning onto a PRE-EXISTING branch ignores base and keeps churn derivation")
    func existingBranchIgnoresBase() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        // The branch pre-exists with its OWN durable lineage (parent = other), as after a prior card.
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "other", base: "deadbeef"))
        env.worktrees.markBranchExists("child")
        // Even though we pass base = parent, the existing branch must derive parent from config (= other).
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "other")
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "other")   // not overwritten by base
    }

    @Test("no base → no lineage, parentBranch nil (today's behavior)")
    func noBaseNoLineage() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
        #expect(await BranchLineage().read(repo: repo, branch: "solo") == nil)
    }

    @Test("spawn threads base through the registry handler")
    func spawnBaseViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("spawn"))
        let out = try await cmd.run(env.svc,
            .object(["prompt": .string("x"), "repo": .string(repo),
                     "branch": .string("child"), "base": .string("parent")]), .mcp)
        #expect(try out.decode(Task.self).parentBranch == "parent")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SpawnBaseTests`
Expected: FAIL — `spawn` doesn't thread `base` yet (`parentBranch == nil`), and the registry `spawn`
handler drops `base`.

- [ ] **Step 3: Add `recordSpawnBase` + `revParseOID` to `OrchestraService+Tree.swift`**

In `Sources/OrchestraCore/OrchestraService+Tree.swift`, add inside the existing
`extension OrchestraService { … }` (e.g. after `setParent`, before the `private func mergeBaseOID`):

```swift
    /// BT2 spawn-with-base (local parents): record lineage for a card whose branch was just CREATED on
    /// top of `base`. The recorded base OID is `base`'s tip at creation — the redirect anchor for later
    /// restack/sync. Returns the canonical parent ref stored on `Task.parentBranch` (the local base name
    /// in BT2; BT6 will canonicalize remote forms). Throws `.invalidParams` if `base` can't be resolved
    /// (defense-in-depth — `WorktreeManager.ensure` already validated it before cutting the worktree).
    func recordSpawnBase(repo: String, branch: String, base: String) async throws -> String {
        let oid = try revParseOID(repo: repo, ref: base)
        try await lineage.set(repo: repo, branch: branch, link: ParentLink(parent: base, base: oid))
        return base
    }

    /// `git rev-parse --verify <ref>` in `repo`, or `.invalidParams` if it doesn't resolve.
    private func revParseOID(repo: String, ref: String) throws -> String {
        let r = try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref])
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !oid.isEmpty else {
            throw OrchestraError.invalidParams("base branch not found: \(ref)")
        }
        return oid
    }
```

- [ ] **Step 4: Thread `base` into `OrchestraService.spawn`'s worktree arm**

In `Sources/OrchestraCore/OrchestraService.swift`, in the worktree `else` arm (lines 243-256):

First, pass `base` to `ensure` — change line 246 from:

```swift
            let ensured = try worktrees.ensure(repo: realRepo, branch: input.branch)
```

to:

```swift
            let ensured = try worktrees.ensure(repo: realRepo, branch: input.branch, base: input.base)
```

Then extend the churn-derivation block (currently lines 253-255) to also record lineage for a
newly-created branch cut with a base. Replace:

```swift
            if ensured.branchExisted {
                derivedParentBranch = await lineage.read(repo: realRepo, branch: input.branch)?.parent
            }
```

with:

```swift
            if ensured.branchExisted {
                // Churn derivation (existing branch): re-derive the parentBranch cache from durable
                // lineage config; `base` is deliberately ignored for a pre-existing branch (L2 contract).
                derivedParentBranch = await lineage.read(repo: realRepo, branch: input.branch)?.parent
            } else if let base = input.base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                // Spawn-with-base (BT2): the branch was just CREATED on `base` — record the parent link
                // (parent = base, recorded base OID = base tip) so the card is parent-aware from spawn.
                derivedParentBranch = try await recordSpawnBase(repo: realRepo, branch: input.branch, base: base)
            }
```

(`Task.parentBranch` is already fed `derivedParentBranch` at the `Task(...)` init, line 303 — no change
there.)

- [ ] **Step 5: Add the `base` catalog param on `spawn` + a `batch-spawn` note**

In `Sources/OrchestraKit/CommandCatalog.swift`, inside the `spawn` schema's `params` (after the `seed`
entry at line 50-51, before the closing `], required: ["prompt"])`):

```swift
                          "base": strProp("Parent branch to create this card's branch ON TOP OF (an "
                              + "existing local branch). The new branch starts at the base's tip and its "
                              + "parent link is recorded. Ignored when the branch already exists. Omit for "
                              + "today's HEAD behavior."),
```

In the `batch-spawn` schema (line 192-194), update the `tasks` array `description` to mention `base`:

```swift
                          "description": .string("Array of spawn params {prompt, repo, branch, model?, col?, base?}"),
```

- [ ] **Step 6: Thread `base` in the registry `spawn` + `batch-spawn` handlers**

In `Sources/OrchestraCore/CommandRegistry.swift`, in the `spawn` handler (lines 38-47), add `base` to
the `SpawnInput(...)` — after `seed: p.optString("seed")` (line 47), change it to:

```swift
                    seed: p.optString("seed"),
                    base: p.optString("base"))
```

In the `batch-spawn` handler (lines 260-264), add `base` to the per-item `SpawnInput(...)` — after
`seed: item.optString("seed")`:

```swift
                        seed: item.optString("seed"),
                        base: item.optString("base")))
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter SpawnBaseTests` → PASS (6 tests).
Run: `swift test --filter LineageSpawnTests` → PASS (BT1 churn tests still green — the existing-branch
arm is unchanged behaviorally when no base is passed).
Run: `swift test --filter CommandsTests` and `swift test --filter CommandRegistryCatalogTests` → PASS
(no new commands added; `base` is just a param on `spawn`, so the pairing sets are unchanged).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraCore/OrchestraService.swift \
        Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift \
        Tests/OrchestraCoreTests/SpawnBaseTests.swift
git commit -m "feat(bt2): thread base through spawn/batch-spawn — record lineage at branch creation"
```

---

## Task 3: CLI `--base` flag + `BoardStore.spawn(base:)`

**Files:**
- Modify: `Sources/orchestra/CLIRunner.swift:41-45` (merge `--base` into the spawn params)
- Modify: `Sources/orchestra/CLIHelp.swift` (spawn `--base` help line)
- Modify: `Sources/OrchestraUI/BoardStore.swift:648-671` (`spawn` gains `base: String?`)

**Interfaces:**
- Consumes: `flags.value("base")` (CLI), the `spawn` catalog param (Task 2).
- Produces: `BoardStore.spawn(..., base: String? = nil)` forwarding the `base` field to the RPC.

- [ ] **Step 1: Add `--base` to the CLI spawn params**

In `Sources/orchestra/CLIRunner.swift`, the worktree `spawn` merges optional flags into `p` (lines
41-44). Add `base` to that chain — change:

```swift
                let p = JSONValue.object(fields
                    .merging(optional("model", flags.value("model"))) { a, _ in a }
                    .merging(optional("col", flags.value("col"))) { a, _ in a }
                    .merging(optional("seed", flags.value("seed"))) { a, _ in a })
```

to:

```swift
                let p = JSONValue.object(fields
                    .merging(optional("model", flags.value("model"))) { a, _ in a }
                    .merging(optional("col", flags.value("col"))) { a, _ in a }
                    .merging(optional("seed", flags.value("seed"))) { a, _ in a }
                    .merging(optional("base", flags.value("base"))) { a, _ in a })
```

(`base` is a no-op unless repo/branch mode is used and the branch is new — matching the service
contract. The daemon ignores it for scratch/freeform, so no CLI-side gating is needed.)

- [ ] **Step 2: Add the `--base` help line**

In `Sources/orchestra/CLIHelp.swift`, find the `spawn` help block and add a `--base` line alongside the
other spawn flags (match the surrounding indentation/format):

```
      --base <branch>       Create the card's branch on top of this existing local branch (records parent link)
```

- [ ] **Step 3: Add `base` to `BoardStore.spawn`**

In `Sources/OrchestraUI/BoardStore.swift`, change the `spawn` signature (line 648-650) to add a
trailing `base` param:

```swift
    @discardableResult
    public func spawn(prompt: String, repo: String, branch: String, model: String?, startIn: StartIn,
               agent: String? = nil,
               cwd: String? = nil, access: CardAccess = .readWrite, scratch: Bool = false,
               base: String? = nil) async -> Task? {
```

Then, in the body, after the `if scratch { p["scratch"] = .bool(true) }` line (line 660), add:

```swift
        // Spawn-with-base (BT2): create the worktree branch on top of an existing local branch.
        if let base, !base.isEmpty { p["base"] = .string(base) }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds clean (no test changes — this task is thin plumbing verified by the build and the
Task-4 sheets that call it).

- [ ] **Step 5: Commit**

```bash
git add Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift Sources/OrchestraUI/BoardStore.swift
git commit -m "feat(bt2): CLI --base flag + BoardStore.spawn(base:)"
```

---

## Task 4: Base picker in both spawn sheets (desktop + iOS)

> **No unit tests** — per `04-tests.md` the UI tier is store-logic units + a manual `orch-ui-shot.sh`
> pass. This task is build-verified; the manual screenshot pass happens at review.

**Files:**
- Modify: `App/Views/SpawnSheet.swift` (base state + picker + spawn call)
- Modify: `App-iOS/Views/SpawnSheet.swift` (base state + picker + spawn call)

**Interfaces:**
- Consumes: `BoardStore.spawn(base:)` (Task 3); the existing branch list source in each sheet
  (`branches` desktop, `branchSuggestions` iOS).
- Produces: a base picker in the worktree body of each sheet; default "none" (empty) = today's behavior.

### Desktop (`App/Views/SpawnSheet.swift`)

- [ ] **Step 1: Add `base` state**

After `@State private var branch = ""` (line 19), add:

```swift
    /// BT2: an existing local branch to create the new branch ON TOP OF (empty = none = today's HEAD
    /// behavior). Sourced from the same `branches` list as the branch combo. BT6 will extend the picker
    /// with remote/PR entries.
    @State private var base = ""
```

- [ ] **Step 2: Add the base picker to the worktree body**

The base picker only makes sense when creating a *new* branch (an existing branch ignores base). Show
it in the worktree layout under the Repository/Branch row. Change the `.worktree` case of the mode
`switch` (lines 180-184) to append a base field:

```swift
                case .worktree:
                    HStack(spacing: 11) {
                        field("Repository") { repoPicker }
                        field("Branch") { branchPicker }
                    }
                    // Base only applies when the branch is newly created; hide it for a branch that
                    // already exists (the daemon ignores base there anyway).
                    if !branches.contains(branch) {
                        field("Base branch (optional)") { basePicker }
                    }
```

- [ ] **Step 3: Add the `basePicker` view + its popover**

The desktop branch combo uses a bespoke popover. Reuse the same `ComboRow`/fuzzy pattern with a small,
self-contained menu picker (a `Menu` keeps it minimal — no new popover state to manage). Add near the
branch combo helpers (after `commitBranch`, ~line 616):

```swift
    // MARK: Base combo (BT2)

    /// A compact picker for the optional base branch: "None (branch from HEAD)" plus every existing
    /// local branch. Reuses `branches` (the same source as the branch combo). BT6 extends this with
    /// remote/PR entries — keep the "None" row first so the default stays today's behavior.
    private var basePicker: some View {
        Menu {
            Button("None (branch from HEAD)") { base = "" }
            if !branches.isEmpty { Divider() }
            ForEach(branches, id: \.self) { b in
                Button(b) { base = b }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11)).foregroundColor(theme.text2)
                Text(base.isEmpty ? "None (branch from HEAD)" : base)
                    .font(F.mono(12.5)).foregroundColor(base.isEmpty ? theme.text3 : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(theme.text2)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
```

- [ ] **Step 4: Pass `base` in the spawn call + reflect it in the CLI preview**

In the footer's Spawn button (the `.worktree` case, lines 284-286), pass `base`:

```swift
                        case .worktree:
                            await model.spawn(prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn,
                                              agent: a, base: base.isEmpty ? nil : base)
```

Then reflect it in `cliPreview` (the `.worktree` case, line 126-127) so the preview stays honest:

```swift
        case .worktree:
            let baseFlag = base.isEmpty ? "" : " --base \(base)"
            return "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\"\(agentFlag) --repo \(repo) --branch \(branch.isEmpty ? "…" : branch)\(baseFlag) --col \(startIn.column.rawValue)"
```

- [ ] **Step 5: Reset `base` when the repo changes (stale-branch guard)**

In `.onChange(of: repo)` (lines 330-333), the branch is already cleared when it's no longer valid. Add
the same guard for `base`:

```swift
        .onChange(of: repo) {
            branches = gitBranches(in: repo)
            if branch.isEmpty || !branches.contains(branch) { branch = "" }
            if !base.isEmpty && !branches.contains(base) { base = "" }
        }
```

### iOS (`App-iOS/Views/SpawnSheet.swift`)

- [ ] **Step 6: Add `base` state**

After `@State private var branch = ""` (line 33), add:

```swift
    /// BT2: an existing local branch to create the new branch ON TOP OF (empty = none). Sourced from the
    /// same `branchSuggestions` as the branch picker. BT6 will extend it with remote/PR entries.
    @State private var base = ""
```

- [ ] **Step 7: Add the base picker to the worktree body**

In `worktreeBody` (lines 257-277), after the Branch `SpawnPickerField` (lines 261-263) and before the
`LabeledContent("Worktree")`, add a base picker. Reuse `SpawnPickerField` but prepend a "None" option
by wrapping in a `LabeledContent`-free row — the simplest fit is a native `Picker` menu since the base
list is the known branch set (free-text isn't needed — a base must already exist):

```swift
        // Base only applies to a NEWLY-created branch; the daemon ignores it for an existing one.
        if !branchSuggestions.contains(branch) {
            Picker("Base branch", selection: $base) {
                Text("None (branch from HEAD)").tag("")
                ForEach(branchSuggestions, id: \.self) { Text($0).tag($0) }
            }
        }
```

- [ ] **Step 8: Pass `base` in the spawn call**

In `spawn()` (lines 442-444), the `.worktree` case, pass `base`:

```swift
            case .worktree:
                card = await model.spawn(prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn,
                                         agent: a, base: base.isEmpty ? nil : base)
```

- [ ] **Step 9: Reset `base` when the repo changes**

In `.onChange(of: repo)` (line 206), the branches reload. Add a `base` reset so a stale base can't
carry across repos. Change:

```swift
            .onChange(of: repo) { _Concurrency.Task { await loadBranches() } }
```

to:

```swift
            .onChange(of: repo) { base = ""; _Concurrency.Task { await loadBranches() } }
```

- [ ] **Step 10: Build both targets to verify they compile**

Run: `swift build` (compiles `OrchestraUI` + core). For the app targets, run the project's build script
(per memory `ios-app-build-and-dev-transport` / `orchestra-build-env`):

```bash
swift build && scripts/build-app.sh 2>&1 | tail -5
```

Expected: both build clean. (The iOS target builds via xcodegen/xcodebuild — the typecheck script is
sufficient here; a full sim run is part of the review screenshot pass.)

- [ ] **Step 11: Commit**

```bash
git add App/Views/SpawnSheet.swift App-iOS/Views/SpawnSheet.swift
git commit -m "feat(bt2): base picker in desktop + iOS spawn sheets (local branches)"
```

---

## Task 5: Full-suite gate

- [ ] **Step 1: Run the whole suite**

Run: `swift build && swift test`
Expected: PASS (all suites, including the real-git `IntegrationTests` when git is available).

- [ ] **Step 2: If anything regressed, fix before proceeding** (systematic-debugging skill).

---

## Self-Review

**Spec coverage (BT2 row of `03-implementation.md` §Sequencing + `04-tests.md`):**
- `WorktreeManager.ensure(base:)` — new branch starts at base tip (rev-parse equality), existing branch
  ignores base, unknown base throws + no worktree dir → Task 1 (`04-tests.md` "ensure(base:)" row). ✓
- `base` threading catalog/registry/`SpawnInput`/service/CLI/`BoardStore` → Tasks 2-3
  (`04-tests.md` "Spawn threading (§4)" / "Spawn param" rows). ✓
- Lineage recorded at spawn (keys written, `parentBranch` set) + existing-branch churn precedence →
  Task 2 `SpawnBaseTests` (`04-tests.md` integration "Spawn-with-base"). ✓
- `SpawnInput` decode back-compat — already covered by BT1's `LineageModelTests`; not re-tested here. ✓
- Both spawn sheets base picker (local branches; extension point noted for BT6) → Task 4
  (`04-tests.md` UI tier = manual shot pass). ✓

**Deliberately out of BT2 (documented, not gaps):** remote/PR bases + `RemoteParents.fetch` (BT6); diff
baseline switch (BT3); `TreeStat` recompute / `synced` / stale nudge (BT4); `shipped` / `set-parent
move` / TreeDocs (BT5). The picker's "None-first + local branches" shape leaves the extension point
BT6 needs (remote/PR rows appended).

**Placeholder scan:** none — every code step shows complete code; every test step shows assertions.

**Type consistency check:**
- `ensure(repo:branch:base:)` — one signature across the protocol requirement, the concrete
  `WorktreeManager`, the `StubWorktrees`, and every callsite (service passes `input.base`; recovery uses
  the `base:nil` convenience).
- `recordSpawnBase(repo:branch:base:) -> String` — Task 2 definition matches its single call in `spawn`.
- `ParentLink(parent:base:)` — same call shape as BT1 (`prNumber`/`watch` default).
- `BoardStore.spawn(..., base: String? = nil)` — Task 3 signature matches both sheets' calls (Task 4).
- `SpawnInput(..., base:)` — memberwise init already carries `base` (BT1, Model.swift:728-736); the
  registry/batch handlers and tests all use the labeled `base:` argument.

**Uncertainties to verify during execution (don't block; adjust to the real code):**
1. `CLIHelp.swift` spawn block format — match the surrounding flag lines' exact indentation.
2. The desktop `Menu`-based `basePicker` styling (`.menuStyle(.borderlessButton)`) — if it clashes with
   the sheet chrome, fall back to the same bespoke popover pattern the branch combo uses. Either is fine;
   the behavior (None-first + local branches) is what matters.
3. `Proc.checked` availability in `IntegrationTests` (used by the existing `WorktreeManagerTests`) — it
   is already used throughout that file, so Task 1's new tests can rely on it.
```
