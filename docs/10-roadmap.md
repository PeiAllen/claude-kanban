# 10. Roadmap

Orchestra is built to grow along **nine extensibility axes**. These axes exist to **widen the core's
seams before they calcify** — the daemon + `OrchestraService` actor + thin clients are sound, so rather
than retrofit each future feature later, every axis shapes an interface that already anticipates the
feature that will plug into it. They were identified by the 2026-06-26 deep code review. Each axis was
worked up as an approved design (a *what* and a *contract*, deepened to implementation + tests when
picked up); that design detail now lives **inline in this chapter** — see [Axis designs](#axis-designs)
below — not in a separate design vault.
**Axis 7 — view/review code on the board — has now fully shipped**, the first whole axis built end
to end (footer diffstat + a read-only in-inspector diff; its row has migrated into
[chapter 9's shipped history](09-design-decisions.md#shipped-feature-history)). The remaining axes still
describe work to pick up, although the non-git card substrate and the connection spine have already landed.

### Current provider and inbox direction

The provider seam now has Claude and Codex adapters. Claude supplies strictly correlated hook observations,
exact same-prompt continuation reactivation, and a narrow provider-native idle repair for hook-silent
Ctrl-C; Codex uses rollout data for metadata and the app server alone for turn state and
provider human need. The app server also owns Codex's thread identity: one fail-closed loaded-thread
snapshot binds a fresh card while the same observer listens for later starts, so rollout/hook metadata
cannot race it. Their normalized
observations reduce into one provider-neutral live state.

The native inbox is deliberately smaller than the retired delivery design. `send` durably queues a local
row. A per-live-session native sender in `CardRuntime` later makes a bounded best-effort request, and
`handedOff` means only that the harness accepted it. Delivery never waits for a displayed status, does not
wake or relaunch a session, does not clear `pendingQuestion`, and does not turn `wait` into a receipt
protocol. Handoff and fork seeds remain authored session context, separate from ordinary inbox rows.

**Deferred:** provider evidence for a delivered/read UI, periodic reminders, the root stalled watchdog,
and possible deprecations of `wait` and `needs-input`.

Separately, **axis 9's connection spine has now landed** — the `Transport`/reconnect seam, the persisted
`Connection` model + a Connections settings pane, the Linux daemon port, and the app-managed SSH tunnel
that runs the Mac board against a remote Linux `orchestrad`. The principle is to design every change
toward these axes, never away from them.

## The nine axes

| # | Axis | Slug | One-line goal |
|---|------|------|---------------|
| 1 | **Configurable columns** | `configurable-columns` | Turn the fixed `plan/impl/review` enum into a daemon-owned, ordered, configurable list of columns (data, not an enum). |
| 2 | **Multiple model providers** | `model-providers` | Make adding a coding agent beyond Claude Code a matter of writing one `Adapter` — the **Codex adapter has now shipped** access-gated (default permissioning, read-only preset per card), with rollout-tail metadata, app-server-only turn and provider-human observation, SessionStart orientation, and a separate native sender peer; it is startable from the UI/CLI through model→adapter routing and `enable-codex`. |
| 3 | **Deeper agent integration** | `agent-integration` | More agent-facing commands, structured sub-status (an in-card progress tree), and richer Orchestra→agent context injection — the delegation **guidance** an agent reads has **shipped** as vendored resources + a shared `AgentGuidance` assembler (D2, ch. 9), packaged on every launch as Claude project skills or Codex `developer_instructions` overrides, and a **column-aware SessionStart orientation** (each agent learns its live column/mode/self-id and is nudged to self-move) has **shipped** on the same hook channel for both agents (ch. 9); structured sub-status + more agent commands remain. |
| 4 | **Non-git cards + search** | `non-git-cards-search` | First-class non-git cards (the `cwd`/`origin`/`access` substrate + freeform/borrowed/scratch cards have **shipped** — ch. 9) plus text search/discovery over cards (the unbuilt remainder). |
| 5 | **Automated PR-review phase** | `pr-review-phase` | A board column that, on entry, runs an agent to address PR review comments + failing checks and loop until clean or escalate. |
| 6 | **Context-clearing continuity** | `context-continuity` | When context fills, the agent saves a handoff and Orchestra launches a fresh agent seeded with it. |
| 7 | **View/review code on the board** ✅ **shipped** | `code-review-on-board` | A diffstat on the card and a read-only in-inspector diff, instead of only "View changes → Zed" — **shipped** (see [chapter 9](09-design-decisions.md#shipped-feature-history)). Inline review comments/approvals remain axis 5. |
| 8 | **Outside-source intake** | `external-intake` | Let external sources (a todo app, webhooks, email) create cards — just another control-plane client calling `spawn`. |
| 9 | **Phone client** | `phone-client` | An iOS client over SSH-forwarded UDS (Tailscale), reusing the shared core/board-model/theme. Its **connection spine has now shipped** — a `Transport` seam + reconnect/backoff, a persisted `Connection`/`ConnectionStore` model + a Connections settings pane, the Linux daemon port, and the app-managed SSH tunnel — built once via its driving case, a **Mac app ↔ remote Linux `orchestrad`** over SSH ([deploy scripts](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box) live; see [chapter 9](09-design-decisions.md#shipped-feature-history)). The iOS app itself is the remaining work, and it inherits that spine. |

## Axis designs

The per-axis design detail below was worked up as an approved *what* + *contract* for each axis (the
2026-06-26 design pass). Axes whose whole design has since shipped are covered in
[chapter 9](09-design-decisions.md#shipped-feature-history); what follows is the design substance for the
axes still carrying unbuilt work, so the planning capital survives inline in this chapter rather than in a
separate vault.

### Axis 1 — Configurable columns

Today's columns are a fixed Swift enum `Column { plan, impl, review }`, baked into `Task.column`, the
board layout, `StartIn`, drag-drop, and the CLI/MCP `col` schema — so changing them (adding a PR-review
stage, splitting Implementation, letting the user name their own workflow) means editing the enum and
recompiling every surface. The design turns columns into **data the daemon owns**: a `ColumnDef` value
type (`id` / `name` / `order` / `startable` / `semantic`) held in an ordered `Config.columns` list
(persisted in `config.json`, already round-tripped through `getConfig`/`setConfig`), and `Task.column`
becomes `Task.columnId: String`. A pure `ColumnRegistry` built over `Config.columns` is the single place
that resolves and validates a column id, lists the startable columns, and supplies display names — both
`OrchestraService.move` (validating a target id) and the app's `BoardModel` (rendering columns + order)
derive from it, so there is no second hardcoded set to drift. `StartIn` collapses into the `startable`
flag, and the Spawn sheet's "start in" picker just lists startable columns.

Two decisions are load-bearing. The migration is a **no-move migration**: the seeded default columns keep
their ids equal to the old enum raw values (`plan`/`impl`/`review`), and `Task`'s decoder falls back from
`columnId` to the legacy `column` string, so an upgrade changes only the field's *type* — no card moves,
the same transparent-decoder trick already used for `AgentModel`. And deleting a non-empty column is
**blocked unless the caller supplies an explicit reassignment target** — never silently strand a card, and
never cascade-archive it. The column-management surface (add/remove/reorder verbs + a Settings editor) is
deliberately deferred; this axis only makes columns data, and the `ColumnDef` shape is chosen so that
surface drops in later without a data change.

`ColumnSemantic { backlog, active, review, other }` is added now even though it is presentationally inert,
because it is the **cross-axis dependency axis 5 keys on**: the `onEnter` column policy that runs a
PR-review agent (see axis 5 below) triggers on `semantic == .review`. A `move` is otherwise pure data
today (no `onEnter` hook), so column transitions stay a *consumer* of existing mechanisms — a context
reset at a boundary is opt-in (`restart + seed`) — until that policy lands.

### Axis 3 — Deeper agent integration (unbuilt remainder)

The keystone of this axis — the `additionalContext` reverse-injection seed — has already shipped as the
`SpawnInput.seed` / `AdapterContext.seed` carriers (see
[chapter 9](09-design-decisions.md#one-seed-four-topologies)). What remains is **roadmap/unbuilt** design
for the richer agent↔Orchestra surface:

- The **`CommandRegistry` single-source refactor** (the foundational prerequisite, below): make the
  registry the one verb definition so the CLI is *generated* from each command's JSON schema instead of a
  hand-written switch in `CLIRunner`, and fold the server-only methods (`models`/`archivedList`/`openInZed`)
  into it — so a new agent-facing verb reaches CLI **and** MCP at once rather than drifting.
- A **structured progress channel**: a `ProgressItem` value type (`id` / `parentId?` /
  `kind` ∈ {subagent, planLayer, step, milestone} / `label` / `state` / `detail?`) forming a tree stored
  on `Task.progress`, upserted by id and kept card-scoped, bounded, and coalesced like the existing
  `StatusReport` snapshot path, rendered as an indented **sub-status tree** in the inspector. It is pushed
  by a **verb, not a model hook**, so it stays provider-agnostic (a skill or tool calls it — works for
  Claude and Codex alike). The worked example is the layered-plan skill reporting each layer plus its
  Explore/Plan subagents as live progress items.
- The remaining **agent-facing verbs** on that same registry: `describe` (read a card's full `Task` back,
  richer than `status`), `note` (attach a bounded freeform annotation), and `link` (record a typed
  parent/child/related relation between cards — which also carries fork lineage via `Task.parentCardId`
  and feeds axis 4's discoverability).

### Axis 4 — Search (the unbuilt remainder)

The non-git-cards half of this axis already shipped — the `cwd`/`origin`/`access` substrate and the
standalone freeform region (see [chapters 4](04-cards-worktrees-sessions.md) and
[9](09-design-decisions.md#shipped-feature-history)). What is left is **search over cards**, still unbuilt:
a pure `TaskSearch.match(tasks, query, includeArchived) -> [Task]` that ranks a substring/fuzzy scan across
card text (title > desc > initialPrompt > repo/branch, extended to notes/progress once axis 3's fields
land), surfaced as a new `find` verb plus a `query` param on `list` (both via the axis-3 registry) and an
app search field over the same. The explicit non-goal keeps it honest: this is a **simple ranked scan over
`tasks.json`**, deliberately not a full-text index engine — the right scale for a personal tool.

### Axis 5 — Automated PR-review phase

Today the Review column means *Allen* reviews, but much of that work is mechanical — address an inline
comment, fix a failing check, rebase. This axis adds a **column-entry automation policy**: `ColumnDef`
gains an `onEnter: ColumnAction` (first action `.prReview`), built on axis 1's `semantic`, and when `move`
lands a card in that column the daemon starts a review loop for it. PR awareness comes through a
**`ForgeProvider` seam** — GitHub via `gh` behind `Proc`, so other forges can follow — that resolves the
card's branch → its PR and fetches unresolved review threads plus failing check runs; `gh` missing or
unauthed degrades with a note, never fabricates state. A **`PRReviewController`** runs the bounded loop per
card: it composes the unresolved comments + failing checks into a task and **steers the card's existing
agent** (preferred — it already has the context) or spawns a fresh reviewer in the same worktree, feeding
the PR context through axis 3's `additionalContext` seed, then re-polls and summarizes into a `PRState` on
the card (checks ✓/✗, unresolved count, phase).

Three decisions define its posture. It is **escalate-only — it never merges or approves**; when checks are
green and threads resolved it marks the card for a human, who keeps the final call. Auto-push is
**bounded, attended, and visible** — per-card opt-in, a cycle cap so it can't thrash push→CI→push, and
every phase change in the Activity feed, the same posture as `exec`. And the reviewer is a **lifecycle
phase of the one card, not a co-tenant on its worktree**: whether the same agent continues into the review
column or a fresh-context successor takes over by ownership transfer, worktree↔card stays 1:1. The axis
depends on axis 1 (the `onEnter` column) and axis 3 (the `additionalContext` feed).

### Axis 6 — Context-clearing continuity (unbuilt remainder)

The core of this axis shipped — the agent-authored handoff artifact and the seeded `restart`/`spawn`
context carriers (see [chapter 9](09-design-decisions.md#shipped-feature-history)). Ordinary inbox rows
remain separate. The one piece still **roadmap/unbuilt** is the **automatic trigger**: an optional `autoContinueCtxPct` threshold
(in `Config`, **default off**) that, when a report's `ctxPct` crosses it, asks the agent to author a
handoff and then performs the seeded restart — bounded by an `autoContinueCount` cap so a session that
immediately refills can't restart-storm, and announced in the Activity feed. If the agent doesn't produce a
handoff within a grace window it stays put — never a blind blank restart, and never a transcript scrape.
The manual path and the seed carriers this rides are already shipped.

### Axis 8 — Outside-source intake

The control plane already lets any MCP client `spawn`, so the design adds only what is needed to let an
external source (a TickTick to-do, a webhook, an email) create a card *safely and idempotently*. On the
daemon side that is one field — an **`ExternalRef { source, id, url? }`** on `SpawnInput` and `Task`, plus
a persisted **`externalIndex`** keyed `"source:id"` — so `spawn` dedupes by it: a re-polled or re-delivered
item returns the existing card rather than a duplicate, and the card carries provenance ("from TickTick",
linking back to the source item).

The load-bearing decision is that everything else — the **`IntakeConnector` / `IntakeMapping` seam** —
runs as an **external process**, not inside the daemon. The connector owns the source's API and its OAuth
tokens, maps each source item to a `SpawnInput` via declarative rules, and calls the existing
`spawn`/`batch-spawn` over MCP/CLI; the daemon only ever sees `spawn` calls, so it keeps its
**no-network-listener, no-credentials** posture. The rejected alternative is a **daemon-hosted poller** —
simpler to configure, but it would give the daemon an outbound network dependency and force it to hold
source credentials, changing exactly the posture that keeps it a local control plane, so it is opt-in at
most and never the default. A source item with **no repo mapping** becomes a **scratch or borrowed card**,
reusing axis 4's already-shipped `cwd`/`scratch`/`access` fields rather than a bespoke card kind.
**TickTick** is the reference connector, with optional done-write-back: it `subscribe`s to the event stream
and marks the source item complete when the card is archived.

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
2. **Near-term standalone fix — ✅ shipped:** **`ControlClient` auto-reconnect** (pulled ahead from
   axis 9) hardens the desktop app today — landed as workstream **B** of the
   [remote-daemon connections work](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box),
   which specified the reconnect/backoff/re-subscribe + `Transport` seam **once**, now shared by the
   phone client *and* the [Mac↔remote-Linux-daemon connection](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box)
   (SSH-tunnel blips need it either way); see [chapter 9](09-design-decisions.md#shipped-feature-history).
3. **First multi-provider consumer:** build a **`CodexAdapter`** (axis 2) once the adapter report-
   mapping seam lands. Studying Codex CLI forced three design points now baked into the model-providers
   design: session ids are **two-mode** (Claude seeds an id; Codex can't, so its app server exposes the
   thread after launch), `ctxPct` is **adapter-derived** where the agent doesn't report it (compute from tokens ÷ a
   new `AgentModel.contextWindow`, from a per-adapter **offline model table**), and report wiring is
   `{files, env, argv}` + trust, not one `--settings` file. The L3 design refines report handling further:
   the daemon owns only the **metadata transport** (push / rollout-tail / pty-scrape, keyed by the
   capability descriptor), while the **parse** into a `StatusReport` is the **adapter's** own
   (agent-dependent) — so `ReportHelper.map` relocated out of the CLI target into `ClaudeCodeAdapter.parse`
   (✅ **landed** as A2). The whole build is sequenced as a **stacked-PR forest** (A1 capability-descriptor
   freeze ✅ **landed** → A2 telemetry seam ✅ **landed** → B1/B2 Codex adapter + rollout-tail ✅ **landed**,
   in parallel with the trust-ledger (✅ **landed** as T1/T2) and native-inbox work).
4. **Keystone — now shipped:** the **context seed** (the design's `additionalContext`) is the chokepoint
   for the whole handoff/fork/fan-out/subagent family — *one primitive at four topologies* (see
   [chapter 9](09-design-decisions.md#one-seed-four-topologies)). As-built it is **two** defaulted carriers, both frozen
   on the seam contract by A1: `AdapterContext.seed` (the *resume-only* carrier, injected by C3's
   `resumeInCard` as the opening turn) and `SpawnInput.seed` (the *new-card* carrier, folded ahead of the
   prompt by D3's `spawn`/`batch-spawn`). With both seed carriers landed, the family is wired,
   and the *guidance auto-injection* on launch has since landed too — the `DelegationDocs` loader (D2) is now
   bound to each adapter's `prepareToLaunch` (skill-injection, ch. 9), independent of the seed carriers.
5. **Dependency chains:** axis 1 enables 5 (a review column); axis 2 → 3 → 5/6; axis 4 is used by 8;
   axis 7 feeds 5. The **freeform region shipped standalone**, *not* as an axis-1 lane, so axis 4 no
   longer depends on axis 1 (see the [axis 1 design](#axis-1--configurable-columns) above).

## Where Claude-specifics live today

Several seams are currently Claude-Code-shaped and must be generalized as axis 2/3 land — the design
notes call these out explicitly so they aren't deepened by accident:

- the report **parse** (`ClaudeCodeAdapter.parse`, relocated from the CLI by A2) and the hooks wiring
  (`claude-hooks.json`), plus transcript/session discovery in `ClaudeCodeAdapter` (keyed to
  `~/.claude/projects`),
- ~~the control plane is raw-fd UDS only with no `Transport` abstraction, and `UDSSocket` is
  Darwin-only~~ — ✅ **resolved.** `ControlClient` now owns a `Transport` seam (reconnect/backoff + an
  observable `ConnectionState`), and `UDSSocket`/`Config`/`DaemonLifecycle` are ported to Glibc/musl
  (`MSG_NOSIGNAL` send-flag, XDG data dir, macOS-gated launchd) — the shared connection spine for the
  phone client and the [Mac↔remote-Linux-daemon connection](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box)
  (see [chapter 9](09-design-decisions.md#shipped-feature-history)),
- `Column` is a fixed Swift enum baked into the model, board layout, `StartIn`, drag-drop, and the
  CLI/MCP `col` schema (axis 1 turns it into data).

## Open design questions

A few decisions are explicitly deferred until the relevant axis is built:

- **Spawn 1:1 enforcement *mechanism*** — enforcing 1:1 worktree↔card (retiring the refcount/shared-
  worktree machinery) is now **decided** (see [chapter 9](09-design-decisions.md#11-worktree--card-ownership));
  what's still open is *how* a spawn on an already-checked-out `repo+branch` is handled: refuse + jump to
  the owning card, or auto-branch a suffixed branch?
- **Context seed injection** — **resolved and shipped** (carriers by PRs A1/D3, injection by PRs C3/D3). The
  **carrier** is a defaulted `AdapterContext.seed` field, frozen on the seam contract by A1. The
  **per-agent injection mechanism** is now
  decided: on a *resume* the seed rides as the resumed session's **opening positional turn** — each adapter
  appends `ctx.seed` as the trailing argv positional (Claude after `--resume`, Codex after `resume <sid>`) —
  *not* `--append-system-prompt` / `AGENTS.md`, and it composes with (never replaces) the hooks
  `--settings`. PR C3 wired the resume path through `OrchestraService.resumeInCard`, and PR D3 added the
  parallel **new-card** carrier — a defaulted `SpawnInput.seed` folded ahead of the prompt by
  `spawn`/`batch-spawn` — so Fork and Fan-out seed a fresh card the same way (see
  [chapter 9](09-design-decisions.md#shipped-feature-history)).
- **Merge-back timing** — a card uses `wait` only to subscribe to a child conclusion, read from lifecycle
  rather than `git merge-base`. A result message is a separate ordinary inbox row: it is locally queued,
  then the live native provider may accept it. That path makes no model-read or scheduling promise, and it
  does not change the conclusion subscription.
- **Archiving a parent with live forks** — hard-block + override, or warn-and-proceed?

Because this manual is regenerated whenever `main` changes (see [chapter 11](11-doc-automation.md)),
these tables will track the roadmap as axes move from design-only to shipped — at which point their rows
should migrate into [chapter 9's shipped history](09-design-decisions.md#shipped-feature-history).
