# 10. Roadmap

Orchestra is built to grow along **nine extensibility axes**. Each one has an approved *design-only*
layered plan (L1 design + L2 contract) under `notes/designs/<slug>/`, indexed by
[`notes/designs/extensibility-roadmap/index.md`](../notes/designs/extensibility-roadmap/index.md). None
are implemented yet — each is deepened to L3 + tests and built when picked up. The principle is to
design every change *toward* these axes, never away from them.

## The nine axes

| # | Axis | Slug | One-line goal |
|---|------|------|---------------|
| 1 | **Configurable columns** | `configurable-columns` | Turn the fixed `plan/impl/review` enum into a daemon-owned, ordered, configurable list of columns (data, not an enum). |
| 2 | **Multiple model providers** | `model-providers` | Make adding a coding agent beyond Claude Code (e.g. Codex CLI) a matter of writing one `Adapter`. |
| 3 | **Deeper agent integration** | `agent-integration` | More agent-facing commands, structured sub-status (an in-card progress tree), and richer Orchestra→agent context injection. |
| 4 | **Non-git cards + search** | `non-git-cards-search` | First-class non-git cards (already seeded by freeform) plus text search/discovery over cards. |
| 5 | **Automated PR-review phase** | `pr-review-phase` | A board column that, on entry, runs an agent to address PR review comments + failing checks and loop until clean or escalate. |
| 6 | **Context-clearing continuity** | `context-continuity` | When context fills, the agent saves a handoff and Orchestra launches a fresh agent seeded with it. |
| 7 | **View/review code on the board** | `code-review-on-board` | A diffstat on the card and an in-inspector structured diff, instead of only "View changes → Zed". |
| 8 | **Outside-source intake** | `external-intake` | Let external sources (a todo app, webhooks, email) create cards — just another control-plane client calling `spawn`. |
| 9 | **Phone client** | `phone-client` | An iOS client over SSH-forwarded UDS (Tailscale), reusing the shared core/board-model/theme. |

## Shared seams and dependency order

The axes are not independent — they plug into a handful of **architectural seams**, and that determines
the build order:

```
CommandRegistry single source (in axis 3) ─→ axes 2, 3, 5, 8
Adapter provider abstraction              ─→ axes 2, 3, 6
Columns as data (not enum, axis 1)        ─→ axes 1, 4, 5
Transport abstraction                     ─→ axes 8, 9
report hook channel                       ─→ axes 3, 5, 6
```

Sequencing guidance from the design gates:

1. **Foundational, do first:** the **`CommandRegistry` single-source refactor** (folded into axis 3).
   Today the CLI is a hand-written switch in `CLIRunner.swift` (not generated from the registry), and
   `models`/`archivedList`/`openInZed`/`getConfig` are server-only — so they're invisible to MCP.
   Making the registry the one true source unblocks axes 3, 5, and 8.
2. **Near-term standalone fix:** **`ControlClient` auto-reconnect** (pulled ahead from axis 9) hardens
   the desktop app today.
3. **First multi-provider consumer:** build a **`CodexAdapter`** (axis 2) once the adapter report-
   mapping seam lands. Studying Codex CLI forced three design points now baked into the model-providers
   design: session ids are **two-mode** (Claude seeds an id; Codex can't, so it's discovered from the
   report), `ctxPct` is **adapter-derived** where the agent doesn't report it (compute from tokens ÷ a
   new `AgentModel.contextWindow`), and report wiring is `{files, env, argv}` + trust, not one
   `--settings` file. Report mapping resolves **server-side** from the card's `agentId`.
4. **Dependency chains:** axis 1 enables 4 (freeform lane) + 5 (a review column); axis 2 → 3 → 5/6;
   axis 4 is used by 8; axis 7 feeds 5.

## Where Claude-specifics live today

Several seams are currently Claude-Code-shaped and must be generalized as axis 2/3 land — the design
notes call these out explicitly so they aren't deepened by accident:

- the report-ingestion path (`ReportHelper.map`, `claude-hooks.json`) and transcript/session discovery
  in `ClaudeCodeAdapter` (keyed to `~/.claude/projects`),
- the control plane (`ControlServer`/`ControlClient`) is raw-fd UDS only, with no `Transport`
  abstraction yet (needed for the phone client),
- `Column` is a fixed Swift enum baked into the model, board layout, `StartIn`, drag-drop, and the
  CLI/MCP `col` schema (axis 1 turns it into data).

## Open design questions

A few decisions are explicitly deferred until the relevant axis is built:

- **Spawn 1:1 enforcement** — when you try to spawn on an already-checked-out `repo+branch`: refuse +
  jump to the owning card, or auto-branch a suffixed branch? (`stacked-branches-and-guardian-
  handoff.md` §1.)
- **Context seed delivery** — inject the seed as a first message, or via `--append-system-prompt`, and
  with what precedence vs the hooks `--settings`? (`context-passing-topologies.md` §9.)
- **Merge-back timing** — inject a fork's conclusion on the parent's next turn, or interrupt the live
  agent immediately? (`context-passing-topologies.md` §9.)
- **Archiving a parent with live forks** — hard-block + override, or warn-and-proceed?
  (`stacked-branches-and-guardian-handoff.md` §7.1.)

Because this manual is regenerated whenever `main` changes (see [chapter 11](11-doc-automation.md)),
these tables will track the roadmap as axes move from design-only to shipped — at which point their rows
should migrate into [chapter 9's shipped history](09-design-decisions.md#shipped-feature-history).
