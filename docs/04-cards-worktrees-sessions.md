# 4. Cards, worktrees & sessions

This chapter covers the machinery that turns a `Task` into a running agent: git worktree management,
the tmux session topology, the agent adapter protocol and the Claude Code adapter, the three-layer
read-only barrier, process and path safety, and crash/reboot recovery. These live under
`Sources/OrchestraCore/` (`WorktreeManager`, `SessionManager`, `Agents/`, `Proc`, `PathResolver`,
`OrchestraService+Recovery`).

## Worktrees

Each `.worktree` card owns **exactly one git worktree** — a 1:1 relationship (see
[Design decisions](09-design-decisions.md#11-worktree-card-ownership)). `WorktreeManager` computes the
path as `~/.orchestra/worktrees/<repoName>/<branch>` and creates it idempotently:

1. resolve and **allowlist-check** the repo (`PathResolver`),
2. if the worktree dir already exists, return it (idempotent),
3. otherwise `git worktree add <wt> <branch>` if the branch exists, or `git worktree add -b <branch>
   <wt>` for a new branch,
4. if git reports the branch is *already checked out / already used by a worktree*, throw
   `branchInUse` — because git forbids the same branch in two worktrees.

**Removal** (on archive) runs `git worktree remove`, but **guards a dirty tree**: it refuses unless
forced, and treats a failed `git status` query as "dirty" (fail-safe), so uncommitted work is never
silently deleted. The **branch is kept** after removal so the work can be recovered — which is exactly
what [`reopen`](#recovery-resume-and-restart) does: it re-`ensure`s the worktree from that surviving
branch and resumes the agent.

Borrowed and scratch cards have **no worktree**: a borrowed card's `cwd` is the directory you chose; a
scratch card's `cwd` is a freshly `mkdir`'d `~/.orchestra/scratch/<id>`.

## Sessions (tmux)

`SessionManager` gives each card one tmux session named `orchestra-<uuid>` on the `orchestra` tmux
socket. Inside it:

- **window 0 is `agent`** — the Claude Code process,
- **`shell-1`, `shell-2`, …** are on-demand shell windows in the same `cwd`.

### The grouped-view topology

A subtlety: multiple SwiftTerm clients can't share one tmux session, because tmux forces every client
onto the same *active window* — opening a shell would yank the agent terminal away. So Orchestra uses
**grouped "view" sessions**: the base session (`orchestra-<id>`) holds the shared window list, and each
client attaches to its own view session `<base>__<window>` pinned to a single window. The agent and
each shell therefore stay independently viewable.

`SessionManager.ensure(task, argv)` creates the session running the agent argv with two environment
variables injected — `ORCHESTRA_TASK_ID` and `ORCHESTRA_SOCK` — which is exactly what the `_report`
helper needs to find the daemon and attribute its reports. Other operations: `isAlive` (a `has-session`
check — the liveness authority), `newShellWindow`, `closeShellWindow` (refuses to touch the `agent`
window; also kills the window's view session), `capture` (`capture-pane`, the status fallback),
`sendKeys` (literal text then Enter; `--` guards messages starting with `-`), and `kill`.

## Agent adapters

The agent provider is abstracted behind the **`Adapter`** protocol so Orchestra isn't wedded to Claude
Code (the multi-provider direction is [Roadmap axis 2](10-roadmap.md), deepened into the
[agent-provider interface](../notes/designs/agent-provider-interface/index.md) design — a per-agent
**capability descriptor** the core degrades on, plus a Codex adapter as the second conformer). The
**seam-contract root of that design has landed** — PR A1
([plan](../notes/plans/2026-07-01-a1-seam-contract-freeze.md)) froze the complete capability descriptor
and moved core onto it, **PR A2** ([plan](../notes/plans/2026-07-01-a2-telemetry-source-seam.md))
added the adapter's own **`parse`** (below), and **PRs B1–B2** have since landed the **Codex adapter**
as the second conformer — its launch/session/trust ([plan](../notes/plans/2026-07-01-b1-codex-adapter.md))
and its rollout-tail telemetry ([plan](../notes/plans/2026-07-01-b2-codex-rollout-tail.md); see
[the Codex adapter](#the-codex-adapter), below) — and **PR C3**
([plan](../notes/plans/2026-07-01-c3-f1-handoff-resume.md)) has landed **F1 resume-in-card**: the `seed`
now rides `resume` as the session's opening positional turn (see the resume argv under
[the Claude Code adapter](#the-claude-code-adapter), below), and **PR C4**
([plan](../notes/plans/2026-07-01-c4-codex-sendkeys-wake.md)) has landed the **Codex send-keys wake** (the
`.sendKeys` `wakeTransport`; see [the Codex adapter](#the-codex-adapter) and
[chapter 9](09-design-decisions.md#shipped-feature-history)); **PR D1**
([plan](../notes/plans/2026-07-01-d1-mcp-delegation-tools.md)) has since surfaced that F1 seam as the
[`handoff` Command](05-command-reference.md#registry-commands) (MCP tool + CLI verb), and **PR D3**
([plan](../notes/plans/2026-07-01-d3-ui-cli-actions.md)) has since landed the new-card **Fork/Fan-out**
board/CLI start-actions (a `spawn`/`batch-spawn` carrying a new `SpawnInput.seed`) plus the Handoff/Send
card actions — completing the agent-provider forest. An
adapter declares its `id`,
`name`, `icon`, `bin`, `models()`, and its `capabilities`, and builds argv for two operations:

- **`start(ctx)`** — argv for a fresh launch,
- **`resume(ctx)`** — argv to reattach an existing session (or `nil` if unsupported),

plus `newSessionId()`, `sessionInfo(...)`, `prepareToLaunch(ctx)` (side-effecting prep), and
**`parse(_:)`** — the adapter's own conversion of one unit of raw telemetry into a `StatusReport`
(relocated into the adapter by A2; see [the report channel](06-clients-cli-mcp.md#the-hooks--_report-channel)).
The `AdapterContext` it receives carries `cwd`, `repo`, `model`, `startIn`, `sessionId`, `prompt`, `name`,
the agent-agnostic `orchestraBin` (the `orchestra` path the agent's hooks call — each adapter renders its
own hook file from it in `prepareToLaunch`), the card's `access`, `trustCwd` (the core's `resolveTrust` decision, `.trusted`
→ `true` — see [trust](#the-claude-code-adapter) below), and `seed` — authored system-level context (a handoff / fork /
`additionalContext` summary) whose *carrier* is frozen here (defaulted `nil`) and whose per-agent
*injection* has now shipped (PR C3): each adapter appends `ctx.seed` as the resumed session's opening
positional turn (see the resume argv under [the Claude Code adapter](#the-claude-code-adapter) below).
`AgentRegistry`
holds the adapters (default: `[ClaudeCodeAdapter(), CodexAdapter()]`) and looks one up by id — or by
model: **`adapter(forModel:)`** returns the enabled adapter whose catalog contains a given model id
(catalog-driven, never sniffing the id string; first match wins since ids don't overlap).

**Making Codex startable — model→adapter routing.** The Codex backend (adapter, models, telemetry, trust,
resume/wake) shipped in B1–B2, but was for a while unreachable from the UI: the model list surfaced only
the default agent's catalog and `spawn` never received an agent. The [enable-codex](09-design-decisions.md#shipped-feature-history)
change wired the reachability. `OrchestraService.models(nil)` now returns the **union** of every enabled
adapter's models (default agent first), a new `agents()` exposes the per-agent grouping
(`AgentInfo` = `id`/`name`/`icon` + catalog) behind the [`agents` RPC](05-command-reference.md#server-only-built-in-methods),
and `spawn` resolves its adapter in three steps: an explicit **`agentId`** wins → else the adapter that
**owns the chosen model** (`adapter(forModel:)`, so the app's flat model-only pick lands on Codex) → else
the **configured default agent**. The [Spawn sheet](07-app-ui.md#the-spawn-sheet)'s agent picker and the
`orchestra spawn --agent` param (parsing the previously-unwired `SpawnInput.agentId`) are the surfaces
this backs.

**Capabilities — core degrades on the descriptor, never on identity.** Every adapter must supply a frozen
**`AgentCapabilities`** value (a required protocol member with *no* default, so a new adapter can't
silently inherit Claude's shape). It is seven enum-typed flags — `sessionId ∈ {seeded, discovered}`,
`telemetry ∈ {hooksPush, fileTail, ptyScrape}`, `contextUsage ∈ {percent, tokens, none}`,
`wakeTransport ∈ {nativeReinvoke, controlChannel, sendKeys, relaunch}`, `inboxDrain ∈ {stopHook,
sessionSeed, none}`, `readOnlyEnforcement ∈ {sandboxed, toolGatedOnly, orchestraSandboxed}`, and
`authMode ∈ {subscription, apiKey}` — with **every variant spelling frozen now** (A1), including cases no
adapter exercises yet, so later PRs implement behavior behind a shape that can't drift. Claude advertises
`seeded / hooksPush / percent / nativeReinvoke / stopHook / sandboxed / subscription` — the
`subscription` `authMode` is now read by the [authMode soft-warn](09-design-decisions.md#authmode-advise-on-fan-out-never-cap)
to advise (never cap) on heavy fan-out, the `stopHook` `inboxDrain` is now *realized* by the C1
[F3 Stop-drain](09-design-decisions.md#shipped-feature-history) (the Claude Stop hook drains the durable
[inbox](03-data-model.md#the-inbox-store-f3) into the agent at its turn-end), and the `nativeReinvoke`
`wakeTransport` is now read by the C2 [F2 wake / merge-watch](09-design-decisions.md#shipped-feature-history).
For Claude that transport has **two** mechanisms, chosen by whether a wait is live: a card watching children
rides its background [`orchestra wait`](05-command-reference.md#notes-on-key-commands) process exiting (the
harness re-invokes it in-session), while a genuinely idle `.waiting` card with **no** live wait is woken by
[resume-seed](09-design-decisions.md#shipped-feature-history) — a `claude --resume` relaunch with the pending
inbox folded into its opening turn (the `send-wakes-idle-card` fix). Core reads this
descriptor instead of branching on `agentId`: session-seeding switches on `capabilities.sessionId` (a
`.seeded` agent like Claude mints its id pre-launch via `newSessionId()`; a `.discovered` agent is left
unseeded to read its id back from its own output post-launch), and `isResumable` asks the adapter's
`sessionInfo` for a state path keyed on that capability rather than assuming a `~/.claude` transcript
exists. Claude's behavior is byte-for-byte unchanged by this gating. The now-shipped
[Codex adapter](#the-codex-adapter) advertises a different frozen set — `discovered / fileTail / tokens /
sendKeys / sessionSeed / sandboxed / subscription` — and core routes on those flags alone: `.discovered`
leaves its session unseeded, `.fileTail` puts it on the rollout-tail transport (never the push endpoint),
`tokens` `contextUsage` drives the compute-ctxPct-from-a-model-table path below, and the `sendKeys`
`wakeTransport` is now realized by the C4 [detect-and-defer wake](09-design-decisions.md#shipped-feature-history)
(an idle Codex card is woken by a fixed content-free TUI nudge, gated on an idle, empty composer read
just-in-time from `capture-pane`).

### The Claude Code adapter

`ClaudeCodeAdapter` (`id = "claude-code"`, `bin = "claude"`) catalogs the available models — Opus 4.8,
Sonnet 4.6, Haiku 4.5, Opus 4.7 — and assembles the `claude` command line:

- **start**: `claude [--model <id>] [--permission-mode auto for plan] [read-only flags] [--session-id
  <uuid>] --settings <one file> [--name <title>] [<prompt>]`. The session id is
  *seeded* at spawn so Orchestra knows it before the agent reports.
- **resume**: `claude --resume <sid> --settings <one file> [--name] [--model] [read-only flags] [<seed>]`
  — no `--session-id`, no prompt re-handed; when a handoff/fork **seed** is present (F1, PR C3) it rides as
  the trailing positional opening turn, otherwise nothing follows and the argv is byte-identical to before.

  Both paths emit **exactly one `--settings`**. A card with no settings overlays uses the shared managed
  hooks file (`Config.hooksPath`, rendered by the adapter in `prepareToLaunch`) directly; a card that
  contributes overlays (read-only enforcement today — see [the read-only
  barrier](#the-read-only-barrier)) gets a per-card file that `SettingsComposer` deep-merges from the hooks
  base plus those overlays. Claude Code applies multiple `--settings` as **last-file-wins (full replacement,
  not deep-merge)**, so a *second* `--settings` would silently drop the managed statusLine + telemetry hooks
  — the merge-into-one invariant is the fix (befad61), and `settingsOverlays(_:)` is the single seam any
  future per-card setting appends to.

**F1 resume-in-card & the seed** (PR C3): `OrchestraService.resumeInCard(_:seed:)` reloads a card into a
fresh process with **clean context while keeping its session id** — a *resume, not a blank `restart`*, so the
transcript carries forward and the seed only adds the new instruction. It **drains the card's inbox first**,
folds it with the authored handoff/fork context via `HandoffSeed.fold(handoff:inbox:)` (handoff first, then
the inbox in FIFO order under the *same* channel-neutral provenance header the Claude Stop-drain uses —
`StopDrain.inboxHeader`, `[k/N]`-numbered when batched — so a Codex card draining via the seed gets the
identical framing a Claude card gets via the hook; the header rides only the inbox portion, so a pure
handoff/fork seed is unchanged; bounded to the 10 000-char live-delivery limit), and threads the result onto a
defaulted `seed:` param of `resume` → `ctx.seed`, which the adapter appends as the positional turn above.
Draining before resume matters most for a `.sessionSeed` agent (Codex has no Stop hook) whose queued
messages can *only* ride the seed; for Claude it also prevents a later Stop-drain double-delivering them.
`resumeInCard` is the seam the [`handoff` Command](05-command-reference.md#registry-commands) (PR D1, MCP
tool + CLI verb) calls; forks instead `spawn` a new card with a `SpawnInput.seed` (a *new-card* seed
distinct from this resume-only `ctx.seed`; [chapter 9](09-design-decisions.md#shipped-feature-history)).
The D3 Handoff/Fork buttons that also drove these seams were later removed (the *agent-buttons
simplification*), leaving the natural-language → MCP path. (See
[One seed, four topologies](09-design-decisions.md#one-seed-four-topologies).)

**Trust — apply the core's decision** (`prepareToLaunch`): Claude prompts for directory trust on first
use of a path, which would block an autonomous agent. **The adapter does not decide trust** — the core
does, provider-agnostically, in [`OrchestraService.resolveTrust`](09-design-decisions.md#trust-boundaries-allowlist-for-worktrees-sandbox-for-the-rest)
(PR T1), and rides the `.trusted`/`.needsGrant` result onto the launch as the `AdapterContext.trustCwd`
bool. `prepareToLaunch` only **applies** that flag (`ClaudeTrust.apply(trusted:cwd:)`) into Claude's
native per-directory trust and **never reads the `TrustLedger`**:

- **`trustCwd == true`** — pre-accept the trust dialog by merging `hasTrustDialogAccepted` for the cwd
  into `~/.claude.json` (creating the file if absent, preserving every other key, and bailing without
  writing if the file is present-but-corrupt so a transient read can't clobber it; no-op when already
  trusted). This covers a **worktree** (registering its repo to run agents *is* the trust act, so core
  records the repo and trusts the tree), a **scratch** dir Orchestra made and owns, and a **borrowed**
  dir a human has already granted.
- **`trustCwd == false`** — a no-op: the card is left untrusted, runs **sandboxed** (writes blocked),
  and Claude's own prompt still applies. This is a `needsGrant` borrowed dir (or a scratch dir a foreign
  repo was cloned into — `resolveTrust` demotes it once a `.git` appears); the human fills the gap
  through the [`trust` grant surfaces](05-command-reference.md#registry-commands) (PR T2), never the
  agent. The Codex adapter applies the same `ctx.trustCwd` into its own `config.toml` `trust_level`
  identically (see [the Codex adapter](#the-codex-adapter)).

**Delegation guidance — materialize the skill** (`prepareToLaunch`, also): as a second best-effort side
effect (after trust and any read-only settings), the adapter writes the vendored Claude **delegation skill**
to `<cwd>/.claude/skills/orchestra-delegation/SKILL.md` — the per-card project-skill location Claude Code
discovers — via `DelegationDocs.install(agentId: id, at:)`. This delivers the *when to hand off / fork /
fan-out / wait* guidance ([PR D2](09-design-decisions.md#shipped-feature-history)) to **every** launched
card (independent of `ctx.seed`), with **no `~/.claude` global install**; `.claude/` is gitignore-conventional
so the tracked worktree stays clean. The step is keyed on the adapter's own `id` (so there is no `if claude`
branch — Codex writes its own variant to a different path), **never throws** into the launch path (absent
resource or any FS failure → no-op), and is **idempotent** — a re-launch atomically overwrites the same
managed file. It changes no `start`/`resume` argv (skill-injection PR; [chapter 9](09-design-decisions.md#shipped-feature-history)).

**Transcript discovery**: Claude stores transcripts at `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`
(slug = the absolute cwd with `/` → `-`). Orchestra computes this path directly for tracked sessions,
with a newest-matching-`.jsonl` fallback used only when no id was tracked.

**Telemetry parse** (`parse(_:)`): because Claude's telemetry is `hooksPush`, the adapter owns the
conversion of each pushed hook event into a `StatusReport`. `ClaudeCodeAdapter.parse` takes a
`RawTelemetry.hooksPush(kind:payload:)` and switches on the event kind (`statusline` / `session` /
`prompt` / `tool` / `notify` / `sessionend`) exactly as the CLI's former `ReportHelper.map` did — this
logic was **relocated verbatim** out of the `orchestra` CLI target by [PR A2](#agent-adapters) so the
transport/parse boundary is per-adapter, while Claude telemetry stays byte-identical. A non-`hooksPush`
raw (e.g. a `fileTail` line) returns `nil` — Claude has no tail transport. See
[the report channel](06-clients-cli-mcp.md#the-hooks--_report-channel) for where the transport calls it.

### The Codex adapter

`CodexAdapter` (`id = "codex"`, `bin = "codex"`) is the **second conformer** — the first proof the seam is
provider-agnostic — registered in the default `AgentRegistry` alongside Claude (PRs **B1–B2**;
`notes/plans/2026-07-01-b2-codex-rollout-tail.md`). It differs from Claude on every capability axis, and
core handles the difference purely through the descriptor:

- **Access-gated launch.** Like Claude, Codex honors the card's `access`: a **default (read-write)**
  card launches with **Codex's own default permissioning** (no `-s`/`-a` clamp), and only a
  **read-only** card applies Codex's read-only preset `-s read-only -a never` (`accessFlags`). `-s
  read-only` selects Codex's own OS-sandboxed read-only mode; `-a never` disables approvals. `resume`
  (`codex resume <sid> [-s read-only -a never] [-m <model>] [<seed>]`) also appends the F1 `seed` as a
  trailing positional turn when present (PR C3) — and because Codex has **no Stop hook**
  (`inboxDrain == .sessionSeed`), this folded seed is the *only* channel its queued inbox messages ride
  (see [the resume argv](#the-claude-code-adapter) above).
- **Discovered session id + rollout path.** Codex can't be handed a session id, so `newSessionId()`
  returns `nil` (`.discovered`, not Claude's `.seeded --session-id`); `sessionInfo`/`discover()` instead
  read the id back by finding the newest `$CODEX_HOME/sessions/**/rollout-<ts>-<uuid>.jsonl` (the uuid is
  the filename tail). That rollout file is both the session identity and the telemetry source below.
- **`CODEX_HOME` isolation + trust.** The home is pinned via the adapter's `env["CODEX_HOME"]` (B1 also
  wired `Adapter.env` into the tmux launch — one `-e KEY=VALUE` per entry; Claude stays byte-identical);
  `prepareToLaunch` creates it and then applies the core's trust decision by appending
  `[projects."<cwd>"].trust_level = "trusted"` to `config.toml` (idempotent, non-clobbering). Like Claude,
  the adapter **applies** `ctx.trustCwd` and never reads the `TrustLedger` itself.
- **Delegation guidance — materialize `AGENTS.md`.** As a third best-effort step, `prepareToLaunch` writes
  the vendored Codex **delegation `AGENTS.md`** variant to `<CODEX_HOME>/AGENTS.md` via the same
  `DelegationDocs.install(agentId: id, at:)` the Claude adapter uses (keyed on `id`, so no `if codex`
  branch). Because the isolated `CODEX_HOME` is the **global (top) level** of Codex's `AGENTS.md`
  precedence — merged *above* any project `AGENTS.md` — and Orchestra owns it, this delivers the guidance
  to every Codex card **without clobbering the user's own project `AGENTS.md`** (one file per directory) and
  **without touching the worktree** cwd. Best-effort (never throws), idempotent, and argv/`env`-preserving
  (skill-injection PR; [chapter 9](09-design-decisions.md#shipped-feature-history)).
- **SessionStart orientation — render + install the parity hooks file.** As a fourth best-effort step,
  `prepareToLaunch` renders the Codex hooks file (`HooksRenderer.renderCodex`, baking `--agent codex`) and
  installs it into `<CODEX_HOME>/hooks.json` via `CodexHooks.install(to:)`, giving a Codex card a
  **Claude-parity SessionStart hook** that injects the card's column/mode/self-id
  [orientation](06-clients-cli-mcp.md#the-hooks--_report-channel) (via `_report --event session`) — the
  inbound counterpart to Claude's SessionStart hook. It **never clobbers a foreign user `hooks.json`**
  (`CodexHooks.installIfSafe` writes only when the file is absent or already Orchestra's, keyed on the
  `_report --event session` sentinel), is **orientation-only** (Codex's `parse` returns `nil` for the push —
  telemetry stays the rollout tail below), and is best-effort/argv-preserving
  (column-aware-orientation PR; [chapter 9](09-design-decisions.md#shipped-feature-history)).
- **Offline model table.** `models()` loads a **vendored** `Resources/codex-models.json` (`gpt-5.3-codex` /
  `gpt-5.5` = 272 000-token window), `.copy`-bundled so the app stays fully offline. This
  table is the **`ctxPct` denominator** for the telemetry below — the context percentage is *derived*
  (tokens ÷ window), because the Codex TUI reports no percentage of its own.

**Telemetry parse + the rollout tailer** (`parse(_:)` + `RolloutTailer` + `pollTelemetry`, PR **B2**).
Codex's telemetry capability is `fileTail`, not `hooksPush`: the agent's TUI emits no push events, but it
appends a JSONL **rollout** file, so the *daemon tails the file* and the *adapter parses each line* —
the same `adapter.parse` seam A2 drew, reached from a different transport. The two halves stay strictly
separated (the tailer never inspects JSON; the parse never touches files):

- **Transport — `RolloutTailer`** (`RolloutTailer.swift`, a `public actor`): tracks a **per-card byte
  offset** into the rollout file and, on each poll, returns only the **newline-terminated** lines appended
  since the last tick. A trailing partial line (a poll landing mid-write) is held until completed; a file
  shorter than the stored offset (rotation/truncation) resets the cursor to 0; `forget(cardId)` drops a
  cursor on death/archive. It owns nothing Codex-specific — the only things crossing the seam are a
  `String` line in and a `StatusReport?` out.
- **Parse — `CodexAdapter.parse(.fileTail(line:))`**: converts one rollout line into a `StatusReport`,
  and is **rename-tolerant** because Codex's rollout schema drifts — it normalizes both the top-level and
  `payload.type` (lower-cased, `_`-stripped) and matches on substrings, so `TaskComplete` /
  `turn_complete` / `TurnComplete` all mean *idle* (`status: .waiting`), and token totals read from a
  nested `total_token_usage.total_tokens` **or** a flat `total_tokens`/`tokens`. A `token_count` line
  yields `ctxPct` (tokens ÷ the **offline** model window above, never the rollout's own reported window)
  plus `modelId`; a turn/task start or a mid-turn `function_call` → `.running` (with a coarse
  `desc: "Running <name>"`); anything unrecognized (including `session_meta`) or non-JSON → `nil`
  (dropped). `seq` is the line's RFC3339 `timestamp` in microseconds since epoch (monotonic in file
  order), so a duplicate or out-of-order line loses to the freshest snapshot at
  [`report`'s seq-gate](06-clients-cli-mcp.md#the-hooks--_report-channel).
- **Driver — `OrchestraService.pollTelemetry()`**: one tick per card, called from the daemon's existing
  **2-second poll loop** next to `reconcileLiveness`. For every live card whose
  `capabilities.telemetry == .fileTail` it resolves the rollout path via `sessionInfo`, feeds each new
  line through `adapter.parse` into the seq-gated `report`, and merges the result onto the card — so a
  Codex card shows live context %, running/idle status, and model, fully offline. Claude (`hooksPush`) is
  never tailed, so its push path stays byte-identical.

**Send-keys wake** (`CodexComposer` + `OrchestraService.sendKeysWake`, PR **C4**;
`notes/plans/2026-07-01-c4-codex-sendkeys-wake.md`). Because Codex advertises `wakeTransport == .sendKeys`
(no `nativeReinvoke` push, no Stop hook), [F2 wake](09-design-decisions.md#shipped-feature-history) can't
just ride a background process exiting — an idle Codex card is instead woken by a **fixed, content-free TUI
nudge** (`sendKeysWakeNudge`, `"Please continue."`) typed into its composer. The nudge only *starts a turn*;
the inbox payload never rides the keystroke — it arrives via the `.sessionSeed` drain on resume (F3/C3). It
is **detect-and-defer**: `sendKeysWake` reads the agent pane just-in-time via `capture` (`capture-pane`) and
asks the adapter's `canNudge(pane:)` gate — for Codex, the pure `CodexComposer` heuristic — whether the TUI
is **idle and composer-empty**; a draft, an in-flight turn, an unparseable pane, or a dead session all
*defer* (drop the nudge, leave the inbox durable for a later event-driven wake). No retry timer (that would
risk the F3 inject cap); focus is not a gate. `CodexComposer` is a pure, isolated heuristic — its prompt
markers, empty-composer placeholders, and "working" cues are the only Codex-specific knobs and the documented
place to tune when the TUI drifts. It is reached only through `CodexAdapter.canNudge(pane:)` (the defaulted
`Adapter.canNudge`, which returns `false` for every non-send-keys agent), so core's generic wake never names
a Codex type; keyed on the `.sendKeys` transport, never `agentId`; see
[chapter 9](09-design-decisions.md#shipped-feature-history).

## The read-only barrier

A read-only card (`access = .readOnly`) is enforced by **three independent layers**, because no single
one is airtight (`Agents/ReadOnlyLaunch.swift`):

1. **Edit tools denied** — `--disallowedTools Edit Write MultiEdit NotebookEdit` removes the write tools
   from the agent's context entirely.
2. **OS sandbox write-block** — a settings overlay sets `sandbox.filesystem.denyWrite` on the
   `cwd` (+ git dir), `allowUnsandboxedCommands:false` (so `dangerouslyDisableSandbox` is a no-op), and
   `failIfUnavailable:true` (fail closed if the sandbox is unavailable). This kills every *sandboxable*
   Bash write — `sed -i`, `>`, `python -c 'open(...,"w")'` — at the kernel level. This overlay
   (`ReadOnlyLaunch.settingsObject`, permissions/autoMode/sandbox only — no statusLine or hooks) is
   **deep-merged onto the managed hooks base** by `SettingsComposer` into the single `--settings` file the
   card launches with (see [the adapter's argv](#the-claude-code-adapter)); it is **not** passed as a
   separate `--settings`, because Claude Code's multiple `--settings` are last-file-wins and a second file
   would clobber the statusLine + telemetry hooks (befad61).
3. **Auto-mode classifier policy** — `autoMode.hard_deny` carries a semantic "deny ANY command that
   modifies the filesystem or git/repo/system state" policy. This is the layer that catches commands
   the sandbox can't reach (anything in the user's `sandbox.excludedCommands`, e.g. `git`). It judges
   mutation *semantically* rather than via a deny-list — so `git log`/`git diff` are allowed while `git
   commit`/`git config`/`git checkout` are denied — and defaults to deny on ambiguity.

The deliberate choice here (recorded in code and in the PR1 plan) was to use the classifier rather than
a brittle command deny-list: a deny-list rots as the ecosystem changes and is trivially evaded
(`git -C`, env prefixes, `sh -c`). Layer 3 is best-effort (an LLM judge, not adversary-proof); the only
hard guarantee is the OS sandbox of layer 2, with a full process-level jail deferred. The same recipe
powers the [`inspect` command](05-command-reference.md) — a throwaway read-only agent in a card's
worktree — except `inspect` runs *without* Orchestra hooks so it stays untracked (it uses
`ReadOnlyLaunch.settingsJSON` directly, intentionally hooks-free), whereas a read-only tracked card
composes those same read-only settings *onto* the hooks base so it keeps its statusLine + telemetry and
is a tracked citizen of the board.

This three-layer recipe is Claude-Code-specific; the [agent-provider interface](../notes/designs/agent-provider-interface/index.md)
design (Roadmap axis 2) generalizes it into a provider-agnostic **`readOnlyEnforcement` capability**
(`∈ {sandboxed, toolGatedOnly, orchestraSandboxed}` — the enum spelling is now frozen on the shipped seam
contract by A1, though core doesn't yet branch on it), of which this Claude barrier is the fully-enforced
`sandboxed` case — so Orchestra never advertises a read-only card an adapter can't actually enforce
(e.g. Codex maps to its native `--sandbox read-only -a never`).

## Process and path safety

- **`Proc`** runs every subprocess from an **argv array**, never an interpolated shell string. It
  resolves `argv[0]` on `PATH` via `/usr/bin/env`, **augments `PATH`** with the common CLI locations
  (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, …) so tools resolve even under a launchd/
  Finder-minimal environment, and **forces a UTF-8 locale** when none is set (without it tmux and
  Claude Code's renderer downconvert multibyte glyphs to `_`). Pipes are drained event-driven (not with
  blocking reader threads, which under concurrency starved the GCD pool and caused false timeouts), and
  timeouts escalate SIGTERM → SIGKILL after 2 s.
- **`PathResolver`** is the security boundary. It canonicalizes a path (expanding `~`, resolving the
  deepest existing ancestor via `realpath(3)`, then lexically collapsing any non-existent tail) so a
  symlink or a `..` in a branch name can't escape, then checks it is a **component-wise prefix** of an
  allowed root (so `/home` doesn't match `/home2/…`). Worktree cards must pass this check; borrowed and
  scratch cards skip it and rely on the OS sandbox instead.

## Recovery, resume, and restart

The daemon makes a card's run survive crashes and reboots (`OrchestraService+Recovery.swift`):

- **Startup sweep — `recoverSessions()`.** For every non-archived card whose tmux session is *not*
  alive:
  - if it has a tracked `agentSessionId` + an on-disk transcript → **resume** it (recreate the tmux
    session and relaunch `claude --resume`), throttled to `maxConcurrentRevivals` (default 4) in flight;
  - if it was never prompted / freshly restarted → relaunch a **blank** session via `restart()`;
  - otherwise → mark it **`dead`** with reason `rebootUnrevived`.
  It is idempotent: a card whose session is still alive (daemon-only crash) is left untouched.
- **`resume(id, graceSeconds, seed:)`.** Revives an existing session and waits up to the grace window
  (default 15 s) for the `SessionStart(resume)` callback. Success → `waiting`, `deadReason` cleared,
  `recovered` activity. Failure → `dead` with reason `resumeFailed` and a `deadDetail`. Guarded against
  stale `SessionEnd` events via a `recovering` set. The defaulted `seed:` (PR C3) is threaded onto
  `ctx.seed` for the adapter to deliver as the opening turn; every recovery caller passes none, so the
  crash-recovery argv is byte-identical.
- **`resumeInCard(id, seed:)` — F1 context-clearing handoff** (PR C3). Reloads the card into a fresh
  process with **clean context while keeping its `agentSessionId`** — a *resume, not a blank restart*, so
  the transcript carries forward. It drains the inbox, folds it with the authored handoff/fork context
  (`HandoffSeed.fold`), and calls `resume(seed:)` with the result. This — not `restart` — is the shipped
  basis for context-clearing handoff (see [the resume argv & seed](#the-claude-code-adapter) above); it is
  the seam the [`handoff` Command](05-command-reference.md#registry-commands) (PR D1, MCP tool + CLI verb)
  drives; forks instead `spawn`/`batch-spawn` a fresh card carrying a `SpawnInput.seed`
  ([chapter 9](09-design-decisions.md#shipped-feature-history)). (The D3 Handoff/Fork buttons that once
  drove these from the inspector were later removed — the *agent-buttons simplification*.)
- **`restart(id)`.** Launches a fresh blank session in the *same* worktree with a new `agentSessionId`,
  rolling the old id into `priorSessionIds`. Sets `titleProvisional=true`, `status=.waiting`, clears
  `desc`. Never touches worktree contents. This is the "Start new session" button in the Recovery
  panel — a genuinely blank restart, distinct from the seeded, id-preserving `resumeInCard` above.
- **`reopen(id)` — un-finish a Done card.** Archive is not terminal: `reopen` brings an archived card
  back onto the board and revives its agent. First it **recreates the run dir the archive reclaimed** —
  `worktrees.ensure(repo:branch:)` for a `.worktree` card (the archive kept its branch, so the work
  returns), a `mkdir` for a `.scratch` card, nothing for `.borrowed` (never removed). Then it unarchives
  the card **keeping its original column**, resetting `status=.waiting` and clearing any stale
  `deadReason`/`deadDetail`, and emits a `.recovered` activity. Finally it revives the agent through the
  **same primitives above** — `resume` when the card `isResumable` (transcript survived), else a blank
  `restart` in the recreated tree. It is **idempotent** (a non-archived card is returned unchanged) and
  fully **agent-agnostic** — every adapter already implements `resume`/`restart`, so `reopen` adds no
  adapter code. It backs the [`reopen` Command](05-command-reference.md#registry-commands) and the app's
  [Done-popover Reopen button](07-app-ui.md#onboarding-settings-recovery-and-popovers).
- **`reconcileLiveness()`.** The 2-second poll loop's safety net: for every non-archived, non-terminal
  card it checks whether the tmux session vanished and flips it to `dead` (`sessionVanished`) if so —
  catching deaths that didn't fire a `SessionEnd` hook. Cards mid-resume/restart are skipped.

How a dead card is presented to you — the "why" line, the preserved-work actions, and the recover/
restart/archive buttons — is covered in the [App UI chapter](07-app-ui.md#recovery-panel).
