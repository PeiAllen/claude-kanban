# 10. Roadmap

Orchestra is built to grow along **nine extensibility axes**. Each one has an approved *design-only*
layered plan (L1 design + L2 contract) under `notes/designs/<slug>/`, indexed by
[`notes/designs/extensibility-roadmap/index.md`](../notes/designs/extensibility-roadmap/index.md). None
of the axes is fully built yet — each is deepened to L3 + tests and built when picked up — but **feature
work has already landed underneath them**: the freeform/borrowed/scratch/read-only PRs (see
[chapter 9](09-design-decisions.md#shipped-feature-history)) shipped the non-git card substrate, which
realizes axis 4's *non-git cards* half and provides the standalone freeform region, leaving **search** as
axis 4's live remainder. Axes **2, 3, and 6's handoff delivery** have since been **consolidated and
deepened to a single implementable L3 + tests design** — the [agent-provider interface](../notes/designs/agent-provider-interface/index.md)
vault (an agent-agnostic adapter seam with a per-agent **capability descriptor**, a **Codex** adapter, and
the **F1/F2/F3 live-delivery** functions that handoff/fork/fan-out compose from), with a defined **PR
forest** and every open question resolved (2026-07-01). The forest's **seam-contract root — PR A1 — has
now landed** ([plan](../notes/plans/2026-07-01-a1-seam-contract-freeze.md)): it froze the complete
`AgentCapabilities` descriptor and the defaulted `AdapterContext.seed`, and moved core to gate
session-seeding and resumability on the capability (never on adapter identity), with Claude behavior
byte-for-byte unchanged — see [chapter 9](09-design-decisions.md#shipped-feature-history). A second forest
PR, **E2 — the authMode soft-warn** ([plan](../notes/plans/e2-authmode-softwarn.md)), has also landed off
A1: an `AuthRateMonitor` that emits an advisory activity-feed warning when a subscription-auth adapter
fans out past a threshold, **advising but never capping** (see
[chapter 9](09-design-decisions.md#authmode-advise-on-fan-out-never-cap)). A third forest PR, **A2 — the
telemetry-source seam** ([plan](../notes/plans/2026-07-01-a2-telemetry-source-seam.md)), has now landed
too: it relocated the raw→`StatusReport` parse out of the `orchestra` CLI into the adapter behind a new
defaulted `Adapter.parse(_ raw: RawTelemetry)`, establishing the transport/parse boundary the design calls
for while keeping Claude telemetry byte-identical (see
[chapter 9](09-design-decisions.md#shipped-feature-history)). A fourth forest PR, **C1 —
the durable inbox + F3 Stop-drain** ([plan](../notes/plans/2026-07-01-c1-inbox-stopdrain.md)), has landed
too: it builds the **first of the design's three live-delivery functions** — a durable per-card
[inbox](03-data-model.md#the-inbox-store-f3) that `send` now routes through, drained into the agent at its
turn-end by the (unchanged) Claude Stop hook via a `decision:block` continuation, with a consecutive-inject
loop guard (see [chapter 9](09-design-decisions.md#shipped-feature-history)). A fifth forest PR, **C2 —
F2 wake + the merge-watch conclusion-watch** ([plan](../notes/plans/2026-07-01-c2-wake-mergewatch.md)), has
now landed on top of C1: the **second live-delivery function**, plus the [`wait` command / `MergeWatch`](05-command-reference.md#notes-on-key-commands)
that lets an orchestrator card block until a watched child concludes (read from **real card state, never
`git merge-base`**) and be woken as each conclusion coalesces into its inbox — the reactive fan-out (see
[chapter 9](09-design-decisions.md#shipped-feature-history)). Two more forest PRs, **B1 and B2 — the
Codex adapter + its rollout-tail telemetry** ([plan](../notes/plans/2026-07-01-b2-codex-rollout-tail.md)),
have now landed too: the **second `Adapter` conformer** (registered alongside Claude), launching
read-only-first with a discovered session id and an isolated `CODEX_HOME`, its live context %/status
derived by the daemon **tailing the rollout JSONL** and the adapter parsing each line — offline, off a
vendored model table (see [the Codex adapter](04-cards-worktrees-sessions.md#the-codex-adapter) and
[chapter 9](09-design-decisions.md#shipped-feature-history)). These are single forest PRs, not whole axes,
so their rows stay in the roadmap below. An eighth forest PR, **C3 — F1 resume-in-card with a seed**
([plan](../notes/plans/2026-07-01-c3-f1-handoff-resume.md)), has now landed too: the **third and final
live-delivery function**, which resumes a card into a fresh process with clean context — keeping its
session id (a *resume, not a blank restart*) — seeded with an authored handoff/fork context folded
together with its pending inbox, delivered as the resumed session's opening turn (see
[chapter 9](09-design-decisions.md#shipped-feature-history)). With F1/F2/F3 all shipped, the rest of the
forest is the Codex **send-keys wake** (C4) plus the handoff/fork/fan-out **Commands + UI** (D1/D3) that
will *call* this F1 seam — all still design-only until those PRs land. The principle is to design every
change *toward* these axes, never away from them.

## The nine axes

| # | Axis | Slug | One-line goal |
|---|------|------|---------------|
| 1 | **Configurable columns** | `configurable-columns` | Turn the fixed `plan/impl/review` enum into a daemon-owned, ordered, configurable list of columns (data, not an enum). |
| 2 | **Multiple model providers** | `model-providers` | Make adding a coding agent beyond Claude Code a matter of writing one `Adapter` — the **Codex adapter has now shipped** read-only-first, with live rollout-tail telemetry (B1/B2, ch. 9); write access, approvals, and the send-keys wake are the live remainder. |
| 3 | **Deeper agent integration** | `agent-integration` | More agent-facing commands, structured sub-status (an in-card progress tree), and richer Orchestra→agent context injection. |
| 4 | **Non-git cards + search** | `non-git-cards-search` | First-class non-git cards (the `cwd`/`origin`/`access` substrate + freeform/borrowed/scratch cards have **shipped** — ch. 9) plus text search/discovery over cards (the unbuilt remainder). |
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
Columns as data (not enum, axis 1)        ─→ axes 1, 5
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
   new `AgentModel.contextWindow`, from a per-adapter **offline model table**), and report wiring is
   `{files, env, argv}` + trust, not one `--settings` file. The L3 design refines report handling further:
   the daemon owns only the **telemetry transport** (push / rollout-tail / pty-scrape, keyed by the
   capability descriptor), while the **parse** into a `StatusReport` is the **adapter's** own
   (agent-dependent) — so `ReportHelper.map` relocated out of the CLI target into `ClaudeCodeAdapter.parse`
   (✅ **landed** as A2). The whole build is sequenced as a **stacked-PR forest** (A1 capability-descriptor
   freeze ✅ **landed** → A2 telemetry seam ✅ **landed** → B1/B2 Codex adapter + rollout-tail ✅ **landed**,
   in parallel with the trust-ledger and live-delivery tracks) in
   [agent-provider-interface/03-implementation.md](../notes/designs/agent-provider-interface/03-implementation.md).
4. **Keystone — build it first:** the **`additionalContext` seed** (axis 3's 11th `AdapterContext`
   field, plus `SpawnInput.additionalContext` + `restart(_:withContext:)`) is the chokepoint for the
   whole handoff/fork/fan-out/subagent family — *one primitive at four topologies* (see
   [chapter 9](09-design-decisions.md#one-seed-four-topologies) and
   `notes/designs/context-passing-topologies.md`). Still unbuilt; the rest of that family is wiring.
5. **Dependency chains:** axis 1 enables 5 (a review column); axis 2 → 3 → 5/6; axis 4 is used by 8;
   axis 7 feeds 5. The **freeform region shipped standalone**, *not* as an axis-1 lane, so axis 4 no
   longer depends on axis 1 (`notes/designs/configurable-columns/index.md` §status).

## Where Claude-specifics live today

Several seams are currently Claude-Code-shaped and must be generalized as axis 2/3 land — the design
notes call these out explicitly so they aren't deepened by accident:

- the report **parse** (`ClaudeCodeAdapter.parse`, relocated from the CLI by A2) and the hooks wiring
  (`claude-hooks.json`), plus transcript/session discovery in `ClaudeCodeAdapter` (keyed to
  `~/.claude/projects`),
- the control plane (`ControlServer`/`ControlClient`) is raw-fd UDS only, with no `Transport`
  abstraction yet (needed for the phone client),
- `Column` is a fixed Swift enum baked into the model, board layout, `StartIn`, drag-drop, and the
  CLI/MCP `col` schema (axis 1 turns it into data).

## Open design questions

A few decisions are explicitly deferred until the relevant axis is built:

- **Spawn 1:1 enforcement *mechanism*** — enforcing 1:1 worktree↔card (retiring the refcount/shared-
  worktree machinery) is now **decided** (see [chapter 9](09-design-decisions.md#11-worktree--card-ownership));
  what's still open is *how* a spawn on an already-checked-out `repo+branch` is handled: refuse + jump to
  the owning card, or auto-branch a suffixed branch? (`stacked-branches-and-guardian-handoff.md` §1.)
- **Context seed delivery** — **resolved and shipped** (carrier by PR A1, injection by PR C3). The
  **carrier** is a defaulted `AdapterContext.seed` field, frozen on the seam contract by A1
  (`notes/plans/2026-07-01-a1-seam-contract-freeze.md`). The **per-agent injection mechanism** is now
  decided: the seed rides as the resumed session's **opening positional turn** — each adapter appends
  `ctx.seed` as the trailing argv positional (Claude after `--resume`, Codex after `resume <sid>`) — *not*
  `--append-system-prompt` / `AGENTS.md`, and it composes with (never replaces) the hooks `--settings`.
  PR C3 wired it through `OrchestraService.resumeInCard` (see
  [chapter 9](09-design-decisions.md#shipped-feature-history)). (`agent-provider-interface/02-contract.md` §2;
  `context-passing-topologies.md` §9.)
- **Merge-back timing** — **resolved and shipped** (PR C1 then C2): a fork's conclusion rides the durable
  **inbox (F3)** and drains at the parent's **next turn-end** — never a mid-turn interrupt (an explicit
  non-goal); concurrent returns coalesce in the inbox and drain together. The
  [durable inbox + Stop-drain (C1)](09-design-decisions.md#shipped-feature-history) and the
  [F2 wake + merge-watch (C2)](09-design-decisions.md#shipped-feature-history) have both landed: an
  orchestrator card `wait`s on its children, each conclusion coalesces into its inbox and wakes it. The
  Claude wake is `nativeReinvoke` (the background `orchestra wait` process exiting is the wake); the
  Codex **send-keys** wake for an idle non-native card is the last remaining piece (PR C4). Conclusion is
  read from real card state, never `git merge-base`. (`agent-provider-interface/01-design.md` §4;
  `02-contract.md` §Area 4.)
- **Archiving a parent with live forks** — hard-block + override, or warn-and-proceed?
  (`stacked-branches-and-guardian-handoff.md` §7.1.)

Because this manual is regenerated whenever `main` changes (see [chapter 11](11-doc-automation.md)),
these tables will track the roadmap as axes move from design-only to shipped — at which point their rows
should migrate into [chapter 9's shipped history](09-design-decisions.md#shipped-feature-history).
