# 4. Cards, worktrees & sessions

This chapter covers the machinery that turns a `Task` into a running agent: git worktree management,
the tmux session topology, the agent adapter protocol and the Claude Code adapter, the three-layer
read-only barrier, process and path safety, and crash/reboot recovery. These live under
`Sources/OrchestraCore/` (`WorktreeRegistry`, `SessionManager`, `Agents/`, `Proc`, `PathResolver`,
`OrchestraService+Recovery`).

## Worktrees

Each `.worktree` card owns **exactly one git worktree** — a 1:1 relationship (see
[Design decisions](09-design-decisions.md#11-worktree-card-ownership)). The **`WorktreeRegistry`** actor
(`Sources/OrchestraCore/WorktreeRegistry.swift`) is the **sole owner** of worktree and borrow lifecycle:
the concrete `WorktreeManager` — the struct that actually shells out to `git worktree add`/`remove` — is
`fileprivate` inside the same file, a compile-time guarantee that nothing outside the registry can touch
a git worktree op. Every teardown path (spawn rollback, archive, reopen, the borrow sweep) routes through
the registry's `ensure` / `release` / `ensureBorrow` / `releaseBorrow` / `sweepOrphanBorrows`.

**`ensure(repo:branch:cardId:base:)` is serialized by the actor mailbox alone** — there is no per-branch
lock. `ensure` performs no `await` between checking for a materialized tree and cutting the checkout, so
two concurrent `ensure` calls for the same branch simply run one at a time inside the mailbox: the first
cuts the checkout, the second adopts the tree the first just made, and `git worktree add` fires exactly
once.

**Adoption is gated by a materialized marker, not a bare `fileExists`.** The registry writes a sentinel
file into its own metadata dir (`Config.worktreeMarkersDir`) — **outside** the worktree — only after a
checkout completes (or an explicit one-time migration stamp, below). Keeping the marker outside the tree
matters: an in-tree sentinel would show up as untracked in `git status --porcelain` (every tree would
read "dirty," breaking the dirty-detection arms below) and would mutate a dirty pre-upgrade tree, which
would violate the "survives byte-intact" guarantee. `created` — the flag `ensure` returns, and the guard
`release` checks before it will ever remove a tree — is defined as exactly "the marker is present"; there
is no separate stored bit.

`ensure` branches on what it finds at the computed path:

- **dir present + marker present** → adopt: hand back the existing path, `created == false`.
- **dir present, no marker, clean** (a pre-upgrade or half-created tree with no uncommitted changes) →
  prune it and cut a fresh checkout.
- **dir present, no marker, dirty** → **never removed.** `ensure` throws `worktreeNeedsManualCleanup`
  to its spawn/reopen caller, whose error message carries the manual-cleanup guidance — a prior checkout
  may have been interrupted mid-write, so an unverified dirty dir is left byte-intact for a human to
  inspect rather than silently pruned. (Mapping this into a card-level `dead(.spawnFailed)` + activity is
  a later PR's reconciler concern — not wired here: at spawn, `ensure` runs before the card exists and
  outside the rollback/launch catch; at reopen, `ensure` runs before the `dead(.spawnFailed)` catch.)
- **dir absent** (fresh, just-pruned, or a marked tree whose dir vanished underneath it) → `git worktree
  add`, then write the marker.

**Removal routes through one policy — `release(cardId:cards:force:)`.** It removes the card's tree only
when **all** of: no sibling still references it, the tree is clean (or `force`), a marker is present
(`created`), and the path is under the registry's owned roots (`config.worktreesRoot`, which also covers
`orch-borrow-*` dirs). A missing tree is an idempotent success, never an error, and `release` never
throws in a way that could lose data — every ambiguous case resolves to "keep the tree."

Sibling counts are **computed on demand** from the `[Task]` the caller passes in — there is no stored
refcount map. The check is `cards.filter { $0.id != cardId && !$0.archived && $0.origin == .worktree &&
$0.cwd == path }`: a `dead` card (not yet archived) still counts as a holder, because its tree must
survive for `restart` to reattach to; only `archived` actually drops the reference. The registry also
tracks an in-memory **in-flight holder set** — a race guard for the window between a concurrent same-branch
`ensure` adopting a tree and that card's persistence to the store; without it, the first spawn's rollback
could see no store-derived sibling and remove the tree out from under the second, still-being-born card.

**Borrow registrations are persisted, not just in-memory.** `ensureBorrow`/`releaseBorrow` maintain a
`[borrowerCardId: path]` map (atomic JSON beside the inbox, `Config.borrowsPath`), enforcing exactly one
borrower per parent branch. This survives a daemon-only crash: a fresh registry instance re-reads the
file and still knows who holds a given borrow path. `sweepOrphanBorrows(cards:)` is **liveness-guarded**:
it reclaims a registered borrow only when its borrower card is *present* in `cards` **and** `archived` — a
borrower that is merely absent from the passed list is ambiguous (a partial store load), not proof of
death, so the borrow is kept. Unregistered stray `orch-borrow-*` dirs are still reclaimed by a separate
pass over `git worktree list`.

A **one-time migration** (`stampMarkers(forMigratedPaths:)`, gated by its own persisted sentinel so it
runs at most once, at the first post-upgrade boot) stamps markers for every pre-existing worktree so it
becomes adoptable without touching its contents — a dirty pre-upgrade tree survives byte-intact.

**Removal** (on archive, via `release`) runs `git worktree remove --force` under the bulk-IO timeout,
but only after a **work-aware guard**: a config-pinned `git status` probe keeps the tree if it holds any
*unsaved work* (staged/modified/untracked/unmerged entries — or an unqueryable probe, fail-safe), and
surfaces the keep as a warning. Entries that are only ` D` worktree-deletions of index-clean files do
NOT block removal — nothing is left on disk to lose, and that state is precisely what an interrupted
removal leaves behind. Removals interrupted by a timeout or crash are **re-driven at the next daemon
boot** (`archivedComplete` cards only), with a repo-root `git worktree prune` reclaiming any dangling
registrations. The **branch is kept** after removal so the work can be recovered — which is
exactly what [`reopen`](#recovery-resume-and-restart) does: it re-`ensure`s the worktree from that
surviving branch and resumes the agent.

Borrowed and scratch cards have **no worktree**: a borrowed card's `cwd` is the directory you chose; a
scratch card's `cwd` is a freshly `mkdir`'d `~/.orchestra/scratch/<id>`.

Alongside the worktree, each launch writes a small **derived per-card config file outside the tree** —
Claude's managed `--settings`, Codex's launch profile, the read-only inspect settings — reaped by
`sweepCardFiles` at boot and after teardown. It is a fail-safe, forward-keep-set sweep sharing
`OrphanSweep.reclaimable` with the scratch/borrow sweeps; see
[garbage-collecting derived per-card files](09-design-decisions.md#garbage-collecting-derived-per-card-files).

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
Code (the multi-provider direction is [Roadmap axis 2](10-roadmap.md)) — a per-agent **capability
descriptor** the core degrades on, plus a Codex adapter as the second conformer. The
**seam-contract root has landed** — PR A1 froze the complete capability descriptor and moved core onto
it, **PR A2** added the adapter's own **`parse`** (below), and **PRs B1–B2** have since landed the
**Codex adapter** as the second conformer — its launch/session/trust and its rollout-tail telemetry (see
[the Codex adapter](#the-codex-adapter), below) — and **PR C3** has landed **F1 resume-in-card**: the
`seed` now rides `resume` as the session's opening positional turn (see the resume argv under
[the Claude Code adapter](#the-claude-code-adapter), below), and **PR C4** has landed the **Codex
send-keys wake** (the `.sendKeys` `wakeTransport`; see [the Codex adapter](#the-codex-adapter) and
[chapter 9](09-design-decisions.md#shipped-feature-history)); **PR D1** has since surfaced that F1 seam
as the [`handoff` Command](05-command-reference.md#registry-commands) (MCP tool + CLI verb), and **PR D3**
has since landed the new-card **Fork/Fan-out** board/CLI start-actions (a `spawn`/`batch-spawn` carrying a
new `SpawnInput.seed`) plus the Handoff/Send card actions — completing the agent-provider forest. An
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
Fable 5, Sonnet 5, Haiku 4.5 — and assembles the `claude` command line:

- **start**: `claude [--model <id>] [--permission-mode auto for plan] [read-only flags] [--session-id
  <uuid>] --settings <one file> [--name <title>] [<prompt>]`. The session id is
  *seeded* at spawn so Orchestra knows it before the agent reports.
- **resume**: `claude --resume <sid> --settings <one file> [--name] [--model] [--permission-mode auto for
  plan] [read-only flags] [<seed>]` — no `--session-id`, no prompt re-handed; when a handoff/fork **seed**
  is present (F1, PR C3) it rides as the trailing positional opening turn. The **launch posture is now
  identical whether a session starts or continues**: the shared `.resume` `AdapterContext` used to omit the
  card's `access`, so a read-only card came back *writable* — an **agent-agnostic** bug, since Codex emits
  its lockdown flags from `ctx.access` on resume too, so read-only Codex cards were equally affected and are
  equally fixed. It also omitted `startIn`, which is Claude-only in effect: a **plan** card silently lost
  `--permission-mode auto` the first time it was resumed or handed off (Codex emits no `startIn` flags), so
  that half needed `ClaudeCodeAdapter.resume` to re-emit them as well. The `--model` here is what the
  [`--model` re-seat](05-command-reference.md#the---model-re-seat) re-binds (the vendor honors it on
  `--resume`; Codex likewise honors `-m` on `codex resume`).

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
transcript carries forward and the authored seed only adds the new instruction. It does **not** drain the
inbox. Instead, the RelaunchStepper calls `claimSeed`, which atomically calls `Inbox.claim` with
`HandoffSeed.compose(handoff:messages:)`: handoff first, then the inbox in FIFO order under the same
operator-relayed header the Claude Stop-drain uses (`StopDrain.inboxHeader`, `[k/N]`-numbered when batched).
The compose runs inside the claim under the single 10 000-character budget, so only the messages actually
rendered into the opening turn are leased; the overflow remains durable for the next delivery. A claimed
message stays in the inbox until its token-confirmed receipt, preventing the old drain-then-crash loss and
the old fold-after-drain truncation path. A pure handoff still seeds even with zero message ids.
`resumeInCard` is the seam the [`handoff` Command](05-command-reference.md#registry-commands) (PR D1, MCP
tool + CLI verb) calls; forks instead `spawn` a new card with a `SpawnInput.seed` (a *new-card* seed
distinct from this resume-only `pendingSeed`; [chapter 9](09-design-decisions.md#shipped-feature-history)).
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
  agent. The Codex adapter applies the same `ctx.trustCwd` as an explicit
  `projects.<cwd>.trust_level` value in the launch profile file on every start and resume, including the
  untrusted case, so a stale native setting cannot silently grant trust (see
  [the Codex adapter](#the-codex-adapter)).

**Delegation guidance — package the shared sections** (`prepareToLaunch`, also): the provider-neutral
`AgentGuidance` bundle chooses the delegation and tree variants, in a stable order, for the adapter's id.
Claude writes each selected section as a vendored project skill under
`<cwd>/.claude/skills/orchestra-<section>/SKILL.md`, which keeps the tracked worktree clean and needs no
`~/.claude` install. Codex consumes the same selected sections as one
`developer_instructions` value in its launch profile file (see [the Codex adapter](#the-codex-adapter))
instead of writing an `AGENTS.md`. The Claude write is best effort and idempotent; the Codex projection is a
per-launch `orch-…` profile layered on the native config, so neither adapter overwrites a user's global
guidance.

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
provider-agnostic — registered in the default `AgentRegistry` alongside Claude (PRs **B1–B2**). It
differs from Claude on every capability axis, and
core handles the difference purely through the descriptor:

- **Access-gated launch.** Like Claude, Codex honors the card's `access`: a **default (read-write)**
  card launches with **Codex's own default permissioning** (no `-s`/`-a` clamp), and only a
  **read-only** card applies Codex's read-only preset `-s read-only -a never` (`accessFlags`). `-s
  read-only` selects Codex's own OS-sandboxed read-only mode; `-a never` disables approvals. `resume`
  (`codex resume <sid> [-s read-only -a never] [-m <model>] [<seed>]`) also appends the F1 `seed` as a
  trailing positional turn when present (PR C3) — and because Codex has **no Stop hook**
  (`inboxDrain == .sessionSeed`), this folded seed is the *only* channel its queued inbox messages ride
  (see [the resume argv](#the-claude-code-adapter) above).
- **Discovered session id + native rollout path.** Codex can't be handed a session id, so `newSessionId()`
  returns `nil` (`.discovered`, not Claude's `.seeded --session-id`); `sessionInfo`/`discover()` instead
  read the id back from Codex's normal state location, normally
  `~/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl` (the uuid is the filename tail). Orchestra does **not**
  export `CODEX_HOME`: Codex keeps its native authentication, plugins, configuration, and session state.
  The adapter retains an injectable home resolver only for hermetic rollout-discovery tests.
- **Launch-scoped hooks, trust, and guidance — via a per-launch profile file.** `prepareToLaunch` writes a
  per-cwd Codex profile (`$CODEX_HOME/orch-<hash>.config.toml`), and `start`/`resume` select it with a tiny
  `-p <name>`. The profile carries the same three things the first cut inlined as `-c` overrides: the
  rendered `codex-hooks.json` handlers as `hooks.<event>` (SessionStart — the
  [Claude-parity orientation channel](06-clients-cli-mcp.md#the-hooks--_report-channel) — PermissionRequest,
  and Stop; telemetry remains the rollout tail below), the explicit `projects."<cwd>".trust_level`
  (`trusted`/`untrusted`, so a stale native setting can't silently grant trust), and one
  `developer_instructions` value from the shared `AgentGuidance` delegation/tree sections. The move off inline
  `-c` is **load-bearing, not cosmetic**: the developer instructions alone are ~16KB, and a session is
  launched through `tmux new-session … --`, whose argv is capped at ~16KB (overlong → `.spawnFailed` /
  "command too long"), so the payload has to travel through a file. Codex layers the profile on top of its
  native config, so Orchestra writes no global `config.toml`, `AGENTS.md`, or `hooks.json` content, keeps
  Codex's authentication / plugins / session state intact, and never reads the `TrustLedger` itself.
- **Establish hook trust at launch — `--dangerously-bypass-hook-trust`.** The installed Codex build
  trust-gates hooks behind a launch-time modal Orchestra can't answer, so without intervention the
  scoped hooks above never fire. `CodexAdapter` adds `--dangerously-bypass-hook-trust` to the
  `start`/`resume` argv, which is empirically the **only** mechanism that runs untrusted hooks — the
  config seed `-c bypass_hook_trust` was rejected as inert, and persisted trust is hash-keyed (a seed
  would be fragile). The flag is a hook-trust choice for that Codex process, not an approvals or sandbox
  setting. It is **build-probed** via
  `<bin> --help` and cached, so a stock `codex-rs` build (which lacks both the trust gate and the flag)
  still launches; the change is Codex-local — Claude's argv is untouched.
- **Offline model table.** `models()` loads a **vendored** `Resources/codex-models.json` (the `gpt-5.6`
  family — Sol / Terra / Luna — = 372 000-token window; `gpt-5.5` = 272 000), `.copy`-bundled
  so the app stays fully offline. This
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
  `turn_complete` / `TurnComplete` all mean a natural turn completion (`run: .waiting(.humanTurn)`,
  `turnCompleted: true`), and token totals read from a
  nested `total_token_usage.total_tokens` **or** a flat `total_tokens`/`tokens`. A `token_count` line
  yields `ctxPct` (tokens ÷ the **offline** model window above, never the rollout's own reported window)
  plus `modelId`; a turn/task start or a mid-turn `function_call` → `.running` (with a coarse
  `desc: "Running <name>"`); anything unrecognized (including `session_meta`) or non-JSON → `nil`
  (dropped). `seq` is the line's RFC3339 `timestamp` in microseconds since epoch (monotonic in file
  order), so a duplicate or out-of-order line loses to the freshest snapshot at
  [`report`'s seq-gate](06-clients-cli-mcp.md#the-hooks--_report-channel).
- **Claude completion signal**: Claude uses the separate `TaskCompleted` hook for the same
  `turnCompleted` signal. Claude `Stop` stays a waiting/Stop-drain event and does not by itself conclude
  a delegated card.
- **Driver — `OrchestraService.pollTelemetry()`**: one tick per card, called from the daemon's existing
  **2-second poll loop** next to `reconcileLiveness`. For every live card whose
  `capabilities.telemetry == .fileTail` it resolves the rollout path via `sessionInfo`, feeds each new
  line through `adapter.parse` into the seq-gated `report`, and merges the result onto the card — so a
  Codex card shows live context %, running/idle status, and model, fully offline. Claude (`hooksPush`) is
  never tailed, so its push path stays byte-identical.

**Send-keys wake** (`CodexComposer` + `OrchestraService.sendKeysWake`, PR **C4**). Because Codex
advertises `wakeTransport == .sendKeys`
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

## The orchestration seam (handoff · fork · fan-out · send · wait)

Agents orchestrating agents is not a fifth feature bolted on beside the other four — **all of it
composes from one live-delivery seam** with three functions: **F1 seed** (authored context folded into
a session's opening turn), **F2 wake** (getting a live-but-idle agent to take a turn), and **F3 inbox**
(a durable per-card queue drained at the agent's natural turn-end).

```mermaid
sequenceDiagram
    participant O as Orchestrator card
    participant D as orchestrad · OrchestraService
    participant X as Inbox — durable, per card
    participant C as Child cards

    O->>D: batch-spawn  (fan-out) / spawn --seed  (fork)
    D->>C: one Task per prompt, phase = creatingWorktree<br/>SpawnInput.seed rides the opening turn  [F1]
    O->>D: wait refs...  (watcher = $ORCHESTRA_TASK_ID)
    D->>D: MergeWatch.register — the call parks, no polling, no git

    Note over C: a child works, then concludes —<br/>archived (Done) or a clean agent exit

    C->>D: transition() into a terminal phase
    D->>D: concludeCard → Conclusion(cardId, ref, kind = done / exited)
    D->>X: coalesce the conclusion into the watcher's inbox  [F3]
    D-->>O: wait returns that Conclusion and the process exits
    D->>O: wake  [F2] — Claude: nativeReinvoke on wait-exit;<br/>Codex: relaunch / send-keys
    O->>D: drains its inbox, re-issues wait on the cards that remain

    Note over O,X: send ref "..." is the same seam —<br/>enqueue to the Inbox [F3], then wake [F2]
    Note over O,D: handoff thisCard "..." is F1 alone — resumeInCard persists the handoff;<br/>RelaunchStepper claims + composes the inbox seed, then resumes
```

Read the verbs against that seam and each one collapses into a composition of the three:

- **`spawn --seed`** is a *fork*: a new card whose `SpawnInput.seed` (the parent's slice of context)
  rides its opening turn — F1.
- **`batch-spawn`** is *fan-out*: the same thing, one card per prompt.
- **`handoff`** is F1 applied to the card *itself* — `resumeInCard` persists the authored context and
  resumes with clean context but the same session identity; the RelaunchStepper atomically claims and
  composes the pending inbox with that context before launch.
- **`send`** is F3 + F2: enqueue durably, then wake.
- **`wait`** is the reactive half. It parks on `MergeWatch` and resolves off **real card state — never
  `git merge-base`** — because [`transition()`](#the-transition-funnel--the-sole-writer-of-phase) is the
  sole concluder, so a `Conclusion` fires exactly once per child on *any* terminal phase, a crash as
  surely as a clean Done. Fan-out **coalesces rather than barriers**: watching N children yields one
  conclusion per child, as each concludes. A child that merely *finishes talking* has not concluded: a
  worktree card that `send`s its result and ends its turn sits in `waiting`, holding its session and
  worktree, until its parent `archive`s it.

The two agents differ only *behind* the `AgentCapabilities` seam (`wakeTransport`, `inboxDrain`) — core
never branches on the agent id. This is the machinery the README's fan-out demo is exercising: the
orchestrator there is an ordinary Claude card calling the ordinary `spawn` and `wait` MCP tools.

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

This three-layer recipe is Claude-Code-specific; the agent-provider interface
(Roadmap axis 2) generalizes it into a provider-agnostic **`readOnlyEnforcement` capability**
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

The daemon makes a card's run survive crashes and reboots (`OrchestraService+Recovery.swift`). Since
Stage 2 (the *lifecycle-convergence* work — see
[design decisions](09-design-decisions.md#the-phase-funnel-one-writer-epochs-and-capability-gated-readiness))
this all routes through **one persisted lifecycle variable** — `Task.phase` — and **one writer**.

### The `transition()` funnel — the sole writer of `phase`

Every lifecycle mover (spawn, launch, liveness poll, restart/resume, archive, a status report) routes its
phase change through **`transition(id, to:, observedEpoch:, mutate:)`** in `OrchestraService+Lifecycle.swift`.
Nothing else writes `phase`. The funnel, in order:

1. **Idempotency.** `to == from` is a `.noop` — *except* the `relaunching → relaunching` supersede
   self-edge, which is **not** swallowed because it re-arms a fresh generation.
2. **Stale-signal fence.** A non-nil `observedEpoch` marks the call a *signal* (a liveness poll / late
   hook) carrying the epoch it observed; if that epoch ≠ the card's current `sessionEpoch` the signal is
   from a session we've since torn down, so it is dropped (`.noop`). A verb-driven call passes no epoch.
3. **Legal-edge check.** The edge is validated against the pure `isLegalEdge(from:to:viaSignal:)` machine
   (below); anything outside the set is `.rejected` and the stored phase is untouched. Verbs map
   `.rejected` → a typed RPC error and `.noop` → idempotent success; async signals ignore the result.
4. **One field-delta patch.** `phase` + `phaseChangedAt` + the epoch bump + the caller's `mutate` closure
   are applied inside a **single** `store.update` patch, so companion writes land atomically with the
   phase change (restart clears `agentSessionId`, resume clears dead metadata, `markDead` writes the
   reason/detail, spawn-fail writes `deadDetail`). This is the **same-patch hook**.
5. **Conclusions.** The funnel is the **sole concluder**: only the entry into a terminal phase *from a
   non-terminal one* fires `concludeCard`; `dead → archived` (terminal → terminal) is guarded out, so a
   card never double-concludes. The wire `Conclusion` carries `{kind, deadReason?}` — `.done` is
   **archived-only** and carries no reason; **any** `.dead` reason concludes `.exited` and carries the
   reason, so a suspended `wait` resolves on **every** terminal death (crash/reboot/resume-fail), not only
   a clean exit (the bug-#2 fix). `isConcluded(_:)` is exactly "phase is terminal" (archived, or any
   `.dead`; archived → `.done`, any `.dead` reason → `.exited`), kept in step with `concludedReason`.
6. **Wake-on-live.** Entering `.live` runs `wakeIfPending` — the single structural release point for a
   message parked (via `send`/inbox) while the card was being born. It no-ops unless the card is now
   `.live(.waiting)` with a non-empty inbox.

### The phase machine (`isLegalEdge`)

The legal edges (spec §P1) are a pure function of the two `Phase.Kind`s plus a `viaSignal` gate:

- provisioning: `creatingWorktree → launching → live`;
- live churn + restart entry: `live → live` (run-state changes), `live → relaunching`;
- relaunch: the `relaunching → relaunching` supersede self-edge, and `relaunching → live`;
- restart of a dead card `dead → relaunching`, and the **signal-only** revival `dead → live` (admitted
  *only* when `viaSignal` — no verb may drive a revival);
- archive teardown `archivedPending → archivedComplete`, and reopen `archived* → creatingWorktree`;
- any non-archived phase may die (`… → dead`) or be archived (`… → archived*`).

Everything not enumerated is illegal.

### Epochs — deterministic staleness

`sessionEpoch` is a **monotonic per-card session generation**. The funnel bumps it **once** on every
(re)launch-bound *entry* — `creatingWorktree` (spawn/reopen) and every `relaunching` entry **including the
supersede self-edge** — *before* any launch work. `launching` is deliberately **not** a bump point (the
machine only reaches it from the already-bumped `creatingWorktree`). At launch the current epoch is stamped
into the tmux environment as **`ORCH_EPOCH`** (`withEpoch`, agent-agnostic — it rides the `-e` env at every
launch call site); the agent's hooks echo it back on `_report`, and it is readable back out-of-band via
`SessionManager.stampedEpoch(name:)` (`tmux show-environment … ORCH_EPOCH`). A late hook or liveness signal
carrying a superseded epoch is dropped by the funnel's fence, which is what makes a stale signal harmless.

**Nil-epoch kill discipline.** A pre-upgrade signal with no epoch can't be epoch-fenced, so a kill-class
signal (a genuine `SessionEnd` exit/logout) is **probed for real liveness before it may kill** — the check
lives at the inbound-`SessionEnd` site in `report()` (`sessions.isAlive`), not in the funnel: a stale
`SessionEnd` for a session that is actually still alive must not kill the card. An epoch-stamped signal
skips the probe (the fence already covers it). Internal deliberate classifications (`markDead`) are **not**
signals — they pass `observedEpoch: nil` and are never second-guessed.

### Capability-gated readiness (being-born confirmation)

A card being *born* — `launching` (blank spawn/reopen) or `relaunching` (resume/restart) — is confirmed
alive by the adapter's `AgentCapabilities.readinessConfirmation`, never by agent identity (the **D1**
resolution — one axis covers *both* being-born phases). `confirmReadiness` dispatches on it:

- **`.sessionStartHook`** (Claude) — inline-await the agent's own SessionStart telemetry reaching
  `report()`: `startup` confirms a fresh launch, `resume` confirms a relaunch. One hook capability covers
  both being-born phases.
- **`.rolloutMeta`** (Codex, `.discovered` id) — also await: a fresh launch writes a rollout `session_meta`
  line that the daemon-side tail observer resolves the waiter on (binding a discovered id mid-`launching`
  *is* the ready signal). A `codex resume` writes **no** rollout, so nothing arrives — the **universal N=3
  liveness-tick fallback** (`tickLaunchReady`, ~6 s, well under the 30 s launch timeout) resolves the still-
  pending waiter within the grace, keeping the relaunch **on** the readiness gate rather than landing live
  immediately and bypassing it.
- **`.relaunchLiveness`** — the successful tmux `ensure` *is* the confirmation (the agent emits no marker at
  all), so it must **not** wait for a signal that never comes (which would time out and fail-dangerously
  `markDead` a live card).

The continuous `reconcileLiveness` (2 s) is the safety net for every variant. Readiness resolution is
outcome-typed `{confirmed, timedOut, superseded}`: **`.superseded`** is distinct from `.timedOut` so a
relaunch displaced by a newer relaunch for the same card exits quietly (the survivor owns the card) instead
of being marked dead.

> **Convergence (PR4b) shipped.** `spawn`/`resume`/`restart`/`reopen`/`handoff` are now **intent-only**:
> each persists a target phase through `transition()` and returns immediately, without awaiting a worktree
> checkout, an agent bring-up, or a teardown duty. The daemon's reconciler drives the walk off the request
> path via four `PhaseStepper`s (`MaterializeStepper`/`LaunchStepper`/`RelaunchStepper`/`TeardownStepper`) —
> see [the Convergence model](02-architecture.md#the-convergence-model) for the full picture; it isn't
> duplicated here. The liveness rule below (a vanished `.launching` session → `.dead(.spawnFailed)`) is now
> enforced by the reconciler's `phaseChangedAt`/`sessionLaunchTimeout` check rather than a synchronous verb
> owning its own timeout.

### The recovery primitives

- **Startup reconciliation — `reconcilePhasesAtBoot()`.** For every `.live` card at boot, adopt its
  surviving tmux session **only on epoch identity** (`sessionEpoch` matches the session's stamped
  `ORCH_EPOCH` — a daemon-only crash); a stale/mismatched epoch means the session isn't ours, so the card
  is driven `→ .relaunching` to reclaim identity. Transitional (`creatingWorktree`/`launching`/
  `relaunching`/`archivedPending`) and dead cards are left for the reconcile **tick**, which re-drives
  them through the phase-keyed steppers (Materialize / Launch / Relaunch / Teardown) — a launch derives
  `resume`-vs-blank via `deriveLaunchFlavor`, and an unrevivable card lands `.dead(.rebootUnrevived)`.
  Idempotent — a `.live` card whose session is still alive at the matching epoch is left untouched.
- **`resume(id, graceSeconds, seed:, model:)`.** **Intent-only** (PR4b): it enters `.relaunching` through
  the funnel (which bumps the generation — the atomic **generation claim** — and clears dead metadata in the
  same patch) and **returns**; no subprocess runs before that return. The reconciler's `RelaunchStepper`
  then drives the walk — re-materialize a missing worktree, kill + re-`ensure` the session **off-actor**,
  confirm readiness (capability-gated), and finalize `→ .live` **epoch-fenced** (`observedEpoch: epoch`), so
  a superseded attempt's finalize is a no-op. Success → `recovered` activity; failure →
  `.dead(.resumeFailed)` + a `deadDetail`. The defaulted `seed:` (PR C3) is threaded onto `ctx.seed`; every
  recovery caller passes none, so the argv is byte-identical.
- **`resumeInCard(id, seed:, model:)` — F1 context-clearing handoff** (PR C3). Reloads the card into a fresh
  process with **clean context while keeping its `agentSessionId`**. It persists the authored handoff/fork
  context and calls `resume(seed:)` without draining. The RelaunchStepper then atomically claims the pending
  inbox and composes it with that context through `HandoffSeed.compose`; messages remain durable until their
  token-confirmed receipt. It is the seam the [`handoff` Command](05-command-reference.md#registry-commands)
  (PR D1) drives and the idle-wake path for a resume-seed agent; forks instead `spawn` a fresh card carrying
  a `SpawnInput.seed`.
- **`restart(id, model:)`.** Also **intent-only**: it enters `.relaunching` with the real persist block
  applied atomically (fresh `agentSessionId`, old id rolled onto `priorSessionIds`, `titleProvisional=true`,
  cleared dead/desc) and returns; the same `RelaunchStepper` then launches a blank session in the *same*
  worktree and finalizes `→ .live` epoch-fenced. Never touches worktree contents. The "Start new session"
  Recovery button — distinct from the seeded, id-preserving `resumeInCard`.
- **The `model:` re-seat** (all three above). A `--model` on `restart`/`handoff`/`resume`
  ([the re-seat](05-command-reference.md#the---model-re-seat)) is validated against the card's **own**
  adapter catalog (`resolveModelOverride` — `agentId` never changes, so a cross-adapter id is refused) and
  staged as [`Task.pendingModel`](03-data-model.md#the-task-card) in the same funnel patch as the
  `→ .relaunching` intent. `finishLaunch` builds its `AdapterContext` from `pendingModel ?? model.id`, and
  each of the four `.live` landings — the two steppers, the boot **adopt** path, and `report()` itself when
  a stamped current-generation report lands a card the steppers left behind — consumes it through the
  shared `consumeModelReseat`, exactly as it consumes `pendingSeed`. A failed launch leaves it staged for
  the retry. Why the intent gets its own field, rather than just writing `model`:
  [report() vs the launch intent](09-design-decisions.md#report-vs-the-launch-intent-pendingmodel-and-the-epoch-fence).
- **`reopen(id)` — un-finish a Done card.** Walks the legal path `archived → creatingWorktree → launching →
  live`: an archived card's `phase` is already `.archived(teardownComplete: true)` (the archive verb writes
  the phase and the `archived` Bool together; `DeadReason.completed` is gone, so a legacy stored
  `.dead(.completed)` record no longer decodes at all — it self-drops on load rather than being normalized,
  see [chapter 9](09-design-decisions.md#done-is-not-observable--success-is-agent-signalled-not-inferred)),
  then enters `.creatingWorktree` (bumping the generation)
  clearing the archived Bool + dead metadata, **recreates the run dir the archive reclaimed** (`worktrees.ensure`
  for `.worktree`, `mkdir` for `.scratch`, nothing for `.borrowed`), and brings the agent up via the shared
  **`launchAndConfirm`** step (`.resume` flavor when `isResumable`, else `.blank`). It does **not** call
  `resume()`/`restart()` (they enter via `.relaunching`, illegal from `.creatingWorktree`). Idempotent and
  agent-agnostic. Backs the [`reopen` Command](05-command-reference.md#registry-commands) and the app's
  [Done-popover Reopen button](07-app-ui.md#onboarding-settings-recovery-and-popovers).
- **`materialize(id)` + `finishLaunch(id, flavor:)`.** The retired synchronous `launchAndConfirm` step is
  now split across the reconciler's steppers (`OrchestraService+Converge.swift`): `MaterializeStepper` calls
  `materialize(id)` to cut/adopt the `.creatingWorktree` card's worktree (or mkdir a scratch dir) and land
  `.launching`; `LaunchStepper` then calls `finishLaunch(id, flavor:)` to `ensure` the session, confirm
  readiness, and land `.live`. Both are stateless, idempotent, and re-derive everything from the persisted
  card, so a crash between steps is re-driven safely rather than raced. Not used by resume/restart (they
  walk the `.relaunching` edge via `RelaunchStepper`).
- **`reconcileLiveness()`.** The 2-second poll loop's phase-gated safety net (one `tmux list-sessions` per
  tick). Being-born (`.creatingWorktree`) and `.relaunching` cards are **skipped** (their session is
  legitimately absent mid-bring-up; a live relaunching card with a still-pending waiter ticks the N=3
  fallback); a vanished `.launching` session → `.dead(.spawnFailed)`; a vanished `.live` session →
  `.dead(.sessionVanished)`; terminal cards excluded. All deaths route through `markDead` → the funnel, so
  they conclude.

### The `relaunchClaimed` atomic claim

The old `recovering` set is **deleted**; its two roles are split. Its *grace-window* role (fencing a stale
signal against a relaunch in flight) is now covered by **epochs** — the funnel drops a superseded-epoch
signal, and `reconcileLiveness` skips `.relaunching` by phase. Its *atomic-claim* role — ensuring a single
winner when a wake/idle-resume fires — is now the narrow **`relaunchClaimed`** set: `resumeSeedWake` inserts
the id synchronously *before* the detached resume hop, so a concurrent `wake` sees the claim and defers
(otherwise two resumes race and the second drains an already-emptied inbox and kills the first's session).
It is cleared when the relaunch settles (`clearRelaunchClaimed`), which then re-drives `wakeIfPending` for a
message that a `send` queued *during* the claim window (nothing else would retry it).

How a dead card is presented to you — the "why" line, the preserved-work actions, and the recover/
restart/archive buttons — is covered in the [App UI chapter](07-app-ui.md#recovery-panel).
