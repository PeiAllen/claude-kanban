# Delegation-Skill Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the vendored, currently-inert `DelegationDocs` into the launch path so every newly-spawned card receives the delegation guidance — Claude as a project skill, Codex as a global AGENTS.md — with no global `~/.claude` install.

**Architecture:** Each adapter's existing `prepareToLaunch(_ ctx:)` (already the home of Claude trust + read-only settings, and Codex `CODEX_HOME` + trust) gains one additive, best-effort side effect: materialize `DelegationDocs.forAgent(id)` to that agent's own discovery location. Content-selection stays in `DelegationDocs.forAgent` (keyed on the adapter's own `id` — no `if claude` in core); the destination path is the adapter's own packaging knowledge (mirrors `ClaudeTrust` vs `CodexTrust`). A shared `DelegationDocs.install(agentId:at:)` DRYs the load-and-write with nil/error tolerance.

**Tech Stack:** Swift, SwiftPM, `swift-testing` (`@Suite`/`@Test`/`#expect`). `Bundle.module` resources.

## Global Constraints

- **Additive + behavior-preserving:** existing Claude/Codex `start`/`resume` argv and `env` stay byte-identical — the ONLY change is the added materialization inside `prepareToLaunch`.
- **Degrade gracefully:** if `DelegationDocs.load`/`forAgent` returns nil (resource absent) or any write/mkdir fails, no-op — NEVER throw into the launch path (mirror `ModelCatalog`/`DelegationDocs`/`ClaudeTrust` nil-tolerance). `prepareToLaunch` stays `throws` but the delegation step never throws.
- **Keyed on the agent, not a hardcoded branch:** content chosen via `DelegationDocs.forAgent(id)` (`id` = the adapter's own `id`). Codex→AGENTS.md, everything else→skill.
- **Idempotent; no clobber; no leakage:** re-launch overwrites Orchestra's own managed file atomically. Claude writes under the (conventionally gitignored) `.claude/`; Codex writes to the Orchestra-owned isolated `CODEX_HOME` — never the user's project `AGENTS.md` (which would be clobbered, one-file-per-directory) and never the user's real repo/home.
- **Discovery (verified against current official docs):** Claude project skills load from `<cwd>/.claude/skills/<name>/SKILL.md`; Codex reads `$CODEX_HOME/AGENTS.md` as the top (global) level of its precedence order, merged *above* project AGENTS.md.
- **USE_REAL_CLAUDE stays unset.** Build/test require an UNSANDBOXED shell (`swift build`/`test` under sandbox-exec fails → re-run no-sandbox). Plan docs live in `notes/plans/` only.

---

### Task 1: `DelegationDocs.install(agentId:at:)` — load-and-write helper

**Files:**
- Modify: `Sources/OrchestraCore/Agents/DelegationDocs.swift`
- Test: `Tests/OrchestraCoreTests/DelegationDocsTests.swift`

**Interfaces:**
- Consumes: `DelegationDocs.forAgent(_ agentId: String) -> String?` (existing).
- Produces: `@discardableResult static func install(agentId: String, at path: String) -> Bool` — loads `forAgent(agentId)`, creates the parent directory, atomically writes the content to `path`. Returns `true` on write, `false` if content is nil or any FS step fails. Never throws.

- [ ] **Step 1: Write the failing tests**

Add to `DelegationDocsTests.swift`:

```swift
    // MARK: install() — load + materialize to a destination path

    @Test("install writes the agent's variant to the destination, creating parent dirs")
    func installWritesVariant() throws {
        let base = NSTemporaryDirectory() + "deleg-install-\(UUID().uuidString)"
        let claudePath = "\(base)/.claude/skills/orchestra-delegation/SKILL.md"
        let codexPath = "\(base)/codexhome/AGENTS.md"
        #expect(DelegationDocs.install(agentId: "claude-code", at: claudePath) == true)
        #expect(DelegationDocs.install(agentId: "codex", at: codexPath) == true)
        // agentId-keyed: each destination holds its OWN variant, byte-for-byte.
        #expect(try String(contentsOfFile: claudePath, encoding: .utf8) == DelegationDocs.load(.claudeSkill))
        #expect(try String(contentsOfFile: codexPath, encoding: .utf8) == DelegationDocs.load(.codexAgents))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("install is idempotent — a second call rewrites the same content, still true")
    func installIdempotent() throws {
        let base = NSTemporaryDirectory() + "deleg-idem-\(UUID().uuidString)"
        let path = "\(base)/.claude/skills/orchestra-delegation/SKILL.md"
        #expect(DelegationDocs.install(agentId: "claude-code", at: path) == true)
        #expect(DelegationDocs.install(agentId: "claude-code", at: path) == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == DelegationDocs.load(.claudeSkill))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("install degrades gracefully (returns false, no throw) when the dir can't be created")
    func installGracefulOnUnwritable() {
        // Parent creation under a non-writable root fails → no throw, returns false.
        #expect(DelegationDocs.install(agentId: "claude-code",
                                       at: "/proc/nonexistent-\(UUID().uuidString)/SKILL.md") == false)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (UNSANDBOXED): `./scripts/test.sh --filter DelegationDocsTests`
Expected: FAIL — `install` is not a member of `DelegationDocs`.

- [ ] **Step 3: Implement `install`**

Add to `DelegationDocs` (after `forAgent`) in `Sources/OrchestraCore/Agents/DelegationDocs.swift`:

```swift
    /// Materialize an agent's delegation guidance to `path` (creating parent dirs), for the
    /// seed-injection launch path. Best-effort by design: returns `false` and does nothing if the
    /// resource is absent (`forAgent` nil) or any FS step fails — NEVER throws into a launch path
    /// (mirrors `load`'s nil-tolerance). Idempotent: an atomic overwrite of the same content.
    @discardableResult
    public static func install(agentId: String, at path: String) -> Bool {
        guard let text = forAgent(agentId) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter DelegationDocsTests`
Expected: PASS (all existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/DelegationDocs.swift Tests/OrchestraCoreTests/DelegationDocsTests.swift
git commit -m "feat(deleg): DelegationDocs.install(agentId:at:) load-and-write helper"
```

---

### Task 2: Claude — materialize the skill in `prepareToLaunch`

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Test: `Tests/OrchestraCoreTests/AdapterTests.swift`

**Interfaces:**
- Consumes: `DelegationDocs.install(agentId:at:)` (Task 1), `self.id` (`"claude-code"`), `ctx.cwd`.
- Produces: after `prepareToLaunch`, `<cwd>/.claude/skills/orchestra-delegation/SKILL.md` holds the Claude skill variant. `start`/`resume`/`env` unchanged.

- [ ] **Step 1: Write the failing tests**

Add a suite to `AdapterTests.swift`:

```swift
@Suite("ClaudeCodeAdapter — delegation skill materialization")
struct ClaudeDelegationTests {
    private func tmpCwd() -> String {
        let d = NSTemporaryDirectory() + "claude-deleg-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func skillPath(_ cwd: String) -> String {
        "\(cwd)/.claude/skills/orchestra-delegation/SKILL.md"
    }

    @Test("prepareToLaunch writes the Claude skill variant under .claude/skills")
    func materializesSkill() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: cwd))
        let text = try String(contentsOfFile: skillPath(cwd), encoding: .utf8)
        #expect(text == DelegationDocs.load(.claudeSkill))       // the Claude variant, not Codex
        #expect(text.contains("name: orchestra-delegation"))
    }

    @Test("materialization is idempotent across launches (no throw, same content)")
    func idempotent() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        let a = ClaudeCodeAdapter()
        try a.prepareToLaunch(AdapterContext(cwd: cwd))
        try a.prepareToLaunch(AdapterContext(cwd: cwd))
        #expect(try String(contentsOfFile: skillPath(cwd), encoding: .utf8) == DelegationDocs.load(.claudeSkill))
    }

    @Test("prepareToLaunch degrades gracefully (no throw) when cwd is unwritable")
    func gracefulOnBadCwd() {
        #expect(throws: Never.self) {
            try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: "/proc/nope-\(UUID().uuidString)"))
        }
    }

    @Test("start(ctx) argv + env are unchanged by the added materialization")
    func argvUnchanged() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: cwd, model: "claude-sonnet-4-6", startIn: .plan,
                                 sessionId: "sid", prompt: "do it", name: nil, hooksPath: "/hooks.json")
        let before = a.start(ctx)
        try a.prepareToLaunch(ctx)
        #expect(a.start(ctx) == before)                          // byte-identical argv
        #expect(a.env.isEmpty)                                   // Claude adds no env
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ClaudeDelegationTests`
Expected: FAIL — `materializesSkill`/`idempotent` fail (no file written; `String(contentsOfFile:)` throws).

- [ ] **Step 3: Implement the materialization**

In `ClaudeCodeAdapter.prepareToLaunch`, after the existing read-only settings block (still inside the method), add:

```swift
        // Standing delegation guidance for EVERY card (independent of ctx.seed): deliver the Claude
        // skill variant to the per-card project-skill location Claude Code discovers. `.claude/` is
        // gitignore-conventional, so this doesn't dirty the tracked worktree. Best-effort (no throw):
        // content is keyed via forAgent(id) — no `if claude` here.
        DelegationDocs.install(agentId: id, at: "\(ctx.cwd)/.claude/skills/orchestra-delegation/SKILL.md")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ClaudeDelegationTests`
Expected: PASS. Also run `./scripts/test.sh --filter AdapterTests` and `--filter ReadOnlyAdapterTests` — still green (argv assertions unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Tests/OrchestraCoreTests/AdapterTests.swift
git commit -m "feat(deleg): materialize Claude delegation skill in prepareToLaunch"
```

---

### Task 3: Codex — materialize AGENTS.md to the isolated `CODEX_HOME`

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift`
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `DelegationDocs.install(agentId:at:)` (Task 1), `self.id` (`"codex"`), `self.codexHome`.
- Produces: after `prepareToLaunch`, `<codexHome>/AGENTS.md` holds the Codex AGENTS.md variant. `start`/`resume`/`env` unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `CodexAdapterTests.swift` (a new suite alongside `CodexAdapterTrustTests`):

```swift
@Suite("CodexAdapter — delegation AGENTS.md materialization")
struct CodexDelegationTests {
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-deleg-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }

    @Test("prepareToLaunch writes the Codex AGENTS.md variant into the isolated CODEX_HOME")
    func materializesAgents() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", trustCwd: false))
        let text = try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8)
        #expect(text == DelegationDocs.load(.codexAgents))       // the Codex variant, not the skill
        #expect(!text.hasPrefix("---\n"))                        // plain AGENTS.md, no frontmatter
    }

    @Test("materialization does not touch the worktree cwd (no leakage / no clobber)")
    func noWorktreeWrite() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = NSTemporaryDirectory() + "cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, trustCwd: false))
        #expect(!FileManager.default.fileExists(atPath: "\(cwd)/AGENTS.md"))   // never in the worktree
    }

    @Test("idempotent + coexists with trust config write")
    func idempotentWithTrust() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ctx = AdapterContext(cwd: "/wt", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        try adapter.prepareToLaunch(ctx)
        #expect(try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8) == DelegationDocs.load(.codexAgents))
        // trust write (config.toml) is unaffected by the AGENTS.md materialization
        #expect((try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8))?.contains("trust_level = \"trusted\"") == true)
    }

    @Test("start argv + env are unchanged by the added materialization")
    func argvEnvUnchanged() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5-codex", prompt: "go")
        let before = adapter.start(ctx)
        try adapter.prepareToLaunch(ctx)
        #expect(adapter.start(ctx) == before)                    // byte-identical argv
        #expect(adapter.env["CODEX_HOME"] == home)               // env unchanged (still just CODEX_HOME)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter CodexDelegationTests`
Expected: FAIL — `materializesAgents`/`idempotentWithTrust` fail (no `AGENTS.md` written).

- [ ] **Step 3: Implement the materialization**

In `CodexAdapter.prepareToLaunch`, after the `CodexTrust.apply(...)` line (still inside the method), add:

```swift
        // Standing delegation guidance for EVERY Codex card (independent of ctx.seed): deliver the
        // AGENTS.md variant to the ISOLATED CODEX_HOME — the global (top) level of Codex's AGENTS.md
        // precedence, merged ABOVE any project AGENTS.md. Orchestra owns CODEX_HOME, so this never
        // clobbers the user's own project AGENTS.md nor dirties the worktree. Best-effort (no throw);
        // content keyed via forAgent(id).
        DelegationDocs.install(agentId: id, at: "\(codexHome)/AGENTS.md")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CodexDelegationTests`
Expected: PASS. Also `./scripts/test.sh --filter CodexAdapterTests` — existing trust/isolation tests still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "feat(deleg): materialize Codex delegation AGENTS.md into isolated CODEX_HOME"
```

---

### Task 4: Full green — behavior-preservation suites + typecheck + e2e

**Files:** none (verification only).

- [ ] **Step 1: Full test suite (UNSANDBOXED)**

Run: `./scripts/test.sh`
Expected: PASS. Behavior-preservation suites (`AdapterTests`, `ReportTests`, `RecoveryTests`, `ReadOnlyAdapterTests`, `CodexAdapterTests`, `HandoffResumeTests`) green.
KNOWN FLAKE: `no SessionStart callback in 2s` under parallel load — if that's the ONLY failure, re-run the affected `--filter` in isolation to confirm green.

- [ ] **Step 2: App typecheck**

Run: `./scripts/typecheck-app.sh`
Expected: PASS (self-pins CLT; no `DEVELOPER_DIR`).

- [ ] **Step 3: UX e2e (advisory, per O6 — touches launch)**

Run: `./scripts/orch-ux-e2e.sh --run-id skillinject`
Expected: PASS. The screenshot step may fail on a headless/locked window server — environmental, not a defect. Treat a screenshot-only failure as advisory-green.

- [ ] **Step 4: Move to `review` and report**

Report: `DONE: deleg/04-skill-injection — tests green` + one-line summary. Do NOT merge/archive (the orchestrator merges).

---

## Self-Review

1. **Spec coverage:** Injection point (`prepareToLaunch`) ✓ Task 2/3. Claude=skill / Codex=AGENTS.md ✓. `forAgent(id)`-keyed, no `if claude` in core ✓. Graceful nil/write-fail ✓ Task 1 Step 3 + Task 2/3 graceful tests. argv/env byte-identical ✓ `argvUnchanged`/`argvEnvUnchanged`. Idempotent ✓. No worktree dirty / no clobber / no leakage ✓ (Claude→gitignored `.claude/`; Codex→isolated `CODEX_HOME`, `noWorktreeWrite`). Behavior suites ✓ Task 4. e2e ✓ Task 4.
2. **Placeholder scan:** none — every step has concrete code/commands.
3. **Type consistency:** `install(agentId:at:) -> Bool` used identically in Tasks 1–3; `forAgent`/`load` names match existing source.
