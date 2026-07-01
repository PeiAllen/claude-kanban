# D2 · Delegation Skill + AGENTS.md — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author the **delegation guidance** an Orchestra agent reads to decide *when* to hand off / fork /
fan-out / wait (vs. just continue or use a native subagent) — shipped as two vendored resources: a Claude
**skill** (`delegation-skill.md`, frontmatter + body) and a Codex **AGENTS.md** variant
(`delegation-agents.md`) — plus a tiny `DelegationDocs` loader (ModelCatalog-parallel) that the seed-injection
path will use to select the per-agent variant, and a test proving both resources are present + well-formed.

**Architecture:** This is a **prose/resource PR** — no new `Command`, no orchestration/adapter behavior change.
The two markdown resources live in `Sources/OrchestraCore/Resources/` and are `.copy`-bundled into
`Bundle.module` exactly like the offline model tables (`codex-models.json` et al.). A minimal
`enum DelegationDocs` (mirrors `enum ModelCatalog`) loads a variant by name and maps an `agentId` →
its variant (`claude-code` → the skill, `codex` → AGENTS.md). D2 authors + validates the content and exposes
the loader; **wiring the loader into `prepareToLaunch`/the seed is out of scope** (a later PR / D3-adjacent) —
D2 changes no launch path. The heuristic content is **identical** across both variants; only the packaging
(frontmatter vs. plain AGENTS.md) and a few per-agent tool-surface notes differ.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), `scripts/test.sh` (needs an
**unsandboxed** shell — `swift build`/`test` trip `sandbox-exec`), `scripts/typecheck-app.sh` (self-pins CLT).
Resources are `.copy`-bundled (`Bundle.module`), loaded offline (no network at build or runtime).

## Global Constraints

- **Prose/resource PR only** — NO new `Command`, NO `SpawnInput`/`spawn` change, NO adapter/launch behavior
  change. The `DelegationDocs` loader is additive resource plumbing (the `ModelCatalog` precedent), not
  orchestration logic, and is wired into **no** existing path in D2.
- **Do NOT replace native subagents.** The single most important content requirement: the guidance must tell
  the agent to KEEP native subagents (the `Task`/`Agent` tool) for ephemeral in-context fan-out, and use a
  *card* only for durable / parallel / cross-agent / isolated delegation. The two are complementary.
- **Per-agent variant** — Claude receives a **skill** (SKILL.md-style: `---` frontmatter with `name:` +
  `description:`, then a markdown body); Codex receives an **AGENTS.md** (plain markdown, no frontmatter —
  Codex reads `AGENTS.md` from the cwd). Same heuristics, different packaging.
- **Delegation surface the guidance teaches** (already shipped upstream — the guidance only *references* it):
  `spawn` / `batch-spawn` (start actions), `handoff <ref> <context…>` (D1 — F1 clean-context resume-in-card,
  or handoff→new via a seeded spawn), `send <ref> <msg>` (F3 inbox), `wait <ref…>` (C2 — block on
  conclusion; backs the reactive orchestration loop).
- **Offline** — resources are vendored + `.copy`-bundled; the test asserts they load from a local file URL
  (no network), mirroring `ModelCatalogTests.offlineLocalResource`.
- **`Bundle.module` in tests** — `OrchestraCoreTests` declares no resources, so `Bundle.module` (via
  `@testable import OrchestraCore`) resolves to OrchestraCore's bundle — the exact mechanism
  `ModelTableTests` already relies on. No test-target resource copy needed.
- Do throwaway work only in `./.scratch/`. `USE_REAL_CLAUDE` stays unset.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `Sources/OrchestraCore/Resources/delegation-skill.md` | **Create** | Claude-facing delegation skill (frontmatter + body): the heuristics + card-vs-subagent line |
| `Sources/OrchestraCore/Resources/delegation-agents.md` | **Create** | Codex-facing AGENTS.md variant: same heuristics, plain markdown, Codex tool-surface notes |
| `Package.swift` | Modify — add two `.copy` entries | bundle both resources into `Bundle.module` |
| `Sources/OrchestraCore/Agents/DelegationDocs.swift` | **Create** | `enum DelegationDocs` — load a variant by name; map `agentId` → variant (ModelCatalog-parallel) |
| `Tests/OrchestraCoreTests/DelegationDocsTests.swift` | **Create** | resources present + well-formed; per-agent selection; offline/local |
| `notes/plans/2026-07-01-d2-delegation-skill.md` | (this plan) | planning doc (notes/plans/ only, not docs/) |

## Interfaces

- **Produces:**
  - `enum DelegationDocs.Variant: String { case claudeSkill = "delegation-skill"; case codexAgents = "delegation-agents" }`
  - `static func DelegationDocs.load(_ variant: Variant) -> String?` — raw resource text from `Bundle.module`,
    `nil` if absent/unreadable (never throws into a launch path — mirrors `ModelCatalog.load`).
  - `static func DelegationDocs.forAgent(_ agentId: String) -> String?` — `"codex"` → `.codexAgents`, every
    other id (incl. `"claude-code"`) → `.claudeSkill` (Claude is the default surface).
- **Consumes:** `Bundle.module` (SwiftPM-synthesized), `Foundation`. Nothing from other D-PRs at runtime.

## Content spec — the heuristics (identical in both variants)

Both docs carry the SAME five sections (only packaging + a couple of per-agent notes differ). The test
asserts the required anchors are present in each, so the content spec below is also the test contract.

1. **The delegation surface** — the tools an agent drives: `spawn`/`batch-spawn` (start a card with a seed),
   `handoff` (F1 resume-in-card clean context, or handoff→new card), `send` (F3 inbox message), `wait`
   (block until any watched card concludes).
2. **Delegate vs. just continue** — delegate only when the work wants *isolation, parallelism, durability, a
   different agent, or its own PR/branch*. If it fits your current context and is tightly coupled to what
   you're doing → just do it inline. A card + worktree + wake round-trip is real overhead; don't pay it for
   trivial or tightly-coupled work.
3. **The four moves — when to use each:**
   - **Handoff** — your context is exhausted/messy but the task continues. *Same-card* (`handoff <thisCard>
     <summary>`): kill + `--resume` the same session, seeded with a clean summary — keep going on the SAME
     work with a fresh context window, same worktree/branch. *New-card*: seed a fresh spawn — when the
     continuation is distinct work, a different agent, or should run while THIS card stays alive.
   - **Fork** — you want an independent exploration of a *slice* and you'll want the result back. Spawn with
     the slice as the seed; the fork concludes → comes back to you via wake + inbox. Use for "try A vs B",
     parallel discussions.
   - **Fan-out** — N *independent* pieces of work to run in parallel, each in its own worktree. `batch-spawn`
     N. No come-back wiring unless you also `wait`. Use for a stacked-PR forest / N independent tasks.
   - **Wait** — after spawning child card(s), background `wait <refs>` to be re-invoked/woken when any
     concludes, then drain your inbox for their conclusions and react (e.g. spawn next-in-stack). This is the
     reactive orchestration loop (UC2).
4. **Card vs. native subagent (THE line):**
   - Use a **card** (spawn/handoff/fork/fan-out) for **durable · parallel · cross-agent · isolated** work:
     outlives your turn, its own git worktree, may run in parallel while you stay chattable, may be a
     different agent (Claude↔Codex), produces a PR/branch, and is observable on the board.
   - Keep **native subagents** (the `Task`/`Agent` tool) for **ephemeral in-context fan-out**: read-only
     research sweeps, quick parallel lookups, throwaway analysis you fold back into YOUR turn immediately.
     No worktree, no durable state, gone at turn-end, not on the board.
   - **Do NOT replace native subagents with cards** — they are complementary. Rule of thumb: *result must
     survive your turn / produce a commit or PR / run in parallel while you stay responsive / use a different
     agent → **card**. Just parallelize reading/searching and synthesize now → **subagent**.*
5. **Reactive orchestration loop** — spawn stack head → background `wait` (turn ends, you stay chattable) →
   child concludes → you're woken → drain inbox → spawn next-in-stack. Several children concluding mid-turn
   coalesce in the inbox and drain together — none lost.

**Per-agent notes (the only cross-variant differences):**
- **Skill (Claude):** frontmatter `name: orchestra-delegation` + a `description:` that triggers on
  delegation decisions; body as above; mentions native subagents = the `Task` tool.
- **AGENTS.md (Codex):** plain markdown (no frontmatter); same body; a note that Codex is woken by a
  send-keys nudge (so a just-concluded delegation may take a beat to surface) and that the MCP/CLI
  delegation tools are identical to Claude's — the seam is agent-agnostic.

---

## Task 1: Author the Claude delegation skill resource

**Files:**
- Create: `Sources/OrchestraCore/Resources/delegation-skill.md`

**Interfaces:**
- Produces: a resource file `delegation-skill.md` — frontmatter (`name`, `description`) + the 5-section body.
- Consumes: nothing.

- [ ] **Step 1: Write the skill markdown** — frontmatter then the five sections from the content spec. Exact
  content:

```markdown
---
name: orchestra-delegation
description: Use when deciding whether to delegate work to another Orchestra card (spawn / handoff / fork / fan-out / wait) instead of doing it inline or with a native subagent. Covers the card-vs-subagent line and the delegation tools.
---

# Orchestra delegation — when to hand off, fork, fan-out, or wait

You are one agent on an Orchestra board. Besides doing the work yourself, you can **delegate** to other
**cards** — each a durable, board-visible unit of work in its own git worktree, possibly running a
different agent. This skill is about **when** to reach for that, and when NOT to.

## The delegation surface (the tools)

- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
- **`handoff <ref> <context…>`** — F1 clean-context resume: kill + `--resume` the SAME session seeded with
  `context` (folded together with the card's pending inbox). Same worktree, same branch, fresh context
  window. Hand off to a *new* card instead by spawning with the context as the seed.
- **`send <ref> <message>`** — enqueue a message into a card's durable inbox (F3); it drains at the card's
  next turn-end, waking it if idle.
- **`wait <ref…>`** — block until **any** watched card concludes (merged / done / exited). Run it in the
  background so your turn ends and you stay chattable; you're re-invoked when a child concludes.

## Delegate, or just continue?

Delegate only when the work wants **isolation, parallelism, durability, a different agent, or its own
PR/branch**. If it fits your current context and is tightly coupled to what you're already doing, **just do
it inline** — a card + worktree + wake round-trip is real overhead. Don't pay it for trivial or
tightly-coupled work.

## The four moves — when to use each

- **Handoff** — *your context is exhausted or messy but the task continues.*
  - *Same card* (`handoff <thisCard> <summary>`): keep going on the SAME work with a clean context window,
    same worktree/branch. Write a tight summary as the seed.
  - *New card* (spawn with the summary as seed): when the continuation is distinct work, a different agent,
    or should run while THIS card stays alive.
- **Fork** — *you want an independent exploration of a slice, and you'll want the result back.* Spawn with
  the slice as the seed; the fork concludes and comes back to you via a wake + your inbox. Good for
  "try approach A vs. B" and parallel discussions.
- **Fan-out** — *N independent pieces of work to run in parallel*, each in its own worktree. `batch-spawn`
  them. There's no come-back wiring unless you also `wait`. Good for a stacked-PR forest or N independent
  tasks.
- **Wait** — *after spawning children, react when they finish.* Background `wait <refs>`; you're woken when
  any concludes; drain your inbox for the conclusions and act (e.g. spawn the next PR in the stack). Several
  children concluding at once coalesce in the inbox and drain together — none is lost.

## Cards vs. native subagents — keep both

You also have **native subagents** (the `Task` tool). These are NOT the same as cards, and cards do **not**
replace them.

- Use a **card** for **durable · parallel · cross-agent · isolated** work: it outlives your turn, gets its
  own git worktree, can run in parallel while you stay chattable, can be a different agent (Claude ↔ Codex),
  can produce a PR/branch, and is visible on the board.
- Keep a **native subagent** for **ephemeral, in-context fan-out**: read-only research sweeps, quick
  parallel lookups, throwaway analysis whose result you fold back into your OWN turn right away. A subagent
  has no worktree, no durable state, is gone at turn-end, and is not on the board.

**Rule of thumb:** if the result must survive your turn, produce a commit or PR, run in parallel while you
stay responsive, or use a different agent → **card**. If you just need to parallelize reading/searching and
synthesize the answer now → **subagent**. Reach for a card *in addition to*, never *instead of*, subagents.

## The reactive orchestration loop

The headline pattern: spawn the stack head → background `wait` → your turn ends (you stay chattable) → the
child concludes → you're woken → drain your inbox → spawn the next-in-stack off the merged branch. Repeat.
That is how one card orchestrates a whole PR forest without polling.
```

- [ ] **Step 2: Sanity-check the file** — confirm it exists and the anchors are present.

Run: `grep -c -iE 'handoff|fork|fan-out|wait|subagent' Sources/OrchestraCore/Resources/delegation-skill.md`
Expected: a positive count (≥ 5).

## Task 2: Author the Codex AGENTS.md variant resource

**Files:**
- Create: `Sources/OrchestraCore/Resources/delegation-agents.md`

**Interfaces:**
- Produces: a resource file `delegation-agents.md` — plain markdown (no frontmatter), same body + Codex notes.
- Consumes: nothing.

- [ ] **Step 1: Write the AGENTS.md markdown** — same five sections, no frontmatter, Codex-phrased notes.
  Exact content:

```markdown
# Orchestra delegation — when to hand off, fork, fan-out, or wait

You are one agent on an Orchestra board. Besides doing the work yourself, you can **delegate** to other
**cards** — each a durable, board-visible unit of work in its own git worktree, possibly running a
different agent (Claude or Codex). This file is about **when** to reach for that, and when NOT to. The
delegation tools below are the **same MCP/CLI surface** every agent sees — the seam is agent-agnostic.

## The delegation surface (the tools)

- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
- **`handoff <ref> <context…>`** — clean-context resume: restart the SAME session seeded with `context`
  (folded with the card's pending inbox). Same worktree, same branch, fresh context. Hand off to a *new*
  card instead by spawning with the context as the seed.
- **`send <ref> <message>`** — enqueue a message into a card's durable inbox; it is delivered at the card's
  next turn.
- **`wait <ref…>`** — block until **any** watched card concludes (merged / done / exited). Run it in the
  background so your turn ends; you are nudged awake when a child concludes.

## Delegate, or just continue?

Delegate only when the work wants **isolation, parallelism, durability, a different agent, or its own
PR/branch**. If it fits your current context and is tightly coupled to what you're already doing, **just do
it inline** — a card + worktree + wake round-trip is real overhead. Don't pay it for trivial or
tightly-coupled work.

## The four moves — when to use each

- **Handoff** — *your context is exhausted or messy but the task continues.*
  - *Same card* (`handoff <thisCard> <summary>`): keep going on the SAME work with a clean context window,
    same worktree/branch. Write a tight summary as the seed.
  - *New card* (spawn with the summary as seed): when the continuation is distinct work, a different agent,
    or should run while THIS card stays alive.
- **Fork** — *you want an independent exploration of a slice, and you'll want the result back.* Spawn with
  the slice as the seed; the fork concludes and comes back to you via a wake + your inbox. Good for
  "try approach A vs. B" and parallel discussions.
- **Fan-out** — *N independent pieces of work to run in parallel*, each in its own worktree. `batch-spawn`
  them. There's no come-back wiring unless you also `wait`. Good for a stacked-PR forest or N independent
  tasks.
- **Wait** — *after spawning children, react when they finish.* Background `wait <refs>`; you are woken when
  any concludes; drain your inbox for the conclusions and act (e.g. spawn the next PR in the stack). Several
  children concluding at once coalesce in the inbox and drain together — none is lost.

  Note: Codex is woken by a send-keys **nudge**, so a just-concluded delegation may take a beat to surface
  in your composer — that's expected; the conclusion is already durable in your inbox.

## Cards vs. ephemeral in-context helpers — keep both

Spinning up a **card** is heavyweight and durable; it is NOT the tool for throwaway, in-context work.

- Use a **card** for **durable · parallel · cross-agent · isolated** work: it outlives your turn, gets its
  own git worktree, can run in parallel while you stay responsive, can be a different agent, can produce a
  PR/branch, and is visible on the board.
- Keep **ephemeral in-context work** (a quick read-only sweep, a lookup, throwaway analysis you fold back
  into your OWN turn right away) *in your own turn* — don't spin up a card for it. If your harness has a
  native subagent / task helper, that is the right tool for ephemeral fan-out; a card is not.

**Rule of thumb:** if the result must survive your turn, produce a commit or PR, run in parallel while you
stay responsive, or use a different agent → **card**. If you just need to parallelize reading/searching and
synthesize the answer now → keep it **in-context** (a native subagent if you have one). Reach for a card
*in addition to*, never *instead of*, ephemeral in-context helpers.

## The reactive orchestration loop

The headline pattern: spawn the stack head → background `wait` → your turn ends → the child concludes → you
are nudged awake → drain your inbox → spawn the next-in-stack off the merged branch. Repeat. That is how one
card orchestrates a whole PR forest without polling.
```

- [ ] **Step 2: Sanity-check the file** — confirm it exists and the anchors are present.

Run: `grep -c -iE 'handoff|fork|fan-out|wait|card' Sources/OrchestraCore/Resources/delegation-agents.md`
Expected: a positive count (≥ 5).

## Task 3: Bundle both resources

**Files:**
- Modify: `Package.swift:32-38` (the OrchestraCore `resources:` array)

**Interfaces:**
- Consumes: the two files from Tasks 1–2.
- Produces: both resources reachable via `Bundle.module.url(forResource:withExtension:)`.

- [ ] **Step 1: Add two `.copy` entries** — after the `codex-models.json` line:

```swift
                .copy("Resources/codex-models.json"),
                .copy("Resources/com.orchestra.daemon.plist"),
                .copy("Resources/delegation-skill.md"),
                .copy("Resources/delegation-agents.md"),
```

(Insert the two `delegation-*.md` lines; keep the existing entries.)

- [ ] **Step 2: Verify the package still resolves** — `swift package describe --type json >/dev/null`
  (unsandboxed if it trips sandbox-exec). Expected: no error.

## Task 4: The `DelegationDocs` loader (TDD)

**Files:**
- Create: `Sources/OrchestraCore/Agents/DelegationDocs.swift`
- Create/Test: `Tests/OrchestraCoreTests/DelegationDocsTests.swift`

**Interfaces:**
- Produces: `DelegationDocs.Variant`, `DelegationDocs.load(_:)`, `DelegationDocs.forAgent(_:)` (signatures
  in the top-level Interfaces block).
- Consumes: `Bundle.module`.

- [ ] **Step 1: Write the failing test** — `Tests/OrchestraCoreTests/DelegationDocsTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Delegation docs — vendored skill + AGENTS.md resources")
struct DelegationDocsTests {

    // MARK: present + loadable

    @Test("both variants load non-empty from the bundle")
    func bothLoad() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        let agents = try #require(DelegationDocs.load(.codexAgents))
        #expect(!skill.isEmpty)
        #expect(!agents.isEmpty)
    }

    @Test("resources are bundled as local files, loaded OFFLINE (no network)")
    func offlineLocalResource() throws {
        let skillURL = try #require(Bundle.module.url(forResource: "delegation-skill", withExtension: "md"))
        let agentsURL = try #require(Bundle.module.url(forResource: "delegation-agents", withExtension: "md"))
        #expect(skillURL.isFileURL)
        #expect(agentsURL.isFileURL)
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
        #expect(FileManager.default.fileExists(atPath: agentsURL.path))
    }

    // MARK: per-agent selection (the Claude-vs-Codex variant)

    @Test("forAgent maps codex → AGENTS.md, everything else → the skill")
    func perAgentSelection() throws {
        #expect(DelegationDocs.forAgent("codex") == DelegationDocs.load(.codexAgents))
        #expect(DelegationDocs.forAgent("claude-code") == DelegationDocs.load(.claudeSkill))
        #expect(DelegationDocs.forAgent("some-future-agent") == DelegationDocs.load(.claudeSkill))
    }

    // MARK: well-formedness — skill frontmatter

    @Test("skill has YAML frontmatter with name + description")
    func skillFrontmatter() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        #expect(skill.hasPrefix("---\n"))
        // second `---` closes the frontmatter block
        let afterOpen = skill.dropFirst(4)
        #expect(afterOpen.contains("\n---\n"))
        #expect(skill.contains("name: orchestra-delegation"))
        #expect(skill.contains("description:"))
    }

    @Test("AGENTS.md is plain markdown (no YAML frontmatter)")
    func agentsHasNoFrontmatter() throws {
        let agents = try #require(DelegationDocs.load(.codexAgents))
        #expect(!agents.hasPrefix("---\n"))
        #expect(agents.hasPrefix("# "))   // starts with a heading
    }

    // MARK: well-formedness — required heuristic anchors in BOTH variants

    @Test("both variants cover the four moves + the card-vs-subagent line")
    func requiredAnchors() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            let lower = doc.lowercased()
            for anchor in ["handoff", "fork", "fan-out", "wait", "spawn",
                           "card", "in-context", "durable"] {
                #expect(lower.contains(anchor), "missing anchor: \(anchor)")
            }
        }
    }

    @Test("both variants tell the agent to KEEP ephemeral in-context helpers (don't replace)")
    func keepSubagentsLine() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            let lower = doc.lowercased()
            #expect(lower.contains("in addition to"))
            #expect(lower.contains("never") && lower.contains("instead of"))
        }
    }

    @Test("the Claude skill names the native subagent Task tool explicitly")
    func claudeNamesSubagent() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        #expect(skill.lowercased().contains("subagent"))
        #expect(skill.contains("Task"))
    }
}
```

- [ ] **Step 2: Run it — expect failure** (`DelegationDocs` undefined).

Run: `./scripts/test.sh --filter DelegationDocsTests` (unsandboxed if `sandbox-exec` trips).
Expected: FAIL — "cannot find 'DelegationDocs' in scope".

- [ ] **Step 3: Write the loader** — `Sources/OrchestraCore/Agents/DelegationDocs.swift`:

```swift
import Foundation

/// Loads the vendored, PR-authored **delegation guidance** an agent reads to decide when to hand off /
/// fork / fan-out / wait (vs. doing the work inline or with a native subagent). Two per-agent variants,
/// `.copy`-bundled into `Bundle.module` (no network — offline at build & runtime), parallel to
/// `ModelCatalog`. This is content-only plumbing: the seed-injection path selects a variant with
/// `forAgent(_:)` and delivers it (Claude as a skill, Codex as AGENTS.md); the docs never mutate launch
/// behavior on their own.
public enum DelegationDocs {
    /// The two authored variants — the raw resource basename (sans `.md`) is the enum's rawValue.
    public enum Variant: String {
        case claudeSkill = "delegation-skill"   // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "delegation-agents"  // plain AGENTS.md (Codex)
    }

    /// Read a variant's markdown from the bundle. Returns `nil` if the resource is absent/unreadable
    /// (callers degrade gracefully) — never throws into a launch path (mirrors `ModelCatalog.load`).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Select the variant for an agent id: Codex reads AGENTS.md; every other agent (Claude and, by
    /// default, any future agent) gets the skill. Content is identical across variants — only the
    /// packaging differs — so an unknown agent still gets correct guidance.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }
}
```

- [ ] **Step 4: Run the test — expect PASS.**

Run: `./scripts/test.sh --filter DelegationDocsTests` (unsandboxed if needed).
Expected: PASS — all cases green.

## Task 5: Full green + commit

- [ ] **Step 1: Full unit suite** — `./scripts/test.sh` (unsandboxed). Expected: all green. (Known flake:
  "no SessionStart callback in 2s" in `RecoveryTests`/`HandoffResumeTests` under parallel load — if those
  are the ONLY failures, re-run that `--filter` in isolation to confirm green, then treat as green.)
- [ ] **Step 2: App typecheck** — `./scripts/typecheck-app.sh` (self-pins CLT). Expected: success. (No app
  code changed, but the gate is required.)
- [ ] **Step 3: Commit to `deleg/02-skill`:**

```bash
git add Sources/OrchestraCore/Resources/delegation-skill.md \
        Sources/OrchestraCore/Resources/delegation-agents.md \
        Sources/OrchestraCore/Agents/DelegationDocs.swift \
        Package.swift \
        Tests/OrchestraCoreTests/DelegationDocsTests.swift \
        notes/plans/2026-07-01-d2-delegation-skill.md
git commit -m "feat(d2): delegation skill + AGENTS.md guidance resources"
```

## Self-Review

- **Spec coverage** (forest row D2 "Plan must cover"): heuristic wording (§ content spec + Tasks 1–2 ✓);
  card-vs-subagent line + keep native subagents (§4 + `keepSubagentsLine`/`claudeNamesSubagent` tests ✓);
  per-agent variant Claude-vs-Codex (two resources + `forAgent` + `perAgentSelection` test ✓); loops (§5
  reactive orchestration loop in both docs ✓). No new Command / no core logic change (loader is
  resource-only, unwired ✓).
- **Placeholder scan:** none — full content in Tasks 1, 2, 4.
- **Type consistency:** `Variant.claudeSkill`/`.codexAgents` rawValues match the resource basenames and the
  `Package.swift` `.copy` names (`delegation-skill.md` / `delegation-agents.md`); `load`/`forAgent`
  signatures match the test call sites.
- **Test-vs-content:** every anchor asserted (`handoff`, `fork`, `fan-out`, `wait`, `spawn`, `card`,
  `in-context`, `durable`, `in addition to`, `never`+`instead of`, `Task`/`subagent`) is present in the
  authored markdown above — verified by reading Tasks 1–2 against the `requiredAnchors`/`keepSubagentsLine`/
  `claudeNamesSubagent`/`skillFrontmatter` assertions.
</content>
</invoke>
