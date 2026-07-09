# BT5 — Branch-Tree Ship Choreography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the post-merge ship choreography for the branch tree — a `shipped` bookkeeping RPC (notify parent + retarget grandchildren), `set-parent mode:"move"` (repoint + restack nudge), and `TreeDocs` agent guidance for both Claude and Codex — on top of merged BT1–BT4.

**Architecture:** Extend `OrchestraService+Tree.swift` with two service methods (`shipped`, and the lifted `move` arm of `setParent`), wire `shipped` through the catalog/registry/CLI trio, and add a `TreeDocs` resource pair mirroring `DelegationDocs`. The one structural change is generalizing the Codex `AGENTS.md` installer into an idempotent **named-section composer** so delegation + tree docs coexist in the single file Codex reads.

**Tech Stack:** Swift 6 (SwiftPM), swift-testing (`#expect`/`@Test`) + XCTest for the pairing test, real `git` fixtures via `Proc`, `Bundle.module` `.copy` resources.

## Global Constraints

- **Never touch `main` or `plan/parent-card-branch-linking`.** This branch merges into `plan/parent-card-branch-linking`; the orchestrator merges. Do not merge anything.
- **Design for BOTH Claude and Codex** — no `if agent == "claude"` branches in shared code; content is keyed via `forAgent(id)`.
- **Keep catalog/registry edits additive** (BT7 runs in parallel; no collisions expected — BT7 only touches `OrchestraUI`/`App`/`App-iOS`).
- **The daemon never rewrites branches.** Rebase/merge is ALWAYS agent-performed in the agent's own worktree; the daemon only writes git-config lineage + enqueues nudges.
- **Idempotency is a hard requirement** for `shipped` (re-run must not double-notify or double-nudge).
- Scratch work in `./.scratch/`. `swift test` must pass cleanly at the end.
- Git idiom in this repo is `["git", "-C", repo, …]` via `Proc.run` (note: the global rule against `git -C` is about the *Bash allowlist*; in-code `Proc` calls use `-C` per house style — follow the surrounding code).

---

## File Structure

**Create:**
- `Sources/OrchestraCore/Agents/TreeDocs.swift` — `TreeDocs` loader/installer (mirror of `DelegationDocs`) + `AgentsFileComposer` (idempotent named-section upsert for the shared Codex `AGENTS.md`).
- `Sources/OrchestraCore/Resources/tree-skill.md` — Claude variant (frontmatter + body).
- `Sources/OrchestraCore/Resources/tree-agents.md` — Codex variant (plain markdown).
- `Tests/OrchestraCoreTests/TreeDocsTests.swift`
- `Tests/OrchestraCoreTests/ShipChoreoTests.swift`
- `Tests/OrchestraCoreTests/SetParentMoveTests.swift`
- `Tests/OrchestraCoreTests/RedirectMechanicsTests.swift`

**Modify:**
- `Sources/OrchestraCore/OrchestraService+Tree.swift` — add `shipped(ref:source:)`; lift the adopt-only guard in `setParent` to add the `move` arm.
- `Sources/OrchestraKit/CommandCatalog.swift` — add `shipped` schema; refresh `set-parent` summary/params to describe `mode:"move"`.
- `Sources/OrchestraCore/CommandRegistry.swift` — add `shipped` handler.
- `Sources/orchestra/CLIRunner.swift` — add `shipped` case.
- `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` — install the tree skill from `prepareToLaunch`.
- `Sources/OrchestraCore/Agents/CodexAdapter.swift` — replace the wholesale `AGENTS.md` overwrite with composed `delegation` + `tree` sections.
- `Package.swift` — `.copy` the two new resources.
- `.claude/commands/ship.md` — add the tree-aware branch, keeping the existing main flow intact.
- `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` — add `"shipped"` to the canonical command set.
- `Tests/OrchestraCoreTests/CodexAdapterTests.swift` — update the `AGENTS.md` materialization assertions to the new sectioned reality.

---

## Task 1: `AgentsFileComposer` + `TreeDocs` loader (sectioned Codex file, isolated first commit)

The one refactor with blast radius. `TreeDocs` mirrors `DelegationDocs` exactly (loader + `forAgent` + Claude `install`). `AgentsFileComposer` is the new idempotent named-section upsert that lets delegation + tree share the one `AGENTS.md` Codex reads. This task builds and tests the mechanism in isolation; Task 2 wires it into the adapters.

**Files:**
- Create: `Sources/OrchestraCore/Agents/TreeDocs.swift`
- Create: `Sources/OrchestraCore/Resources/tree-skill.md`
- Create: `Sources/OrchestraCore/Resources/tree-agents.md`
- Modify: `Package.swift` (add two `.copy` lines)
- Test: `Tests/OrchestraCoreTests/TreeDocsTests.swift`

**Interfaces:**
- Produces:
  - `enum TreeDocs { enum Variant: String { case claudeSkill = "tree-skill"; case codexAgents = "tree-agents" }; static func load(_:) -> String?; static func forAgent(_ agentId: String) -> String?; @discardableResult static func install(agentId: String, at path: String) -> Bool }`
  - `enum AgentsFileComposer { @discardableResult static func upsert(section name: String, content: String, at path: String) -> Bool; static func startMarker(_:) -> String; static func endMarker(_:) -> String }`
- Consumes: `Bundle.module` (from `DelegationDocs`'s precedent), `FileManager`.

- [ ] **Step 1: Create the two resource files**

`Sources/OrchestraCore/Resources/tree-skill.md` (Claude — frontmatter + body):

```markdown
---
name: orchestra-tree
description: Use when your card's branch was spawned on top of another branch (it has a tree parent) — for keeping in sync with the parent, restacking after the parent moves or ships, and shipping your branch up the tree instead of straight to main.
---

# Working in a branch tree

Your branch may have a **parent branch** (you were spawned on top of it, or `set-parent` linked one). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Three operations keep the tree healthy. Resolve your position first with `orchestra tree` (or `orchestra tree <you>`): it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

## Sync — pull the parent's new work down

When `orchestra tree` shows you `stale` / behind N, the parent advanced. Merge it down, then report:

1. Commit or stash-free: make sure your tree is clean (commit WIP first).
2. `git merge <parent>` (a normal merge — you are pulling the parent INTO you).
3. Resolve any conflicts, commit the merge.
4. `orchestra synced <you>` — records the parent's current tip as your new base and clears the stale signal.

## Restack — the parent moved out from under you

When `treeStat` is `restackNeeded` (the parent was rebased, re-parented via `set-parent move`, or **shipped** so your link was retargeted onto its grandparent), replay only YOUR commits onto the new parent:

1. **Commit your WIP first** — a restack rewrites history and refuses to run on a dirty tree. **Never autostash.**
2. `git rebase --onto <new-parent> <recorded-base>` — `<recorded-base>` is the OID Orchestra kept as your rebase anchor (in the nudge, and in `orchestra tree`). Using `--onto` with the recorded base transplants ONLY your own commits, so work already in the new parent (e.g. a squash-merged parent) is not re-applied and you avoid phantom conflicts.
3. If it conflicts, resolve and `git rebase --continue`; if it goes wrong, `git rebase --abort` and report — never leave the branch half-restacked.
4. `orchestra synced <you>`.

## Ship — merge your branch up the tree

Do NOT blindly ship to main. Resolve the parent via `orchestra tree` and take the matching path:

- **Parent has a live card** → you cannot advance a branch checked out in another worktree, and the owning agent must merge it. `orchestra send <parent-ref> "merge-request: squash-merge <you> into <parent>"` and **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <you>`. Do not `cd` into the parent's worktree.
- **Bare local parent (no card owns it)** → borrow it ephemerally: check the parent branch out in a throwaway worktree, `git merge --squash <you>`, commit, remove the worktree, then `orchestra shipped <you>`.
- **Parent is `main`** → today's `/ship` flow is unchanged (commit → merge to main → relaunch → archive). Do not call `orchestra shipped`.
- **Remote parent (`origin/…` / a PR)** → out of scope for now (BT6). Do not attempt a local merge.

After `orchestra shipped <you>` runs, the daemon notifies the parent card and retargets any children of yours onto the grandparent — you then archive as usual.
```

`Sources/OrchestraCore/Resources/tree-agents.md` (Codex — plain markdown, no frontmatter, starts with `# `):

```markdown
# Working in a branch tree

Your branch may have a **parent branch** (spawned on top of it, or linked via `set-parent`). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Resolve your position with `orchestra tree` (or `orchestra tree <you>`) before acting: it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

## Sync — pull the parent's new work down

When `orchestra tree` shows you `stale` / behind N:

1. Commit WIP so your tree is clean.
2. `git merge <parent>` (merge the parent INTO you).
3. Resolve conflicts, commit the merge.
4. `orchestra synced <you>`.

## Restack — the parent moved out from under you

When `treeStat` is `restackNeeded` (parent rebased, re-parented via `set-parent move`, or **shipped** so your link was retargeted onto its grandparent):

1. **Commit your WIP first.** A restack rewrites history and refuses a dirty tree. **Never autostash.**
2. `git rebase --onto <new-parent> <recorded-base>` — `<recorded-base>` is the OID Orchestra kept as your rebase anchor (in the nudge, and in `orchestra tree`). `--onto` with the recorded base transplants ONLY your own commits, so work already in the new parent (a squash-merged parent) is not re-applied — no phantom conflicts.
3. On conflict resolve + `git rebase --continue`; if it goes wrong `git rebase --abort` and report.
4. `orchestra synced <you>`.

## Ship — merge your branch up the tree

Resolve the parent via `orchestra tree` and take the matching path:

- **Parent has a live card** → you cannot advance a branch checked out in another worktree. `orchestra send <parent-ref> "merge-request: squash-merge <you> into <parent>"` and **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <you>`.
- **Bare local parent (no card)** → borrow it ephemerally: check the parent out in a throwaway worktree, `git merge --squash <you>`, commit, remove the worktree, then `orchestra shipped <you>`.
- **Parent is `main`** → today's ship flow is unchanged; do not call `orchestra shipped`.
- **Remote parent (`origin/…` / a PR)** → out of scope for now (BT6).

After `orchestra shipped <you>` runs, the daemon notifies the parent card and retargets any children of yours onto the grandparent — you then archive as usual.
```

- [ ] **Step 2: Register both resources in `Package.swift`**

In the `OrchestraCore` target's `resources:` array (after the `delegation-*` lines at `Package.swift:65-66`):

```swift
                .copy("Resources/delegation-skill.md"),
                .copy("Resources/delegation-agents.md"),
                .copy("Resources/tree-skill.md"),
                .copy("Resources/tree-agents.md"),
```

- [ ] **Step 3: Write `TreeDocs.swift`**

`Sources/OrchestraCore/Agents/TreeDocs.swift`:

```swift
import Foundation

/// Branch-tree agent guidance (sync / restack / tree-aware ship), vendored per-agent and `.copy`-bundled
/// into `Bundle.module` — the `DelegationDocs` pattern verbatim. Claude reads it as a project skill
/// (`.claude/skills/orchestra-tree/SKILL.md`); Codex reads it as a NAMED SECTION of its single
/// `CODEX_HOME/AGENTS.md`, composed alongside the delegation section by `AgentsFileComposer`. Content is
/// keyed via `forAgent(_:)` — no per-agent branch in the adapters.
public enum TreeDocs {
    public enum Variant: String {
        case claudeSkill = "tree-skill"    // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "tree-agents"   // plain AGENTS.md section body (Codex)
    }

    /// Read a variant's markdown; nil if absent/unreadable (callers degrade — never throws into launch).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Codex reads AGENTS.md; every other agent (Claude, future) gets the skill. Same substance both ways.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }

    /// Materialize the Claude skill variant to `path` (its own `orchestra-tree` skill dir — a SEPARATE
    /// file from the delegation skill, so no composition is needed on the Claude side). Best-effort;
    /// idempotent atomic overwrite. Mirrors `DelegationDocs.install`. Codex does NOT use this — its shared
    /// `AGENTS.md` is composed via `AgentsFileComposer` (see `CodexAdapter.prepareToLaunch`).
    @discardableResult
    public static func install(agentId: String, at path: String) -> Bool {
        guard let text = forAgent(agentId) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}

/// Composes a Codex `AGENTS.md` from named sections behind idempotent HTML-comment markers, so multiple
/// Orchestra-owned docs (delegation + tree) share the one file Codex reads per scope without clobbering
/// each other. Each section is delimited by
///   `<!-- orchestra:section:<name>:start -->` … `<!-- orchestra:section:<name>:end -->`.
/// `upsert` replaces an existing same-named block IN PLACE (rewrite-idempotent) or appends a new one,
/// leaving every other section untouched. Best-effort — never throws into a launch path.
public enum AgentsFileComposer {
    public static func startMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):start -->" }
    public static func endMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):end -->" }

    @discardableResult
    public static func upsert(section name: String, content: String, at path: String) -> Bool {
        let start = startMarker(name), end = endMarker(name)
        let block = "\(start)\n\(content)\n\(end)"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if let existing = sectionRange(name, in: text) {
            text.replaceSubrange(existing, with: block)
        } else {
            if !text.isEmpty {
                if !text.hasSuffix("\n") { text += "\n" }
                text += "\n"
            }
            text += block + "\n"
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    /// The full span of a named block (inclusive of both markers), or nil if not present / malformed.
    private static func sectionRange(_ name: String, in text: String) -> Range<String.Index>? {
        guard let s = text.range(of: startMarker(name)),
              let e = text.range(of: endMarker(name)),
              s.lowerBound < e.upperBound else { return nil }
        return s.lowerBound..<e.upperBound
    }
}
```

- [ ] **Step 4: Write the failing tests**

`Tests/OrchestraCoreTests/TreeDocsTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Tree docs — vendored skill + sectioned AGENTS.md composer")
struct TreeDocsTests {

    // MARK: loader parity with DelegationDocs

    @Test("both variants load non-empty from the bundle (offline)")
    func bothLoad() throws {
        let skill = try #require(TreeDocs.load(.claudeSkill))
        let agents = try #require(TreeDocs.load(.codexAgents))
        #expect(!skill.isEmpty)
        #expect(!agents.isEmpty)
        let skillURL = try #require(Bundle.module.url(forResource: "tree-skill", withExtension: "md"))
        #expect(skillURL.isFileURL)
    }

    @Test("forAgent maps codex → AGENTS variant, everything else → the skill")
    func perAgentSelection() throws {
        #expect(TreeDocs.forAgent("codex") == TreeDocs.load(.codexAgents))
        #expect(TreeDocs.forAgent("claude-code") == TreeDocs.load(.claudeSkill))
        #expect(TreeDocs.forAgent("some-future-agent") == TreeDocs.load(.claudeSkill))
    }

    @Test("Claude skill has orchestra-tree frontmatter; Codex variant is plain markdown")
    func wellFormed() throws {
        let skill = try #require(TreeDocs.load(.claudeSkill))
        #expect(skill.hasPrefix("---\n"))
        #expect(skill.contains("name: orchestra-tree"))
        #expect(skill.contains("description:"))
        let agents = try #require(TreeDocs.load(.codexAgents))
        #expect(!agents.hasPrefix("---\n"))
        #expect(agents.hasPrefix("# "))
    }

    @Test("both variants cover sync / restack / tree-aware ship anchors")
    func requiredAnchors() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            for anchor in ["orchestra synced", "orchestra shipped", "orchestra tree",
                           "rebase --onto", "merge-request", "squash", "restack"] {
                #expect(doc.contains(anchor), "missing anchor: \(anchor)")
            }
            #expect(doc.lowercased().contains("never autostash") || doc.lowercased().contains("never leave"))
        }
    }

    // MARK: Claude install — its own skill dir

    @Test("Claude install writes the skill under .claude/skills/orchestra-tree/, creating parents")
    func claudeInstall() throws {
        let base = NSTemporaryDirectory() + "tree-install-\(UUID().uuidString)"
        let path = "\(base)/.claude/skills/orchestra-tree/SKILL.md"
        #expect(TreeDocs.install(agentId: "claude-code", at: path) == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == TreeDocs.load(.claudeSkill))
        #expect(TreeDocs.install(agentId: "claude-code", at: path) == true)   // idempotent
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: Codex sectioned AGENTS.md — delegation + tree coexist across reinstall

    @Test("composer keeps BOTH delegation and tree sections across a reinstall (idempotent)")
    func sectionedIdempotence() throws {
        let base = NSTemporaryDirectory() + "agents-compose-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        let deleg = try #require(DelegationDocs.forAgent("codex"))
        let tree = try #require(TreeDocs.forAgent("codex"))

        for _ in 0..<2 {   // install twice — must not duplicate
            #expect(AgentsFileComposer.upsert(section: "delegation", content: deleg, at: path) == true)
            #expect(AgentsFileComposer.upsert(section: "tree", content: tree, at: path) == true)
        }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        // exactly one of each marker pair
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("tree")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.endMarker("tree")).count == 2)
        // both bodies present
        #expect(text.contains(deleg))
        #expect(text.contains(tree))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("upsert replaces a section's body in place without touching its neighbor")
    func upsertReplacesInPlace() throws {
        let base = NSTemporaryDirectory() + "agents-replace-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        AgentsFileComposer.upsert(section: "delegation", content: "OLD-DELEG", at: path)
        AgentsFileComposer.upsert(section: "tree", content: "TREE-BODY", at: path)
        AgentsFileComposer.upsert(section: "delegation", content: "NEW-DELEG", at: path)  // replace
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("NEW-DELEG"))
        #expect(!text.contains("OLD-DELEG"))
        #expect(text.contains("TREE-BODY"))   // neighbor untouched
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        try? FileManager.default.removeItem(atPath: base)
    }
}
```

- [ ] **Step 5: Run tests — expect FAIL then PASS**

Run: `swift test --filter TreeDocsTests`
Expected first: compile error (`TreeDocs`/`AgentsFileComposer` undefined) → after Steps 1–3 exist, PASS. If a resource anchor `#expect` fails, adjust the resource prose (not the test) to contain the exact anchor strings.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/TreeDocs.swift Sources/OrchestraCore/Resources/tree-skill.md Sources/OrchestraCore/Resources/tree-agents.md Package.swift Tests/OrchestraCoreTests/TreeDocsTests.swift
git commit -m "feat(bt5): TreeDocs resources + AgentsFileComposer (sectioned Codex AGENTS.md)"
```

---

## Task 2: Install TreeDocs from both adapters (Claude skill + composed Codex sections)

Wire Task 1's mechanism into the launch paths. `prepareToLaunch` is called from spawn (`OrchestraService.swift:336`) and both recovery paths (`OrchestraService+Recovery.swift:84,172`), so installing here covers "spawn + recovery" automatically — no extra call sites.

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift:153` (add tree install after delegation install)
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift:214` (replace overwrite with composed sections)
- Modify: `Tests/OrchestraCoreTests/CodexAdapterTests.swift` (update the AGENTS.md materialization suite)

**Interfaces:**
- Consumes: `TreeDocs.install`, `TreeDocs.forAgent`, `DelegationDocs.forAgent`, `AgentsFileComposer.upsert` (Task 1).

- [ ] **Step 1: Add the tree skill install to `ClaudeCodeAdapter.prepareToLaunch`**

After the existing delegation install (`ClaudeCodeAdapter.swift:153`), append:

```swift
        DelegationDocs.install(agentId: id, at: "\(ctx.cwd)/.claude/skills/orchestra-delegation/SKILL.md")
        // Branch-tree guidance (sync / restack / tree-aware ship) as a SECOND, independent project skill —
        // its own dir, so it composes with (never clobbers) the delegation skill. Best-effort, keyed via
        // forAgent(id) — no `if claude` here. Installed on every spawn + recovery (this runs from both).
        TreeDocs.install(agentId: id, at: "\(ctx.cwd)/.claude/skills/orchestra-tree/SKILL.md")
```

- [ ] **Step 2: Replace the Codex `AGENTS.md` overwrite with composed sections**

In `CodexAdapter.prepareToLaunch` (`CodexAdapter.swift:214`), replace the single line:

```swift
        DelegationDocs.install(agentId: id, at: "\(codexHome)/AGENTS.md")
```

with:

```swift
        // Codex reads ONE AGENTS.md per scope, so delegation and tree guidance must COMPOSE into it, not
        // overwrite each other. Upsert each as a named, marker-delimited section (rewrite-idempotent):
        // a relaunch/recovery refreshes both in place without duplication. Best-effort; content keyed via
        // forAgent(id), so no `if codex` here.
        let agentsPath = "\(codexHome)/AGENTS.md"
        if let deleg = DelegationDocs.forAgent(id) {
            AgentsFileComposer.upsert(section: "delegation", content: deleg, at: agentsPath)
        }
        if let tree = TreeDocs.forAgent(id) {
            AgentsFileComposer.upsert(section: "tree", content: tree, at: agentsPath)
        }
```

- [ ] **Step 3: Update `CodexAdapterTests` AGENTS.md assertions (they encode the old wholesale-overwrite behavior)**

Open `Tests/OrchestraCoreTests/CodexAdapterTests.swift`. In the "CodexAdapter — delegation AGENTS.md materialization" suite (~line 411), the write-out test (~418) asserts a plain non-frontmatter file — keep that, but the idempotence test (~441-443) asserts `== DelegationDocs.load(.codexAgents)` (byte-for-byte wholesale). Replace that byte-for-byte assertion with the sectioned reality. Change the body of the idempotent test to:

```swift
        try adapter.prepareToLaunch(ctx)
        try adapter.prepareToLaunch(ctx)   // second apply must not duplicate either section
        let text = try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8)
        // both Orchestra-owned sections present, exactly once each, across the reinstall
        #expect(text.contains(try #require(DelegationDocs.forAgent("codex"))))
        #expect(text.contains(try #require(TreeDocs.forAgent("codex"))))
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("tree")).count == 2)
        // the trust write (config.toml) is unaffected by the AGENTS.md materialization
```

Also, in the write-out test (~418-424) that asserts `!text.hasPrefix("---\n")`, keep it (the composed file starts with the delegation start-marker comment, not frontmatter). If that test additionally asserts the file EQUALS the delegation variant, relax it to `#expect(text.contains(try #require(DelegationDocs.forAgent("codex"))))`.

- [ ] **Step 4: Run the adapter tests — expect PASS**

Run: `swift test --filter CodexAdapterTests` then `swift test --filter DelegationDocsTests`
Expected: both PASS. `DelegationDocsTests` is untouched by design (it exercises `DelegationDocs.install` directly, which still writes its raw variant) — confirm it stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "feat(bt5): install TreeDocs from both adapters; compose Codex AGENTS.md sections"
```

---

## Task 3: `shipped` RPC — notify parent + retarget grandchildren (idempotent)

The post-merge bookkeeping method plus its catalog/registry/CLI trio. `shipped(<child>)`: (a) notify the child's parent card; (b) retarget the child's OWN children onto the grandparent (keeping each child's recorded base), mark them `restackNeeded`, and nudge; (c) clear the shipped child's own lineage so a re-run is a pure no-op (the idempotency key).

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (add `shipped`)
- Modify: `Sources/OrchestraKit/CommandCatalog.swift` (add `shipped` schema)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift` (add `shipped` handler)
- Modify: `Sources/orchestra/CLIRunner.swift` (add `shipped` case)
- Modify: `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` (add `"shipped"`)
- Test: `Tests/OrchestraCoreTests/ShipChoreoTests.swift`

**Interfaces:**
- Produces: `@discardableResult public func shipped(ref: String, source: ActivitySource = .daemon) async throws -> Task` on `OrchestraService`. Returns the (now unlinked) shipped child Task.
- Consumes: `lineage.read/set/clear/children` (`BranchLineage`), `store.get/all/update`, `inbox.enqueue`, `wake`, `emit(.taskUpserted)`, `emitActivity`, `resolveRef` — all existing.

- [ ] **Step 1: Add `"shipped"` to the catalog and refresh `set-parent`**

In `Sources/OrchestraKit/CommandCatalog.swift`, add after the `synced` schema (~line 132):

```swift
        CommandSchema(name: "shipped",
                      summary: "Post-merge bookkeeping after a child branch was merged into its parent: "
                          + "notify the parent's card and retarget the child's own children onto the "
                          + "grandparent (keeping each one's recorded base) with a restack nudge. Idempotent.",
                      params: schema(["ref": refProp()], required: ["ref"])),
```

And update the `set-parent` schema (~line 112-119) `mode` param doc + summary to include `move` (used in Task 4, but land the schema copy here so the pairing test stays coherent as one change):

```swift
        CommandSchema(name: "set-parent",
                      summary: "Set or clear a card branch's parent link. With `parent`: 'adopt' (default) "
                          + "records parent + merge-base (history untouched); 'move' repoints and keeps the "
                          + "recorded base as the rebase anchor, marking restack-needed. Omit `parent` to clear.",
                      params: schema([
                          "ref": refProp(),
                          "parent": strProp("Parent branch ref (local name). Omit to clear the link."),
                          "mode": strProp("'adopt' (default): metadata-only relink, base = merge-base. "
                              + "'move': repoint + keep recorded base; marks restack-needed and nudges the "
                              + "owner to `git rebase --onto <new-parent> <recorded-base>`."),
                      ], required: ["ref"])),
```

- [ ] **Step 2: Add `"shipped"` to the registry**

In `Sources/OrchestraCore/CommandRegistry.swift`, after the `"synced"` handler (~line 157):

```swift
            "shipped": { svc, p, src in
                let updated = try await svc.shipped(ref: try p.string("ref"), source: src)
                return try JSONValue(encodable: updated)
            },
```

- [ ] **Step 3: Add `"shipped"` to the canonical command set (fix the pairing test up front)**

In `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift`, `testCatalogHasAllCommands`, add `"shipped"` to the set literal (end of the list, next to `"synced"`):

```swift
            "trustState", "batch-spawn", "trust", "set-parent", "tree", "synced", "shipped",
```

- [ ] **Step 4: Implement `shipped` in `OrchestraService+Tree.swift`**

Add this method to the `extension OrchestraService` in `Sources/OrchestraCore/OrchestraService+Tree.swift` (after `synced`):

```swift
    /// `shipped` — post-merge bookkeeping, run once a child branch has been merged into its parent
    /// (by the parent's agent for a live parent, or by the child borrowing a bare parent). The daemon
    /// performs NO git surgery here — only lineage config writes + inbox nudges. Three steps, idempotent:
    ///   (a) NOTIFY the parent's card (active card owning `repo` + the child's recorded parent branch) that
    ///       the child landed; no such card ⇒ a warning-level activity item (bare parent, nothing to wake).
    ///   (b) RETARGET the child's OWN children onto the grandparent (the child's parent): repoint each
    ///       child's lineage parent, KEEP its recorded base (the rebase anchor), set `treeStat =
    ///       restackNeeded`, and nudge it to `rebase --onto <grandparent> <recorded-base>` + wake.
    ///   (c) CLEAR the shipped child's own lineage so a second `shipped` is a pure no-op: its parent lookup
    ///       finds nothing (no duplicate notify) and `children(of: child)` is empty because they now point
    ///       at the grandparent (no duplicate nudges).
    @discardableResult
    public func shipped(ref: String, source: ActivitySource = .daemon) async throws -> Task {
        let child = try await resolveRef(ref)
        guard child.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards can be shipped")
        }
        let link = await lineage.read(repo: child.repo, branch: child.branch)
        let grandparent = link?.parent

        // (a) notify the parent's card, if one owns the parent branch.
        if let parent = grandparent {
            let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
            if let parentCard = active.first(where: { $0.repo == child.repo && $0.branch == parent }) {
                try? await inbox.enqueue(parentCard.id,
                    "child \(child.branch) (\(child.shortId)) merged into you — it's in your branch now")
                await wake(parentCard.id)
            } else {
                emitActivity(.warning, child, source,
                    "shipped \(child.branch): no active card owns parent \(parent) to notify")
            }
        } else {
            emitActivity(.warning, child, source,
                "shipped \(child.branch): no recorded parent link — nothing to notify or retarget")
        }

        // (b) retarget the child's own children onto the grandparent (keep each one's recorded base).
        if let grandparent {
            let grandchildren = await lineage.children(repo: child.repo, of: child.branch)
            let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
            for gcBranch in grandchildren {
                guard let gcLink = await lineage.read(repo: child.repo, branch: gcBranch) else { continue }
                // Repoint parent; KEEP the recorded base — it is the rebase anchor the agent replays from.
                try? await lineage.set(repo: child.repo, branch: gcBranch,
                                       link: ParentLink(parent: grandparent, base: gcLink.base))
                if let card = active.first(where: { $0.repo == child.repo && $0.branch == gcBranch }) {
                    if let saved = try? await store.update(card.id, {
                        $0.parentBranch = grandparent
                        $0.treeStat = TreeStat(state: .restackNeeded)
                    }) {
                        emit(.taskUpserted(saved))
                    }
                    try? await inbox.enqueue(card.id,
                        "parent \(child.branch) shipped — commit WIP, then `git rebase --onto "
                        + "\(grandparent) \(gcLink.base)`, then `orchestra synced \(card.shortId)`")
                    await wake(card.id)
                }
            }
        }

        // (c) clear the shipped child's own lineage → re-run is a no-op; treeStat clears on next recompute.
        try? await lineage.clear(repo: child.repo, branch: child.branch)
        let updated = (try? await store.update(child.id, { $0.parentBranch = nil; $0.treeStat = nil })) ?? child
        emit(.taskUpserted(updated))
        emitActivity(.command, updated, source, "shipped \(child.branch)")
        return updated
    }
```

- [ ] **Step 5: Add the `shipped` CLI case**

In `Sources/orchestra/CLIRunner.swift`, after the `"synced"` case (~line 120-123), mirror it:

```swift
            case "shipped":
                let ref = try positionalOrFlag(args, "ref")
                let task = try await client.call("shipped", .object(["ref": .string(ref)]))
                printResult(task)
```

Match the exact helper names/shape the neighboring `synced`/`set-parent` cases use (`positionalOrFlag`, `printResult` or whatever the file calls them — copy the `synced` case's surrounding idiom verbatim, substituting `shipped`).

- [ ] **Step 6: Write `ShipChoreoTests`**

`Tests/OrchestraCoreTests/ShipChoreoTests.swift`. Reuse `TreeStatTests` fixtures (`repoWithParent`, `git`, `write`, `advanceParent`) and `TestEnv`/`EventCollector`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Ship choreography — shipped notify + retarget + idempotence")
struct ShipChoreoTests {

    /// A repo on main with `parent`, plus a `child` branch off parent's tip (BranchLineage config set).
    /// Returns (repo, childBase = parent tip at link time).
    static func repoWithChild(_ base: String) throws -> (repo: String, childBase: String) {
        let repo = try TreeStatTests.repoWithParent(base)   // main + parent
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "child", "parent")
        try TreeStatTests.write(repo, "c.txt", "child\n")
        try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "child work")
        try TreeStatTests.git(repo, "checkout", "-q", "main")
        let parentTip = try TreeStatTests.git(repo, "rev-parse", "parent")
        return (repo, parentTip)
    }

    // (a) live parent card gets an inbox message + wake
    @Test("live parent card is notified when its child ships")
    func liveParentNotified() async throws {
        let env = TestEnv.make()
        let (repo, childBase) = try Self.repoWithChild(env.base)
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: childBase))

        try await env.svc.shipped(ref: child.ref())

        let msgs = try await env.svc.inboxPeek(parentCard.id)
        #expect(msgs.count == 1)
        #expect(msgs.first?.text.contains("child") == true)
        #expect(msgs.first?.text.contains("merged into you") == true)
        // shipped clears the child's own lineage
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    // (a) bare parent (no card) ⇒ warning activity, no throw
    @Test("bare parent (no card) yields a warning activity, not a throw")
    func bareParentActivity() async throws {
        let env = TestEnv.make()
        let (repo, childBase) = try Self.repoWithChild(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: childBase))
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        try await env.svc.shipped(ref: child.ref())   // must not throw (no parent card)

        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.contains { $0.text.contains("parent") })
    }

    // (b) two children retargeted to grandparent, base preserved, restackNeeded, nudged; idempotent
    @Test("shipping a mid branch retargets its two children onto the grandparent (base kept), once")
    func retargetsGrandchildren() async throws {
        let env = TestEnv.make()
        // Tree: main → grandparent → mid → {c1, c2}. Ship `mid`.
        let repo = TestEnv.repo(env.base)
        try TreeStatTests.git(repo, "init", "-q", "-b", "main")
        try TreeStatTests.git(repo, "config", "user.email", "t@t")
        try TreeStatTests.git(repo, "config", "user.name", "t")
        try TreeStatTests.write(repo, "a.txt", "0\n")
        try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "base")
        try TreeStatTests.git(repo, "branch", "grandparent")
        try TreeStatTests.git(repo, "checkout", "-q", "-b", "mid", "grandparent")
        try TreeStatTests.write(repo, "m.txt", "m\n"); try TreeStatTests.git(repo, "add", "-A")
        try TreeStatTests.git(repo, "commit", "-q", "-m", "mid work")
        let midTip = try TreeStatTests.git(repo, "rev-parse", "mid")
        try TreeStatTests.git(repo, "branch", "c1", "mid")
        try TreeStatTests.git(repo, "branch", "c2", "mid")
        try TreeStatTests.git(repo, "checkout", "-q", "main")

        let mid = try await env.svc.spawn(SpawnInput(prompt: "mid", repo: repo, branch: "mid"))
        let c1 = try await env.svc.spawn(SpawnInput(prompt: "c1", repo: repo, branch: "c1"))
        let c2 = try await env.svc.spawn(SpawnInput(prompt: "c2", repo: repo, branch: "c2"))
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "mid", link: ParentLink(parent: "grandparent",
                          base: try TreeStatTests.git(repo, "rev-parse", "grandparent")))
        try await lin.set(repo: repo, branch: "c1", link: ParentLink(parent: "mid", base: midTip))
        try await lin.set(repo: repo, branch: "c2", link: ParentLink(parent: "mid", base: midTip))

        try await env.svc.shipped(ref: mid.ref())

        // repointed to grandparent, base KEPT (== midTip)
        let l1 = try #require(await lin.read(repo: repo, branch: "c1"))
        let l2 = try #require(await lin.read(repo: repo, branch: "c2"))
        #expect(l1.parent == "grandparent" && l1.base == midTip)
        #expect(l2.parent == "grandparent" && l2.base == midTip)
        // treeStat restackNeeded on the cards
        #expect(await env.svc.list().first { $0.id == c1.id }?.treeStat?.state == .restackNeeded)
        #expect(await env.svc.list().first { $0.id == c2.id }?.treeStat?.state == .restackNeeded)
        // nudged with the rebase --onto command + recorded base
        let n1 = try await env.svc.inboxPeek(c1.id)
        #expect(n1.count == 1)
        #expect(n1.first?.text.contains("rebase --onto grandparent \(midTip)") == true)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)

        // idempotent re-run: mid's link cleared + children already repointed ⇒ no new nudges
        try await env.svc.shipped(ref: mid.ref())
        #expect(try await env.svc.inboxPeek(c1.id).count == 1)
        #expect(try await env.svc.inboxPeek(c2.id).count == 1)
    }
}
```

- [ ] **Step 7: Run tests — expect PASS**

Run: `swift test --filter ShipChoreoTests` then `swift test --filter CommandRegistryCatalogTests`
Expected: both PASS. If `resolveRef`/`ref()` or `positionalOrFlag`/`printResult` names differ, align to the actual signatures (grep the `synced` case + `TreeStatTests` for exact usage — already confirmed present).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift Sources/orchestra/CLIRunner.swift Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift Tests/OrchestraCoreTests/ShipChoreoTests.swift
git commit -m "feat(bt5): shipped RPC — notify parent + retarget grandchildren, idempotent"
```

---

## Task 4: `set-parent mode:"move"` — repoint + restack nudge

Lift BT1's adopt-only guard. `move` repoints the lineage to a new parent, KEEPS the recorded base (the rebase anchor), sets `treeStat = restackNeeded`, and nudges the owning card to `rebase --onto <new-parent> <recorded-base>`. `adopt` behavior is unchanged.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`setParent`)
- Test: `Tests/OrchestraCoreTests/SetParentMoveTests.swift`

**Interfaces:**
- Consumes: existing `setParent(ref:parent:mode:source:)` signature (unchanged), `lineage.read/set`, `store.update`, `inbox.enqueue`, `wake`, `mergeBaseOID` (already private in the file).

- [ ] **Step 1: Rewrite the guard + add the `move` arm in `setParent`**

In `Sources/OrchestraCore/OrchestraService+Tree.swift`, replace the current guard and adopt block. Delete:

```swift
        guard mode == "adopt" else {
            throw OrchestraError.invalidParams("mode must be 'adopt' (move is not yet available)")
        }
```

and change the `if let p = trimmed, !p.isEmpty { … }` adopt body to branch on mode:

```swift
        guard mode == "adopt" || mode == "move" else {
            throw OrchestraError.invalidParams("mode must be 'adopt' or 'move'")
        }
        let trimmed = parent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = trimmed, !p.isEmpty {
            guard p != t.branch else {
                throw OrchestraError.invalidParams("a branch cannot be its own parent: \(p)")
            }
            if mode == "move" {
                // MOVE: repoint the lineage but KEEP the recorded base — it is the rebase anchor the agent
                // replays from (`rebase --onto <new-parent> <recorded-base>`). Fall back to the merge-base
                // only when there is no prior link to preserve. The daemon never rewrites the branch; it
                // marks restack-needed and nudges the owning card to do the rebase in its own worktree.
                let existing = await lineage.read(repo: t.repo, branch: t.branch)
                let anchor = existing?.base ?? (try mergeBaseOID(repo: t.repo, t.branch, p))
                try await lineage.set(repo: t.repo, branch: t.branch, link: ParentLink(parent: p, base: anchor))
                let updated = try await store.update(t.id) {
                    $0.parentBranch = p
                    $0.treeStat = TreeStat(state: .restackNeeded)
                }
                emit(.taskUpserted(updated))
                try? await inbox.enqueue(t.id,
                    "parent moved to \(p) — commit WIP, then `git rebase --onto \(p) \(anchor)`, "
                    + "then `orchestra synced \(updated.shortId)`")
                await wake(t.id)
                emitActivity(.command, updated, source, "moved parent → \(p)")
                return updated
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
```

(Note: `move` with an omitted/empty `parent` falls through to the `else` clear branch — which is fine; there is no "move to nothing". The catalog doc already says omit `parent` to clear.)

- [ ] **Step 2: Write `SetParentMoveTests`**

`Tests/OrchestraCoreTests/SetParentMoveTests.swift`:

```swift
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
}
```

- [ ] **Step 3: Run tests — expect PASS**

Run: `swift test --filter SetParentMoveTests`
Expected: PASS. (`linkedChild` links `child → parent`; adopting/moving to `other` exercises the repoint.)

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Tests/OrchestraCoreTests/SetParentMoveTests.swift
git commit -m "feat(bt5): set-parent mode:move — repoint + keep base + restack nudge"
```

---

## Task 5: Redirect mechanics — `rebase --onto` transplants only the child's own commits

A pure-git fixture proving the phantom-conflict fix independent of any agent or service: when a parent is **squash-merged** into main and the child rebases with `--onto main <recorded-base>`, only the child's own commits transplant (the parent's already-in-main work is not re-applied → no conflict).

**Files:**
- Test: `Tests/OrchestraCoreTests/RedirectMechanicsTests.swift`

**Interfaces:**
- Consumes: `Proc.run` (via `TreeStatTests.git` helper), real `git`.

- [ ] **Step 1: Write the failing test**

`Tests/OrchestraCoreTests/RedirectMechanicsTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Redirect mechanics — rebase --onto after a squash-merged parent")
struct RedirectMechanicsTests {

    @Test("rebase --onto <grandparent> <recorded-base> transplants ONLY the child's own commits, no conflict")
    func onlyChildCommitsTransplant() async throws {
        let repo = TestEnv.repo(TestEnv.make().base)
        func git(_ a: String...) throws -> String {
            let r = try Proc.run(["git", "-C", repo] + a)
            #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ rel: String, _ s: String) throws {
            try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
        }

        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t"); try git("config", "user.name", "t")
        try write("shared.txt", "base\n"); try git("add", "-A"); try git("commit", "-q", "-m", "base")

        // parent adds a commit that touches shared.txt
        try git("checkout", "-q", "-b", "parent")
        try write("shared.txt", "base\nPARENT-LINE\n"); try write("p.txt", "p\n")
        try git("add", "-A"); try git("commit", "-q", "-m", "parent work")
        let recordedBase = try git("rev-parse", "parent")   // child's recorded base = parent tip

        // child forks off parent, adds TWO of its own commits
        try git("checkout", "-q", "-b", "child")
        try write("c1.txt", "c1\n"); try git("add", "-A"); try git("commit", "-q", "-m", "child 1")
        try write("c2.txt", "c2\n"); try git("add", "-A"); try git("commit", "-q", "-m", "child 2")

        // parent is SQUASH-merged into main (new OID; same net change to shared.txt)
        try git("checkout", "-q", "main")
        try git("merge", "--squash", "parent")
        try git("commit", "-q", "-m", "squash parent into main")

        // redirect: replay only base..child onto main
        let r = try Proc.run(["git", "-C", repo, "rebase", "--onto", "main", recordedBase, "child"])
        #expect(r.ok, "rebase --onto must apply cleanly (no phantom conflict): \(r.stderr)")

        // child now sits directly on main and carries EXACTLY its own two commits
        try git("checkout", "-q", "child")
        let count = try git("rev-list", "--count", "main..child")
        #expect(count == "2")
        let subjects = try git("log", "--format=%s", "main..child")
        #expect(subjects.contains("child 1"))
        #expect(subjects.contains("child 2"))
        #expect(!subjects.contains("parent work"))   // parent's commit NOT re-applied
    }
}
```

- [ ] **Step 2: Run test — expect PASS**

Run: `swift test --filter RedirectMechanicsTests`
Expected: PASS. If the rebase reports a conflict, that is a real fixture bug (the `--onto` base must be the parent tip the child forked from) — fix the fixture, not the assertion.

- [ ] **Step 3: Commit**

```bash
git add Tests/OrchestraCoreTests/RedirectMechanicsTests.swift
git commit -m "test(bt5): redirect mechanics — rebase --onto transplants only child commits"
```

---

## Task 6: `.claude/commands/ship.md` — tree-aware branch

Add a tree-aware path to the checked-in Claude `/ship` slash command, keeping the existing main flow intact. No unit test (slash-command prose is deliberately untested per 04-tests.md); verified by reading.

**Files:**
- Modify: `.claude/commands/ship.md`

- [ ] **Step 1: Insert a tree-resolution step before the main-merge steps**

Edit `.claude/commands/ship.md`. Keep the frontmatter and the intro line. Insert a new step **before** the current step 2 ("Merge to main"), and renumber. The tree-aware branch:

```markdown
2. **Resolve the parent** — run `orchestra tree <this-card>` (ref = `ORCHESTRA_TASK_ID`). If this branch has a tree parent that is NOT `main`, ship UP the tree instead of to main:
   - **Parent has a live card** → you cannot advance a branch checked out in another worktree. `orchestra send <parent-ref> "merge-request: squash-merge <this-branch> into <parent>"`, then **stop** — the parent's agent merges in its own worktree and calls `orchestra shipped <this-card>`, which notifies it and retargets any children of yours. Do not `cd` into the parent's worktree, do not merge to main.
   - **Bare local parent (no card owns it)** → borrow it ephemerally: `git worktree add` a throwaway checkout of the parent branch, `git merge --squash <this-branch>`, commit, remove the worktree, then `orchestra shipped <this-card>`.
   - **Parent is `main` (or no parent)** → continue with the standard main flow below.
   - **Remote parent (`origin/…` or a PR)** → out of scope for now; stop and report rather than guessing.
```

Then keep the existing steps (Merge to main / Relaunch / Archive) as the "standard main flow below", renumbered 3–5. Leave the `$ARGUMENTS` / `no-relaunch` note as-is.

- [ ] **Step 2: Verify the file reads coherently**

Run: `cat .claude/commands/ship.md` — confirm the main flow is intact and the tree branch precedes it, numbering is sequential.

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/ship.md
git commit -m "docs(bt5): tree-aware /ship — resolve parent before merging to main"
```

---

## Task 7: Full-suite green + self-review

**Files:** none (verification only)

- [ ] **Step 1: Run the whole test suite**

Run: `swift test 2>&1 | tail -40`
Expected: all suites pass — specifically `TreeDocsTests`, `ShipChoreoTests`, `SetParentMoveTests`, `RedirectMechanicsTests`, `CodexAdapterTests`, `DelegationDocsTests`, `CommandRegistryCatalogTests`, plus the untouched BT1–BT4 suites (`LineageTests`, `TreeStatTests`, `StaleNudgeTests`, `TreeCommandTests`, `CommandsTests`).

- [ ] **Step 2: Build the CLI target too (catches CLIRunner drift)**

Run: `swift build 2>&1 | tail -20`
Expected: clean build (the `shipped` CLI case compiles against the real client signature).

- [ ] **Step 3: Grep for accidental scope violations**

Run: `git diff --stat plan/parent-card-branch-linking` — confirm only the files in this plan's File Structure changed, and nothing under `OrchestraUI`/`App`/`App-iOS` (BT7's turf) was touched.

- [ ] **Step 4: Move to review + request code review**

Move this card to the review column (`move <id> --col review`) and run superpowers:requesting-code-review with a subagent over the diff vs `plan/parent-card-branch-linking`. Fix findings; repeat until a clean round.

---

## Self-Review (checklist run against the contract)

**Spec coverage (02-contract §Ship choreography, 03 §8, 04-tests):**
- `shipped` (a) notify live parent / (b) bare-parent activity → Task 3, ShipChoreoTests `liveParentNotified` / `bareParentActivity`. ✓
- `shipped` (b) retarget 2 children to grandparent, base kept, restackNeeded, idempotent → Task 3, `retargetsGrandchildren`. ✓
- Double-`shipped` idempotent (no duplicate nudges) → Task 3, idempotent re-run assertions (mechanism: lineage clear + children already repointed). ✓
- `set-parent move` repoint + nudge; adopt unchanged → Task 4, SetParentMoveTests. ✓
- Redirect mechanics (squash-merged parent, `rebase --onto`, only child commits) → Task 5, RedirectMechanicsTests. ✓
- TreeDocs Claude install path + Codex sectioned AGENTS.md keeps BOTH sections across reinstall → Tasks 1–2, TreeDocsTests + updated CodexAdapterTests. ✓
- Codex installer generalized to compose sections without breaking DelegationDocsTests → Task 1 (`AgentsFileComposer`) + Task 2 (DelegationDocsTests untouched, exercises `DelegationDocs.install` directly). ✓
- Install from both adapters' spawn + recovery paths → Task 2 (via `prepareToLaunch`, called from spawn + both recovery sites). ✓
- `.claude/commands/ship.md` tree-aware branch, main flow intact → Task 6. ✓
- Catalog/registry pair for `shipped`, exposure `.all`, + CLI case → Task 3. ✓

**Placeholder scan:** none — every code step carries full code; the two skill docs carry real prose with the exact anchor strings TreeDocsTests asserts.

**Type consistency:** `shipped(ref:source:) -> Task`, `TreeStat(state:)`, `ParentLink(parent:base:)`, `AgentsFileComposer.upsert(section:content:at:)`, `TreeDocs.forAgent(_:)` used identically across tasks and tests. Recorded base is called `base`/`recorded-base` consistently; the nudge string format `rebase --onto <parent> <base>` matches between `shipped`, `set-parent move`, and both test assertions.

**Open risk to confirm during impl:** the exact CLI helper names in `CLIRunner.swift` (`positionalOrFlag`/`printResult`) — copy the neighboring `synced` case verbatim rather than assuming. The `set-parent` summary edit (Task 3 Step 1) may shift a string another test asserts on; the full-suite run in Task 7 catches it.
