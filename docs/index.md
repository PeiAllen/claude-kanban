# Orchestra — Reference Manual

This is the complete reference for **Orchestra**, a local-only macOS app that orchestrates many coding
agents across repositories from a single Kanban board. It is written as a book: read it front-to-back
to understand the system, or jump to a chapter as a reference.

For a one-page overview, see the [project README](../README.md). For the design rationale behind every
decision, the chapters here link into the layered design vault under
[`notes/designs/`](../notes/designs/) and the shipped-PR plans under [`notes/plans/`](../notes/plans/).

## Table of contents

1. [**Concepts**](01-concepts.md) — What Orchestra is, what a *card* is, the columns and lifecycle, the
   four card modes, and the vocabulary used throughout the rest of the manual.
2. [**Architecture**](02-architecture.md) — The background daemon, the unix-socket control plane, the
   three clients (app / CLI / MCP), and the two-way agent report channel. How a command flows end to
   end.
3. [**Data model**](03-data-model.md) — The `Task` (card) schema field by field, statuses and dead
   reasons, persistence and schema migration, configuration, on-disk paths, errors, and events.
4. [**Cards, worktrees & sessions**](04-cards-worktrees-sessions.md) — The internals: git worktree
   management, tmux session topology, the agent adapter protocol, the Claude Code adapter, the
   three-layer read-only barrier, and crash/reboot recovery.
5. [**Command reference**](05-command-reference.md) — Every command in the `CommandRegistry` (the single
   surface shared by the CLI, the MCP bridge, and the app), the server-only built-in methods, and the
   JSON-RPC wire protocol.
6. [**CLI & MCP**](06-clients-cli-mcp.md) — Using the `orchestra` CLI, driving Orchestra from the MCP
   bridge, daemon lifecycle commands, and the hooks / `_report` status channel.
7. [**App UI**](07-app-ui.md) — A tour of the SwiftUI app: the board, cards, the spawn sheet, the
   inspector and its embedded terminals, shell tabs, settings, onboarding, recovery, and the theme.
8. [**Building & operations**](08-building-operations.md) — Building and testing the package, building
   the app bundle, the development scripts, status-line configuration, macOS (TCC) permissions, and
   troubleshooting.
9. [**Design decisions**](09-design-decisions.md) — The cross-cutting principles that shape Orchestra,
   and a history of the shipped feature PRs and what each delivered.
10. [**Roadmap**](10-roadmap.md) — The nine extensibility axes the project is designed toward, their
    dependency order, the shared architectural seams, and the open design questions.
11. [**Documentation automation**](11-doc-automation.md) — How this manual and the README are kept in
    sync with `main` automatically, and how to configure or disable it.

## How to read the citations

Where a chapter states a precise behavior, it usually names the file that implements it (for example,
`OrchestraService.swift` or `notes/designs/kanban-board/index.md`). Those are pointers for going
deeper, not required reading. Treat code paths as authoritative if the prose and the code ever drift —
and remember that this manual is regenerated automatically (see chapter 11), so it tracks `main`
closely.
