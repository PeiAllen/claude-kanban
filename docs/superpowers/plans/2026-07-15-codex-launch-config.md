# Codex Launch-Scoped Configuration Implementation Plan

> **For agentic workers:** Use test-driven development for each implementation task. This plan executes in the current isolated worktree; no approval gate remains because the user explicitly authorized planning and implementation.

**Goal:** Deliver Codex hooks, trust, and Orchestra guidance through per-launch `-c` overrides, while preserving Codex's native home and safely retiring the old Orchestra-owned global artifacts.

**Architecture:** Shared `AgentGuidance` composes the existing delegation and tree content. Claude keeps provider-specific skill files and `--settings`; Codex maps that shared content plus its rendered hook template into deterministic TOML `-c` flags. `prepareToLaunch` only performs idempotent legacy cleanup.

**Tech Stack:** Swift 6, Foundation, Swift Testing, Codex CLI TOML overrides.

## Constraints

- Do not set `CODEX_HOME` in production or write new global `config.toml`, `AGENTS.md`, or `hooks.json` content.
- Pass the trust override for both trusted and untrusted cards on both start and resume.
- Preserve non-Orchestra user text and foreign hook entries during migration.
- Retain the test-only Codex-home injection seam for rollout-discovery fixtures.
- Keep Claude behavior and its `--settings` contract unchanged.

---

### Task 1: Specify the new launch and migration contract with failing tests

**Files:**

- Modify: `Tests/UnitTests/OrchestraCore/Agents/CodexAdapterTests.swift`
- Modify: `Tests/UnitTests/OrchestraCore/SessionBriefTests.swift`
- Modify: `Tests/UnitTests/OrchestraCore/Service/TreeDocsTests.swift`

- [x] Add assertions that start and resume contain the same Codex `-c` hook, trust, and instruction overrides; they must quote special characters correctly and retain model/access/seed behavior.
- [x] Replace pinned-`CODEX_HOME` expectations with an empty adapter environment while retaining injected-home rollout discovery.
- [x] Add red migration tests for marker-only AGENTS removal, mixed legacy hook filtering, pure Orchestra hook deletion, and foreign/malformed file preservation.
- [x] Run the focused test suites and confirm they fail for the absent configuration builder and cleanup API.

### Task 2: Centralize shared guidance and render Codex hook data in memory

**Files:**

- Add: `Sources/OrchestraCore/Agents/AgentGuidance.swift`
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Modify: `Sources/OrchestraCore/Control/HooksRenderer.swift`

- [x] Create a named guidance bundle from `DelegationDocs` and `TreeDocs`, with a deterministic combined developer-instructions body.
- [x] Route Claude's existing two skill writes through the bundle so content selection is shared while Claude retains its own filesystem packaging.
- [x] Refactor Codex hook rendering to expose the substituted, `_comment`-free hooks object without requiring a rendered global file.
- [x] Run the guidance and hook-renderer focused suites; confirm the new source remains byte-equivalent in content.

### Task 3: Add safe Codex override serialization and wire both launch paths

**Files:**

- Add: `Sources/OrchestraCore/Agents/CodexLaunchConfiguration.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift`

- [x] Implement deterministic TOML scalar, array, inline-table, and dotted-key encoding for the supported hook schema.
- [x] Build repeated `-c` pairs for rendered hooks, always-explicit trust, and shared developer instructions.
- [x] Use the same flags from `start` and `resume`; remove production `CODEX_HOME` export and config/AGENTS/hooks installation.
- [x] Keep `codexHome` only as an injectable rollout-discovery path.
- [x] Run `./scripts/test.sh --filter CodexAdapterTests` and verify the red tests become green.

### Task 4: Retire only legacy Orchestra artifacts

**Files:**

- Modify: `Sources/OrchestraCore/Agents/TreeDocs.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexHooks.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift`

- [x] Add an idempotent marker-block removal API that never resets markerless AGENTS content.
- [x] Replace hook installation with JSON-aware removal of only Orchestra command handlers, preserving mixed and foreign user configuration.
- [x] Invoke both cleanup steps as best effort during `prepareToLaunch`; do not remove ambiguous existing trust records.
- [x] Run the migration-focused suites and inspect a mixed fixture semantically.

### Task 5: Update durable documentation and verify the integrated result

**Files:**

- Modify: `docs/02-architecture.md`
- Modify: `docs/04-cards-worktrees-sessions.md`
- Modify: `docs/05-command-reference.md`
- Modify: `docs/09-design-decisions.md`
- Modify: `docs/10-roadmap.md`
- Modify: `docs/superpowers/specs/2026-07-15-codex-launch-config-design.md`
- Modify: this plan

- [x] Replace the old isolated-home/global-file descriptions with launch-scoped `-c` behavior and the safe migration rule.
- [x] Run `./scripts/test.sh`, `scripts/typecheck-app.sh`, and focused config/migration tests after all edits.
- [x] Run `git diff --check`, inspect all launch argv and cleanup call sites with `rg`, and update the plan checkboxes with actual evidence.
- [x] Commit the implementation with a focused message once verification passes; do not ship or merge unless asked.

## Verification evidence

- `./scripts/test.sh` passed 849 tests in 159 suites.
- `./scripts/test.sh --filter 'Codex|Tree docs|Delegation docs'` passed 85 tests in 13 suites; the final
  `CodexHooksTests` migration sweep passed 7 tests, `TreeDocsTests` passed 9 cleanup tests, and
  `ClaudeDelegationTests` passed 4 shared-guidance packaging tests.
- `./scripts/typecheck-app.sh` completed successfully; `git diff --check` passed.
- `codex --strict-config` accepted the generated TOML shapes for nested hooks, project trust, and
  developer instructions before stopping only because the noninteractive probe had no TTY.
