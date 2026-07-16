# Automatic Orchestra MCP Card Setup

## Goal

Every newly launched, resumed, or recovered Orchestra card should have access to the local `orchestra` MCP server without requiring a manual MCP registration step. The launch-local configuration must take precedence over a same-named global entry while preserving all unrelated user configuration.

The application should also offer an explicit opt-in setting that adds the Orchestra MCP server to the user's global Claude and Codex configuration when it is absent. Global installation is additive and idempotent: it must never replace an existing `orchestra` entry or rewrite unrelated settings.

## Current gap

The adapters currently render hooks, trust settings, and guidance for a card, but they do not pass an MCP configuration to the launched Claude or Codex process. The packaged app already ships `orchestrad`, `orchestra`, and `orchestra-mcp` together, so the missing behavior is configuration, not a separate CLI installation workflow.

## Launch-local behavior

Both adapters use the canonical server name `orchestra` and the absolute sibling path resolved for `orchestra-mcp`.

- Claude receives an inline JSON MCP configuration through `--mcp-config` on both start and resume. The flag is deliberately non-strict so Claude continues to load other configured servers; its same-name precedence rules make the launch-local `orchestra` entry win over a global one.
- Codex receives an `[mcp_servers.orchestra]` entry in the launch profile used by both start and resume. The profile is layered over the user's base configuration, so the launch-local same-name entry wins while unrelated global servers remain available.
- The local configuration is generated from the resolved sibling executable path and does not modify the repository, the user's global config, or the installed binaries.
- If the sibling lookup falls back to `PATH`, that resolved path is used. The existing bundled-app and Linux deployment layouts continue to ship all three binaries together; no additional CLI installer is introduced.

## Opt-in global installation

Add `autoInstallMCPGlobally` to the persisted Orchestra configuration with a default of `false`, expose it in Settings, and apply it during adapter preparation for a card launch.

When enabled:

- Claude adds the top-level `mcpServers.orchestra` entry to the user's global Claude config only when that entry is missing.
- Codex adds the `[mcp_servers.orchestra]` table to the user's global Codex config only when that table is missing.
- Existing same-name entries are left byte-for-byte untouched, including entries that point at an older or user-selected executable.
- Unrelated global entries are preserved, and writes are atomic where the existing configuration format permits it.
- A missing global config is created with only the Orchestra entry. Read or write failures fail closed for the global convenience step and do not change the default local launch behavior.

Turning the setting off stops future global additions; it does not remove or alter anything previously installed. Existing cards receive the local configuration the next time they start or resume.

## Implementation seams

Keep the server definition and global installation logic in a small testable OrchestraCore helper. Pass the resolved `orchestra-mcp` path through `AdapterContext` so Claude and Codex tests can use a deterministic temporary executable path without depending on the host installation.

The persisted setting flows through the existing `Config` Codable path and `getConfig`/`setConfig` control calls. The Settings view reads and saves it alongside the existing agent settings.

## Verification

Tests should prove the behavior at the argument/profile boundary and at the global-file boundary:

- legacy and current `Config` decoding default the setting safely to `false`;
- Claude start and resume include the local `orchestra` MCP JSON without enabling strict mode;
- Codex start and resume share a profile containing the local `orchestra` table;
- global installers add a missing entry, preserve unrelated entries, and leave an existing same-name entry untouched for both agents;
- the packaged sibling-binary resolution remains the source of the MCP command path.

Documentation should describe automatic per-card setup, the optional global setting, and the fact that the CLI and MCP executable are shipped together rather than installed through separate paths.

## Non-goals

This change does not migrate or overwrite an existing global `orchestra` server, remove global configuration when the setting is disabled, install binaries outside the existing app/deployment packaging, or introduce a separate CLI installation mechanism.
