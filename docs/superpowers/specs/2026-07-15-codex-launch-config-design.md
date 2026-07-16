# Codex Launch-Scoped Configuration Design

## Goal

Move Orchestra's Codex hooks, project trust, and standing delegation/tree guidance out of mutable global Codex files and into each `codex` invocation. Orchestra will compose provider-neutral guidance once, while each adapter remains responsible for translating that content into its provider's native launch surface: Claude keeps its managed `--settings` file and project skills; Codex emits repeated `-c key=value` overrides.

## Verified Codex Surface

The installed `codex-cli 0.144.4` accepts TOML-valued `-c` overrides, including nested inline hook tables, `projects."<cwd>".trust_level`, and `developer_instructions`. `codex resume --help` exposes the same `-c` option, so start and resume can receive the same launch-scoped configuration. CLI overrides have the highest configuration precedence. Codex merges hook sources, rather than replacing a lower-priority hooks file, which makes retiring Orchestra's old global hook entries necessary before injecting the same handlers inline.

## Current Problem

`CodexAdapter.prepareToLaunch` currently creates and writes under `$HOME/.codex`, then exports that directory as `CODEX_HOME` to every Codex process. The writes add project trust to `config.toml`, insert Orchestra sections into `AGENTS.md`, and install `hooks.json`. That couples Orchestra to Codex's durable auth/plugins/state root, changes user-global files, and lets a legacy Orchestra Stop hook coexist with an injected Stop hook once inline configuration is added.

## Design

### Shared Orchestra content, provider-specific delivery

`AgentGuidance` will be the common content seam. It loads the already-vendored delegation and branch-tree variants for an adapter id, exposes them as named sections, and can combine their bodies for a developer-instructions string. Claude will consume the sections by writing its two existing project skills; Codex will consume the combined text as `developer_instructions`. This keeps the Orchestra material and its composition in shared internals instead of duplicating it in either adapter.

`HooksRenderer` remains the single source for the provider-specific hook template. Its Codex path will expose the rendered, comment-free hooks object in memory as well as the existing template transformation. `CodexLaunchConfiguration` will encode those hook entries as TOML inline values and make deterministic repeated `-c hooks.<event>=...` pairs. It will also encode the quoted project path and the combined instructions safely, so paths, quotes, backslashes, and newlines cannot escape a CLI override.

### Codex launch behavior

Both `start` and `resume` will append the same launch-configuration flags:

- every rendered Codex hook event (`SessionStart`, `PermissionRequest`, and `Stop`);
- `projects."<cwd>".trust_level`, always set to either `"trusted"` or `"untrusted"` from `ctx.trustCwd`; and
- `developer_instructions`, containing the shared Orchestra guidance.

Passing both trust states matters: a previously written global `trusted` entry must not silently authorize a card whose current context is untrusted. The existing model, access, seed, and build-probed `--dangerously-bypass-hook-trust` flags remain in their existing roles. The hook-trust flag is still required by the installed Codex build for the launch-scoped handlers to run; it does not change approval or sandbox policy.

`CodexAdapter.env` will become empty. Production launch code will not set `CODEX_HOME`, create `~/.codex`, or write `config.toml`, `AGENTS.md`, or `hooks.json`. Codex therefore retains its ordinary native auth, plugins, logs, sessions, and user configuration. The adapter retains a `codexHome` resolver only for rollout discovery and hermetic tests, defaulting to Codex's ordinary `~/.codex/sessions` location.

### Legacy migration

`prepareToLaunch` becomes a best-effort retirement pass, not a configuration installer. It resolves the normal Codex home only to remove Orchestra's previous artifacts safely:

- `AgentsFileComposer` removes only its named `delegation` and `tree` marker blocks from global `AGENTS.md`; it never rewrites markerless user text.
- `CodexHooks` parses a legacy `hooks.json`, removes only command entries containing the Orchestra `_report --event` sentinel, drops now-empty handler groups and events, and preserves all foreign hooks and root properties. A purely Orchestra-owned file is removed. Malformed files are left untouched rather than guessed at.

Old trust records are deliberately not deleted because a project trust table cannot be safely attributed to Orchestra. The per-launch `untrusted` override wins over any stale entry without mutating the user's config.

## Failure Behavior

Missing bundled guidance or an invalid hook template degrades to the remaining valid overrides; it never prevents a launch. Legacy cleanup is idempotent and best-effort. The serializer only emits TOML forms representable by the hook schema; unsupported values are omitted rather than interpolated unsafely. Existing foreign global hooks remain loaded by Codex, and the injected hook source is additive as Codex specifies.

## Tests

Unit coverage will prove that start and resume carry equivalent `-c` overrides, preserve the existing access/model/seed behavior, and no longer export `CODEX_HOME`. Serializer tests will exercise quotes, backslashes, and newlines. Guidance tests will prove that Claude and Codex consume the same named source material in their respective packaging. Migration tests will prove marker-only AGENTS removal, pure legacy hook-file deletion, mixed-hook filtering, foreign-hook preservation, and malformed-file non-interference. Existing rollout discovery tests keep the injectable home resolver covered.

## Scope

This changes only Codex launch-scoped injection and cleanup of prior Orchestra-owned artifacts. It does not migrate user-authentication state, remove Codex's normal default home, rewrite arbitrary user TOML, change Claude's settings format, or alter card permission semantics.
