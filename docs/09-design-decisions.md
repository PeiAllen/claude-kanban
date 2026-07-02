# 9. Design decisions

This chapter records the *why* behind Orchestra — the cross-cutting principles that shape the system,
and the history of the shipped feature PRs. The authoritative source is the layered design vault under
[`notes/designs/`](../notes/designs/) (each topic has `index.md` + 01-design → 04-tests layers) and the
shipped-PR plans under [`notes/plans/`](../notes/plans/); this chapter summarizes and links into them.

## Cross-cutting principles

### Thin clients, single coordinator

The daemon runs the one `CommandRegistry` and the `OrchestraService` actor; the app, CLI, and MCP
bridge each serialize calls independently and converge at the server. Commands go in, events come out.
There are no distributed state machines and no per-client truth — a spawn from the CLI updates the app's
board because both subscribe to the same event stream. (`notes/designs/kanban-board/index.md`, "Control-
plane data flow — one coordinator, but federated truth".)

### Federated ground truth, not in-memory state

The daemon does not treat its memory as authoritative. **`tasks.json`** holds metadata, **tmux** is the
authority on liveness, and **git** is the authority on the worktree. This is what makes recovery robust:
the daemon (or the whole machine) can restart and reconstruct reality from disk + `tmux ls` + git,
rather than losing track of running agents.

### Terminal bytes bypass the daemon

The control plane carries commands, state, and events — never PTY bytes. SwiftTerm and the CLI's
`shell`/`inspect` attach to **tmux directly**. This keeps the daemon simple and the terminals fully
interactive and real-time.

### State is pushed through a two-way hook channel

Live card fields (`ctxPct`, `desc`, `status`, session id, title) are **pushed by the agent** via a
managed Claude Code `--settings` file (statusLine + hooks → `orchestra _report`), not scraped from the
pane. The channel is bounded (a stalled daemon can't freeze the agent's status bar) and seq-guarded (a
stale `ctxPct` can't overwrite a fresh one); pane capture is a fallback only. The same channel is the
backbone for the planned Orchestra → agent context injection. (`kanban-board/index.md`, "The Orchestra
hook protocol".)

### Ownership: Orchestra deletes only what it made

Cleanup is decided by `origin`:

- **`worktree`** — Orchestra created it; archive removes the dir (kept if dirty, and only when no other
  live worktree card shares it).
- **`scratch`** — Orchestra created it; archive **unconditionally** `rm -rf`s it (double-gated by the
  `origin == .scratch` check *and* a runtime prefix check under the scratch root).
- **`borrowed`** — *you* created it; archive never touches it.

This clean rule removes any ambiguity about which cleanup is safe. (`notes/designs/freeform-and-
borrowed-cards/index.md`.)

### Trust boundaries: allowlist for worktrees, sandbox for the rest

Worktree cards validate their repo path against the allowlist (`PathResolver`, symlink- and
`..`-escape-safe, component-wise prefix). Borrowed and scratch cards skip the allowlist and rely on the
OS sandbox confining writes to their directory — so freeform cards stay friction-light while the
boundary still holds.

Layered under that boundary is the **trust ledger** — the durable, human-owned record of which
directories agents may *write* in (see [the trust ledger](03-data-model.md#the-trust-ledger-t1)). Core
resolves trust from a card's `origin` in **`OrchestraService.resolveTrust`** → a `TrustDecision` of
`.trusted` or `.needsGrant`, carried onto the launch as `AdapterContext.trustCwd` — and **adapters only
*apply* that flag; they never read the ledger** (so the same "trusted once" fact carries across Claude,
Codex, and every later agent through one core seam). The three origins resolve distinctly: a
**worktree** trusts its source repo (registering a repo to run agents *is* the trust act — recorded
`repoRegistration`), a **scratch** dir Orchestra made empty is auto-trusted (`orchestra`) but
**demotes to `needsGrant` if a foreign repo is later cloned into it** (a `.git` appears — external code
is no longer Orchestra's to auto-trust), and a **borrowed** dir is `.needsGrant` until a human grants it.
Filling a `needsGrant` is a **human decision, never the agent's**: an untrusted card still spawns — but
**sandboxed** (writes blocked), with an actionable activity telling the human how to grant — and the
grant flows through a `TrustGrantResolver` seam whose production `SurfaceGrantResolver` approves only
*interactive* surfaces (a CLI tty prompt, the MCP elicitation dialog) and **denies `.agent`/`.daemon`**.
That single rule is both the **autonomy-exemption** and the "an agent can't self-grant" guarantee. (Trust
ledger + resolver by **PR T1**; the grant surfaces — `trust` Command, `orchestra trust` verb, MCP
elicitation — by **PR T2**, both in the [shipped history](#shipped-feature-history) below.)

### Read-only is defense in depth

A read-only agent is constrained by three independent layers — edit tools removed, a kernel-level
sandbox write-block, and a semantic auto-mode "deny any mutation" classifier — chosen over a brittle
command deny-list precisely because deny-lists rot and are trivially evaded. On a tracked card the
sandbox layer's settings are **deep-merged onto the managed hooks base into one `--settings` file**
(`SettingsComposer`), never handed as a second `--settings`: Claude Code applies multiple `--settings`
last-file-wins (full replacement, not deep-merge), so a second file would silently strip the statusLine +
telemetry hooks — which is exactly the regression befad61 fixed for agent-created (MCP/CLI-spawned)
read-only cards. `settingsOverlays(_:)` is the single seam any future per-card setting appends to, keeping
the one-file invariant automatic. (See
[the read-only barrier](04-cards-worktrees-sessions.md#the-read-only-barrier);
`notes/plans/pr1-readonly-inspect-button.md`.)

### authMode: advise on fan-out, never cap

Fanning out many concurrent agents onto a **single subscription seat** (a Claude or Codex plan login,
rather than a metered API key) is the "heavy parallel automation" pattern both providers' anti-automation
terms target — so Orchestra notices it, but it **advises and never blocks**. When a card is brought up on
an adapter whose `capabilities.authMode` is `.subscription`, `AuthRateMonitor` tallies the *live*
subscription-auth cards for that same adapter and, past a threshold (default 3 → the 4th warns), emits an
advisory `ActivityKind.warning` into the feed suggesting API-key mode for large fan-outs. The spawn always
proceeds; there is **no concurrency cap, no queue, no rejection**. Three properties make this a decision
rather than a knob:

- **Warn-only, resolved deliberately.** Capping was considered and rejected — a hard limit on parallelism
  would break the very fan-out topology Orchestra exists to enable. The monitor never throws or blocks.
- **Rate state is per-adapter and derived, not held.** Each subscription is its own seat, so a Claude
  fan-out never pushes a Codex adapter over, and vice versa; and the tally is computed from the current
  card set (the SSOT) on every spawn rather than kept in a counter — so it can't drift and survives a
  daemon restart with no reconciliation.
- **It gates on the capability, never on identity.** The monitor reads `adapter.capabilities.authMode`,
  so an API-key adapter (or a future subscription agent) is classified by its descriptor, never by an
  `if agentId == "claude-code"` branch.

(Agent-provider forest PR **E2**; `notes/plans/e2-authmode-softwarn.md`,
`notes/designs/agent-provider-interface/03-implementation.md` D12 / §9 / q4.)

### 1:1 worktree ↔ card ownership

The target model is **one card owns one branch's worktree** — enforced, not shared. Git forbids the
same branch in two worktrees, so every N:1 case is two writers on one branch (a footgun with no safe
use). Stacked branches want *distinct* trees (still 1:1). This retires the old refcount guard + shared-
worktree badge machinery; the safe co-location patterns (read-only inspect, freeform cards) don't need
worktree sharing. (`notes/designs/stacked-branches-and-guardian-handoff.md`.)

### One seed, four topologies

Handoff, fork, fan-out, and (Claude) subagents are **one primitive** — a fresh session seeded with
authored context — at four topologies. The keystone is an `additionalContext` seed on the spawn/restart
path. The decision rule: *return to the thread?* → fork or subagent; *replace the thread?* → handoff;
*split into many?* → fan-out. Merge-back must be a **durable persisted inbox keyed on card lineage**, not
a `send`-to-tmux (which throws if the session died), and orphaned forks are promoted to standalone cards
rather than cascade-killed. The guiding maxim: **handoff carries intent, artifacts carry facts** — the
seed is for navigation and next steps, while committed code, plan files, and the card description carry
the durable record, so successive handoffs don't degrade into a telephone game. The **live-delivery
substrate** these topologies compose from is specified as three functions — **F1** resume-in-card,
**F2** wake an idle card, **F3** the durable per-card **inbox** (merge-back drains at the next turn-end) —
in the [agent-provider interface](../notes/designs/agent-provider-interface/index.md) L3 design. **F3 has
now landed** (PR C1, below): `send` routes through a durable [inbox store](03-data-model.md#the-inbox-store-f3),
and the Claude Stop hook drains it into the agent at its turn-end. `send`-to-tmux is retired exactly as the
maxim demanded — a queued conclusion no longer throws if the session died, and coalesces with other returns
until the next turn. **F2 wake + the conclusion-watch have now landed too** (PR C2, below): the
[`wait` command / `MergeWatch`](05-command-reference.md#notes-on-key-commands) let an orchestrator card
block until a watched child concludes, with each conclusion coalescing into the parent's inbox and waking
it — the reactive fan-out. **F1 resume-in-card has now landed too** (PR C3, below): a card resumes into a
fresh process with clean context, seeded with an authored handoff/fork context folded together with its
pending inbox — so **all three live-delivery functions the topologies compose from are now shipped**. The
Codex **send-keys wake (C4)** has since landed too (below), the **`handoff` Command (D1)** that *calls*
the F1 seam shipped the first of the topology surfaces (below), and the new-card **fork / fan-out
start-actions + the Handoff/Send card actions** have now landed as well (**D3**, below) — folding an
authored `SpawnInput.seed` ahead of a new card's prompt — so **all four topologies are driveable from the
CLI, MCP, and (at the time) the board**. The board surface was subsequently pared back: the
Handoff/Fork/Fan-out buttons were removed in favor of the natural-language → MCP path, and the per-card
Send button became a full **inbox editor** (the *agent-buttons simplification*, in the
[shipped history](#shipped-feature-history) below). The **guidance** an agent reads to *choose* among these topologies — delegate vs.
continue, and card vs. native subagent (keep both) — has been authored and vendored too (**D2**, below);
and **that last wire has since landed** (**skill-injection**, below): each adapter's `prepareToLaunch` now
auto-materializes the per-agent variant into the location its agent discovers (Claude a project skill, Codex
its isolated `CODEX_HOME` `AGENTS.md`), so the guidance reaches every launched card with no `~/.claude`
install and no launch-argv change.
(`notes/designs/context-passing-topologies.md`, `stacked-branches-and-guardian-handoff.md`.)

## Shipped feature history

The v1 architecture (daemon + control plane + two-way hook protocol + per-card worktree + session
recovery + activity feed + sessions debug handles) is documented in the
[`kanban-board/`](../notes/designs/kanban-board/) design vault. On top of it, four feature PRs shipped
(plans in [`notes/plans/`](../notes/plans/)):

| PR | Delivered | Key decision |
|----|-----------|--------------|
| **PR1** — read-only inspect | An inspector button that opens a read-only `claude` in a card's worktree (read/search/git, no writes). | Two independent locks (tool denial + sandbox `denyWrite`); a normal conversational agent that just can't write (not "plan mode"); throwaway and untracked. |
| **PR2** — task schema `cwd`/`origin` | Migrated `Task` from a single `worktree: String` to `cwd: String` + `origin: CardOrigin`. | A *total* `cwd` (no `effectiveCwd` helper); a 3-way `origin` enum instead of two bools (which would have an impossible 4th combo); behavior-neutral (only `.worktree` cards existed after it). |
| **PR3** — freeform & borrowed cards | Cards that run in an existing directory the user doesn't own (`.borrowed`), in a standalone freeform region, plus the `.readOnly` access mode for tracked read-only cards. | Sandbox-as-boundary (no allowlist gate); rescoped the shared-worktree badge/refcount to worktree cards only. |
| **PR4** — scratch cards | A scratch spawn mode (board, CLI `--scratch`, MCP) that makes a fresh `~/.orchestra/scratch/<id>` dir and `rm -rf`s it on archive; startup sweep of orphaned scratch dirs; auto-trusts the dir so the autonomous agent never blocks on Claude's trust dialog. | Double-gated delete (origin check + path-under-scratch-root check); no dirty-guard (the user moves out anything worth keeping first). Trust is *granted* (not mirrored) because Orchestra owns the dir — there's no source repo to mirror from — while borrowed dirs are left to Claude's own prompt. |

Beyond those four feature PRs, the first **foundational** PR of the agent-provider forest has also landed —
**A1, the seam-contract freeze** (`notes/plans/2026-07-01-a1-seam-contract-freeze.md`). It froze the
complete **`AgentCapabilities`** descriptor (seven enum-typed flags, *every* variant spelling — including
cases no adapter exercises yet — locked now so later PRs can't drift the shape) and the defaulted
**`AdapterContext.seed`** carrier, and moved core to gate session-seeding and resumability on the
capability rather than on adapter identity or a nil-return implication. It ships **no** user-visible
change — Claude behavior is byte-for-byte unchanged — because it is deliberately just the drift-proof
shape the Codex adapter, telemetry seam, and live-delivery PRs will build behind (see
[the adapter capability descriptor](04-cards-worktrees-sessions.md#agent-adapters)). Unlike a full axis
shipping, this is plumbing, not a feature — so it stays here as history rather than migrating a roadmap
row.

A second forest PR has since landed on top of A1 — **E2, the authMode soft-warn**
(`notes/plans/e2-authmode-softwarn.md`). It adds a pure `AuthRateMonitor` value type and an `AuthWarning`
result that watch for heavy parallel fan-out on a single subscription seat and emit an advisory
`ActivityKind.warning` past a threshold — **advising, never capping** (see
[authMode: advise on fan-out, never cap](#authmode-advise-on-fan-out-never-cap) above for the decision and
its rationale). Like A1 it is a single forest PR rather than a whole axis, so it too stays here as history
and leaves the roadmap row for the model-providers/agent-integration axes in place until the full seam
ships.

A third forest PR has landed on top of A1 — **A2, the telemetry-source seam**
(`notes/plans/2026-07-01-a2-telemetry-source-seam.md`). It draws the **transport/parse boundary** the
agent-provider design (D3) calls for: the daemon-side **transport** obtains only *raw* bytes, while the
raw→`StatusReport` **parse** is the **adapter's** own, because that conversion is agent-dependent. A2
relocated the parse out of the `orchestra` CLI target (the former `ReportHelper.map`/`toolDesc`) into a new
defaulted protocol method `Adapter.parse(_ raw: RawTelemetry) -> StatusReport?` (added with a `nil`-returning
default in `extension Adapter`, so no conformer breaks) plus a `RawTelemetry` envelope
(`hooksPush(kind:payload:)` for pushed hook events, `fileTail(line:)` reserved for a future rollout tailer;
`ptyScrape` deferred — no v1 consumer). `ClaudeCodeAdapter.parse` now owns the `hooksPush` conversion,
carrying the former CLI logic **verbatim**; the hidden `orchestra _report` helper — which *is* the Claude
push transport — calls `ClaudeCodeAdapter().parse(.hooksPush(...))` instead of a local `map`. The daemon's
`report` endpoint and the `OrchestraService.report` seq-gate merge are **untouched**, so Claude telemetry
is byte-identical (the pre-existing `ReportTests` stayed green unchanged). The `fileTail` parse and the
daemon-side rollout tailer that feeds it — the same `adapter.parse` seam from a different transport — have
since landed with the Codex adapter (PRs B1/B2, below). Like A1 and E2, this is a single forest PR of plumbing, not a whole axis,
so it stays here as history rather than migrating a roadmap row. (As-built symbols are recorded in
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 1.)

A fourth landed PR is **C1 — the durable inbox + F3 Stop-drain**
(`notes/plans/2026-07-01-c1-inbox-stopdrain.md`). It builds the first of the design's three live-delivery
functions (see [One seed, four topologies](#one-seed-four-topologies)): a durable per-card **`Inbox`**
store (sibling to `TaskStore`, actor-over-JSON, FIFO-per-card, restart-durable — see
[the inbox store](03-data-model.md#the-inbox-store-f3)), with `send` **rerouted through it** instead of
typing into tmux, and a `StopDrain` helper that composes the pending messages into a 10 000-char-bounded
payload. The delivery reuses — rather than adds to — the existing Claude Stop hook: the same
`_report --event notify` command, on detecting `hook_event_name == "Stop"`, calls a new Orchestra-internal
[`drain` RPC](05-command-reference.md#server-only-built-in-methods) and prints a `{"decision":"block",
"reason":…}` continuation so the model reads the queued messages and keeps working. Two decisions shape it:
the merge-back is **turn-end, never mid-turn** — a queued `send` waits for the agent's natural stop rather
than interrupting it — and because `stop_hook_active` is only *informational* on the agent, Orchestra
enforces its **own consecutive-inject loop guard** (`drainForStop`, cap 25, reset by a genuine
`UserPromptSubmit`) to break a runaway Stop→inject→Stop cycle, leaving messages durable when it trips. The
change is deliberately additive: `HooksRenderer`/`claude-hooks.json` are untouched, and the Stop hook's
existing notify→`waiting` report is preserved byte-for-byte. Waking an *idle* card so it takes a turn to
drain (F2) landed next (C2/C4, below), and `send` was subsequently wired to call that same `wake` right
after it enqueues — so a message to an idle card now triggers a turn immediately (content still rides the
inbox; the wake no-ops when the card is busy/drafting, mid-relaunch, or already watching children — a
genuinely idle `nativeReinvoke` card with no live wait is instead woken via resume-seed, see the
[`send-wakes-idle-card` entry](#shipped-feature-history) below) instead of sitting durable
until the agent's next unprompted turn. Like the forest PRs above, C1 is one live-delivery function, not a whole
axis, so it stays here as history while the roadmap's context-continuity row remains open.

A fifth landed PR is **C2 — F2 wake + the merge-watch conclusion-watch**
(`notes/plans/2026-07-01-c2-wake-mergewatch.md`). It builds the second of the three live-delivery functions
and the reactive fan-out on top of C1's inbox: an orchestrator card can watch its spawned children and be
woken as each concludes. Two symbols carry it — a `MergeWatch` actor and a `Conclusion` value
(`{cardId, ref, kind ∈ {done, exited}}`), surfaced as the [`wait` command](05-command-reference.md#notes-on-key-commands)
(auto-exposed as an MCP tool; registry↔MCP parity stays green) plus an `orchestra wait <ref…>` CLI verb.
Three decisions shape it:

- **Conclusion is read from real card state, never git.** The prior fan-out bug was calling `git merge-base`
  to decide "merged" — which false-positives a branch with **zero commits ahead of main** as already merged.
  C2 keys conclusion on `OrchestraService`'s own derived card state (`isConcluded`: archived/Done, or dead
  with `deadReason == .agentExited`), the state it already adjudicates. A dedicated regression test pins the
  0-commit case as *not* concluded.
- **The service is the single authority; `MergeWatch` only subscribes.** `MergeWatch` owns **no** detection —
  no git poll, no file stat, no per-card watcher. It parks a `CheckedContinuation` keyed on the watch set (the
  existing `awaitResume`/`resolveResume` pattern) and is resolved when the service — the one writer that marks
  terminal state — calls `concludeCard`. That call fires from exactly two places: `archive` (→ `.done`) and
  the `report` clean-exit branch (agent-exited, guarded so a *recovering* card never counts → `.exited`). A
  transient crash (`sessionVanished`) that may still be revived is deliberately **not** a conclusion —
  "process ended" ≠ "card concluded."
- **Fan-out coalesces; wake is only a trigger.** Watching N children yields **one conclusion per child, as
  each concludes** — not a barrier on all N. `concludeCard` routes each into every registered watcher's
  durable inbox (F3 coalesce) and calls `wake`; several children concluding while the parent is mid-turn all
  enqueue and drain together at its next turn-end, so no return is lost or needs its own wake. `wake` dispatches
  on the adapter's `wakeTransport`: at C2, Claude's `nativeReinvoke` was a no-op *push* — the wake rode the
  background `orchestra wait` process exiting (which the harness re-invokes on) — and Codex's `sendKeys` wake
  landed later (C4, below). (That no-op case was later narrowed: a genuinely *idle* Claude card with **no**
  live wait is now woken by resume-seed; see the [`send-wakes-idle-card` entry](#shipped-feature-history)
  below.) `wait` also short-circuits on an already-concluded child so the re-issue race can't
  lose a conclusion.

Like the forest PRs above, C2 is one live-delivery function, not a whole axis, so it stays here as history;
the remaining live-delivery function — **F1** resume-in-card — has since landed too (**C3**, below), and the
Codex send-keys wake landed after it (**C4**, below), so only the handoff/fork Commands + UI keep the
roadmap's model-providers / context-continuity rows open. (As-built symbols are recorded in
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 4.)

The sixth and seventh landed PRs are **B1 and B2 — the Codex adapter and its rollout-tail telemetry**
(`notes/plans/2026-07-01-b2-codex-rollout-tail.md`). Together they add the **second `Adapter` conformer**
— the first proof the provider seam is agent-agnostic — registered in the default `AgentRegistry`
alongside Claude (`[ClaudeCodeAdapter(), CodexAdapter()]`). **B1** builds the launch/session/trust half:
`CodexAdapter` (`id = "codex"`) launches **read-only-first** (`-s read-only -a never`, write/approvals
deferred), uses a **discovered** session id (it can't be seeded, so `sessionInfo` reads the newest
`$CODEX_HOME/sessions/**/rollout-*.jsonl` back), isolates its home via `env["CODEX_HOME"]` (B1 also wired
`Adapter.env` into the tmux launch — Claude byte-identical), and mirrors the core's trust decision into
`config.toml`'s `[projects."<cwd>"].trust_level` (never reading the `TrustLedger`). **B2** makes its
telemetry live end-to-end, and its two decisions are the interesting part:

- **The daemon owns the transport; the adapter owns the parse.** Codex's TUI pushes no hook events but
  appends a JSONL **rollout** file, so telemetry is `fileTail`: a daemon-side `RolloutTailer` actor (a
  per-card byte offset that returns only complete, newline-terminated lines and holds a trailing partial)
  hands each line to `CodexAdapter.parse(.fileTail(line:))`, driven by `OrchestraService.pollTelemetry()`
  in the existing 2-second poll loop. This reuses A2's `adapter.parse` seam from a *different* transport
  and stays strictly split — the tailer never inspects JSON, the parse never touches files. Claude
  (`hooksPush`) is never tailed, so its push path is byte-identical.
- **`ctxPct` is derived from a vendored offline model table, and the parse is rename-tolerant.** Because
  Codex reports no context percentage, the parse computes it as tokens ÷ the context window from a
  **vendored** `Resources/codex-models.json` (`gpt-5-codex` = 272 000), never the rollout's own reported
  window — keeping the app fully offline. That per-adapter **offline model table** on `Adapter.models()`
  (context window + flags from an in-repo, PR-updated JSON, no fetch at build or runtime) is its own forest
  PR — **E1** (`notes/plans/e1-model-table.md`), a root off `main` — which B2 consumes here; it is the
  same offline-model-table decision the [roadmap](10-roadmap.md) records for the model-providers axis. And because the rollout schema drifts, the parse
  normalizes the line's `type` fields (lower-cased, `_`-stripped, substring-matched) so `TaskComplete` /
  `TurnComplete` both mean idle and nested/flat token fields both parse; `seq` is the line timestamp (µs)
  so the [report seq-gate](06-clients-cli-mcp.md#the-hooks--_report-channel) keeps the freshest snapshot.

Like the forest PRs above, B1/B2 are a single provider conformer, not the whole model-providers axis — the
Codex **send-keys wake** has since landed (C4, below) but write/approval access remains deferred — so the row
stays in the roadmap as history is recorded here. (As-built symbols:
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 1 & §Area 3.)

The eighth landed PR is **C3 — F1 resume-in-card with a seed**
(`notes/plans/2026-07-01-c3-f1-handoff-resume.md`). It builds the **third and last** of the design's three
live-delivery functions (see [One seed, four topologies](#one-seed-four-topologies)) on top of C1's inbox:
**resume-in-card**, which reloads a card into a fresh process with clean context while **keeping its session
id** — a *resume, not a blank restart*, so the vendor transcript carries forward and the seed only adds the
new instruction. Three symbols carry it:

- **`HandoffSeed.fold(handoff:inbox:)`** — a pure helper that folds an authored handoff/fork context (first,
  trimmed, dropped if empty) and the card's drained pending inbox (FIFO) into **one** seed string, bounded to
  the same 10 000-char live-delivery limit (`StopDrain.maxPayloadChars`) with a `[…truncated]` prefix on
  overflow; `nil` when there is nothing to deliver.
- **`OrchestraService.resumeInCard(_:seed:…)`** — the F1 entry point. It **drains the inbox first**, folds it
  into the seed, then delegates to `resume`. Draining before resume is the load-bearing ordering decision: a
  `.sessionSeed` agent (Codex has no Stop hook) would otherwise never receive its queued messages, and a
  later Claude Stop-drain must not double-deliver them.
- A defaulted **`seed:` parameter on the service `resume`**, threaded onto the frozen `AdapterContext.seed`
  (A1). Each adapter then **reads** `ctx.seed` and appends it as the resumed session's **trailing positional
  turn** (Claude after `--resume`, Codex after `resume <sid>`, and `StubAdapter` mirrors it); with no seed the
  argv is byte-identical, so every existing recovery/`Commands`/test caller is unchanged.

Two invariants make it safe: the **`Adapter.resume(ctx) -> [String]?` protocol signature is unchanged** (the
seed rides the already-frozen context field, resolving the roadmap's
[open injection question](10-roadmap.md#open-design-questions) in favor of an opening-turn positional over
`--append-system-prompt` / `AGENTS.md`), and the change is fully additive/defaulted. `resumeInCard` is the
seam D1's `handoff` Command *calls* (shipped below) and the Handoff/Fork UI (D3, below) now calls too — C3 only
wires the seed *through* resume, adding no Command or UI itself. Like the forest PRs above it is one
live-delivery function, not a whole axis, so it stays here as history while the model-providers /
context-continuity roadmap rows stay open for their non-forest remainders. (As-built symbols:
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 4.)

The ninth landed PR is **C4 — the Codex send-keys wake**
(`notes/plans/2026-07-01-c4-codex-sendkeys-wake.md`). It fills the `.sendKeys` `wakeTransport` case that C2
left as a no-op, so an idle **non-native** card (Codex, whose TUI has no `nativeReinvoke` push and no Stop
hook) is actually woken by [F2 wake / merge-watch](#shipped-feature-history) — completing the reactive
fan-out across *both* providers. Two decisions shape it, and both keep the fragile part contained:

- **Nudge-only — content never rides the keystroke.** The wake sends a *fixed, content-free* nudge
  (`OrchestraService.sendKeysWakeNudge`, `"Please continue."`) whose only job is to start a turn on an idle
  composer. The inbox payload is **never** delivered by keystroke — it rides F3 (the durable inbox drained
  by the [session seed on resume](#one-seed-four-topologies), the `.sessionSeed` `inboxDrain` Codex
  advertises), so the nudge stays a constant. This mirrors the same content/transport split as B2 (the
  daemon owns the transport, the adapter owns the payload).
- **Detect-and-defer — wake only when idle *and* the composer is empty.** `sendKeysWake` reads the agent
  pane *just-in-time* via `capture-pane` (this single capture **is** the re-check right before the nudge)
  and asks a pure heuristic — `CodexComposer` — whether the TUI is idle-and-composer-empty. Only then does
  it fire. A user draft in the composer, an in-flight turn, an unparseable pane, or a dead session all
  **defer**: the nudge is dropped and the inbox stays durable for a later event-driven wake (a subsequent
  conclusion or turn-end). There is **no retry timer** — a poll loop would risk the F3 inject cap
  (`maxConsecutiveInjects`), which is Orchestra's to enforce (C1), not C4's to duplicate. **Focus is not a
  gate.**

`CodexComposer` is a **pure** heuristic (`String` in, no I/O, no service deps) deliberately isolated so its
fragility is contained and unit-testable: it scans the pane bottom-up for the composer's prompt marker
(`› ❯ ▌ ▶`), treats known greyed placeholders (`"Send a message"`, …) as empty rather than a draft, and reads
`workingCues` (`"esc to interrupt"`, `"thinking"`, …) to tell a streaming turn from an idle one — the only
Codex-specific knobs, and the documented place to tune when the TUI drifts. It is keyed on the `.sendKeys`
`wakeTransport`, **never** on `agentId` (send-keys is Codex's transport in v1, not its identity). This TUI
scrape is explicitly a stopgap: v1 stays on send-keys while watching upstream Codex app-server work to
eventually replace it with a real `controlChannel` `wakeTransport` (the already-frozen enum variant), so the
fragile pane read is a contained, swappable seam. Like the forest PRs
above, C4 is one live-delivery function, not a whole axis, so it stays here as history while the
model-providers / context-continuity rows keep their non-forest remainders open. (The `handoff`
Command — D1 — and the fork/fan-out surfaces — D3 — have since landed too; see the entries below.)

The tenth landed PR is **D1 — the handoff delegation tool (MCP Command + CLI verb)**
(`notes/plans/2026-07-01-d1-mcp-delegation-tools.md`). It is the **first agent-facing surface that
*calls*** the three shipped live-delivery functions rather than adding another — a thin `handoff` Command
on the [`CommandRegistry`](05-command-reference.md#registry-commands) that resolves a card ref and
delegates to C3's `OrchestraService.resumeInCard(seed:)`, wiring the F1 *same-card* (replace-the-thread)
[handoff topology](#one-seed-four-topologies) into a callable tool. Three properties keep it thin:

- **No new mechanism — pure delegation.** The Command adds only a schema (`ref` + `context`) and a
  two-line handler (`resolveRef` → `resumeInCard(seed:)`); all the load-bearing logic (drain the inbox
  first, `HandoffSeed.fold`, kill + `--resume` the same session id, the seed as the opening positional
  turn) already shipped in C3. `SpawnInput`/`spawn` are untouched — stacked (`repo`/`branch`) and
  cross-agent (`agentId`) delegation were already covered by existing spawn params, and the *new-card*
  handoff/fork/fan-out start-actions are D3, not D1.
- **MCP is auto; the CLI is the one manual surface.** Because `orchestra-mcp` maps `registry.commands`,
  adding the Command auto-surfaces it as an MCP tool and keeps the E2E registry↔MCP parity assertion
  (`tools/list == CommandRegistry().names`) green with **no** test edit. The CLI is a hand-written
  `CLIRunner` switch (not auto-derived), so the verb is added by hand — one `case "handoff"` plus a
  `CLIHelp` line — the same one-Command-plus-one-CLI-case shape the [foundational registry-single-source
  refactor](10-roadmap.md) will eventually collapse.
- **The C2 full-set guard is honored.** Every `Command` added to the registry must also be registered in
  `CommandsTests`'s `expected` set or `main` reddens (the lesson C2 paid for); D1 adds `"handoff"` there,
  plus a round-trip test proving the Command dispatches to `resumeInCard`, carries the seed, and keeps the
  session id, and a CLI-surface smoke proving `orchestra handoff` *routes* (not "unknown command").

Like the forest PRs above, D1 is a single Command surface, not a whole axis, so it stays here as history
while the context-continuity row keeps its remainder open; the new-card handoff/fork/fan-out **UI +
start-actions** it left for D3 have since landed too (below). (As-built symbols:
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 4.)

The eleventh landed PR is **D2 — the delegation guidance skill + AGENTS.md**
(`notes/plans/2026-07-01-d2-delegation-skill.md`). Where D1 shipped a delegation *tool*, D2 ships the
**guidance an agent reads to decide when to reach for it** — a **prose/resource PR** with no new `Command`
and no launch-behavior change. It vendors two markdown resources under `Sources/OrchestraCore/Resources/`,
`.copy`-bundled into `Bundle.module` exactly like the offline Codex model table: `delegation-skill.md`
(a Claude **skill** — `name:`/`description:` frontmatter + body) and `delegation-agents.md` (a Codex
**AGENTS.md** — plain markdown, no frontmatter, read from the cwd). The heuristics are **identical** across
both variants; only the packaging and a couple of per-agent tool-surface notes differ (the Codex file notes
its send-keys nudge may take a beat to surface a conclusion). A minimal `enum DelegationDocs` (mirroring
`ModelCatalog`) loads a variant by name — `load(_:)` returns the raw text or `nil`, never throwing into a
launch path — and `forAgent(_:)` maps an agent id to its variant (`codex` → AGENTS.md, every other id incl.
Claude → the skill, so an unknown future agent still gets correct guidance). The guidance itself teaches
four things: **delegate vs. just continue** (pay the card + worktree + wake round-trip only for isolation /
parallelism / durability / a different agent / its own PR-branch; otherwise do it inline); **the four moves**
— handoff (same-card resume vs. new-card), fork, fan-out, wait — mapped to when each fits; **cards vs.
native subagents** — keep *both*, they are complementary: a **card** for durable · parallel · cross-agent ·
isolated work that outlives your turn and can land a PR, a **native subagent** (Claude's `Task` tool) for
ephemeral in-context read/search fan-out you fold back immediately — reach for a card *in addition to*,
never *instead of*, subagents; and the **reactive orchestration loop** (spawn stack head → background
`wait` → woken on conclusion → drain inbox → spawn next-in-stack). Two properties keep it contained:

- **Unwired *in D2* — since bound by skill-injection (below).** The `DelegationDocs` loader is additive
  resource plumbing — the `ModelCatalog` precedent — and is called from **no** launch path *in D2 itself*,
  which touches no `prepareToLaunch`/seed behavior, so its own launches are byte-for-byte unchanged. The
  binding turned out **not** to ride the D3 `SpawnInput.seed` (a per-*task* carrier) but each adapter's
  `prepareToLaunch` — a standing, seed-independent materialization added in the **skill-injection** PR
  (below), which keeps `start`/`resume` argv byte-identical.
- **Content is the test contract.** Because the heuristics are the deliverable, `DelegationDocsTests`
  asserts both variants load offline from a local file URL, that the skill carries YAML frontmatter
  (`name: orchestra-delegation`) while the AGENTS.md does not, that `forAgent` selects the right variant,
  and that the required anchors (`handoff`/`fork`/`fan-out`/`wait`/`spawn`/`card`/`in-context`/`durable`,
  the "*in addition to* … never *instead of*" keep-both line, and the Claude skill naming the `Task` tool)
  are present in each.

Like the forest PRs above, D2 is content + a loader, not a whole axis — it deepens axis 3's *richer
Orchestra→agent context injection* — so it stays here as history while the context-continuity row keeps its
remainder open; the new-card handoff/fork/fan-out **UI + start-actions** (D3) have since landed (below),
and auto-injecting this vendored guidance on launch — the one wire D2 left open — has since landed too
(**skill-injection**, below).
(`notes/designs/context-passing-topologies.md`;
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 4.)

The twelfth and thirteenth landed PRs are **T1 and T2 — the trust ledger and its human-grant surfaces**
(`notes/plans/2026-07-01-t2-trust-grant-surfaces.md`), the agent-provider forest's **permissioning**
track (design Area 3). Together they make "which directories may agents *write* in" a durable,
provider-agnostic, **human-owned** decision — see the [Trust boundaries](#trust-boundaries-allowlist-for-worktrees-sandbox-for-the-rest)
principle above. **T1** built the foundation: a `TrustLedger` (actor-over-JSON, sibling to `TaskStore` —
see [the trust ledger](03-data-model.md#the-trust-ledger-t1)) and `OrchestraService.resolveTrust(origin:cwd:repo:)`,
which maps a card's origin to a `TrustDecision` (`.trusted`/`.needsGrant`) and rides it onto the launch as
`AdapterContext.trustCwd` — moving trust resolution into the **core** so each adapter merely *applies* the
bool (Claude's `hasTrustDialogAccepted`, Codex's `config.toml` `trust_level`) and never reads the ledger.
**T2** then filled the `needsGrant` gap with the **grant surfaces**, and its decisions are the interesting
part:

- **The agent triggers; a human answers — core never self-grants.** The grant seam is a small
  `TrustGrantResolver` protocol whose production `SurfaceGrantResolver` approves `.cli`/`.mcp`/`.app`
  sources — where a human has *already* been gated at the surface — and **denies `.agent`/`.daemon`**.
  That one rule is simultaneously the **autonomy-exemption** (an autonomy card never blocks on trust) and
  the **no-self-grant** guarantee. `OrchestraService.grantTrust(_:source:)` (behind the new `trust`
  Command) is idempotent on an already-trusted path, records `grantedBy: .human` on approval, and
  **fail-closed throws `OrchestraError.trustDenied` (code 1011) on denial — recording nothing**.
- **No `--trust` flag anywhere — the grant is a surface, not a switch.** The human gate lives at each
  *surface* before the daemon `trust` command is ever relayed: the **CLI** `orchestra trust <path>` gates
  on `isatty` (a `[y/N]` confirm; refuses non-interactively with actionable help), and the **MCP** bridge
  special-cases the `trust` tool to `requestElicitation` back over its persistent session to the agent's
  own client, relaying only on `.accept` (no fallback — both v1 targets advertise `elicitation`). The
  `trust` Command auto-surfaces as an MCP tool (registry↔MCP parity stays green; `"trust"` was added to
  `CommandsTests.expected`, the C2 full-set guard), and the CLI verb is the one hand-wired surface.
- **Untrusted spawn is actionable, never blocking.** A `needsGrant` card still spawns — **sandboxed**
  (`trustCwd == false`) — and emits a `.warning` activity naming the cwd and the exact `orchestra trust`
  command to grant it. And `resolveTrust` **demotes a scratch dir that a foreign repo was cloned into**
  (a `.git` present) to borrowed semantics, so external code is never silently auto-trusted.

Automated coverage uses a **`StubGrantResolver`** only (approve/deny fixtures) — the live
`requestElicitation` dialog is a manual, out-of-scope acceptance (design rule O7), and **T2 adds no app
UI**: the `SpawnSheet` trust·read-only·cancel control is **D3** (which has since shipped it — below). Like
the forest PRs above, T1/T2 are the permissioning track, not a whole axis, so they stay here as history.
(As-built
symbols:
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 3.)

The final landed PR is **D3 — the delegation UI + new-card start-actions**
(`notes/plans/2026-07-01-d3-ui-cli-actions.md`). It is the **first surface set that *drives*** the three
shipped live-delivery seams from the board and CLI rather than adding another, closing out the
agent-provider forest — **all 15 PRs merged** (see
[the overnight build result](../notes/designs/agent-provider-interface/OVERNIGHT-RESULT.md)). It maps the
four [handoff/fork/fan-out topologies](#one-seed-four-topologies) to concrete actions:

- **Card actions** (act on the selected card, in the [inspector](07-app-ui.md#the-inspector) header):
  **Send** (the existing `send`, F3), **Handoff** (the existing `handoff`, F1 same-card resume), and
  **Fork** — a *new-card* `spawn` carrying a **seed** (the parent's authored slice).
- **Board action** (no card selected, board toolbar → `FanoutSheet`): **Fan-out** — a `batch-spawn` of one
  card per prompt line, each on a suffixed `<branch>-<n>`.

(The **Handoff / Fork / Fan-out buttons here were later removed** and **Send became an inbox editor** — see
the *agent-buttons simplification* at the end of this history; the tools they called are unchanged.)

Two small backend primitives carry it:

- **`SpawnInput.seed`** — a defaulted seed on the **`spawn`** and **`batch-spawn`** Commands (and the CLI's
  `spawn --seed`) that `OrchestraService.spawn` folds **ahead of the prompt** into the single launch
  positional, bounded by the same `StopDrain.maxPayloadChars` live-delivery cap. This is the *new-card*
  seed the Fork / Fan-out start-actions needed, and it is **distinct** from F1's resume-only `ctx.seed` —
  the adapters' `start`/`resume` argv are byte-identical, so Claude and Codex launches are unchanged.
- **`trustState`** — one new **read-only** Command (`{path}` → `{trusted}`) backed by
  `OrchestraService.isPathTrusted`, a pure `TrustLedger.isTrusted` query that **records nothing** (granting
  stays a human act, T2). The [`SpawnSheet`](07-app-ui.md#the-spawn-sheet) freeform mode queries it on every
  cwd change and, when the dir is untrusted, **forces read-only and shows the amber trust · read-only ·
  cancel notice** — the app trust control T2 deferred to D3. `BoardModel` gains
  `handoff`/`fork`/`fanout`/`trustState` wrappers.

Command discipline holds: only `trustState` is new, so it is added to `CommandsTests`'s `expected` set (the
C2 full-set guard) plus a hand-wired `CLIRunner` case, while MCP parity auto-derives; `SpawnSeedTrustTests`
pins the seed-fold order and the query's no-side-effect. D3 also lands the **app+daemon UX-e2e** harness
(`scripts/orch-ux-e2e.sh` with a `fixtures/fake-agent` symlink on `PATH` — no real vendor agent,
`USE_REAL_CLAUDE` unset — and an RPC-driven UC1–UC8 replay; the `screencapture` step is advisory per design
rule O6 and expected to fail on a headless window server). With D3 merged the **whole agent-provider forest
is shipped**; but as with every entry above it is a set of surfaces, not a whole axis — the model-providers
axis still owes Codex write access + approvals, and agent-integration its richer sub-status — so those rows
stay in [chapter 10](10-roadmap.md). (As-built symbols:
[agent-provider-interface/03-implementation.md](../notes/designs/agent-provider-interface/03-implementation.md)
"As-built (D3, shipped)".)

Landing after the forest closed is **enable-codex — making Codex startable** (commit `cf83921`, branch
`enable-codex`). The whole Codex backend — `CodexAdapter`, its models, rollout-tail telemetry, trust, and
resume/wake — had shipped (B1/B2/C4) but was **unreachable from any client**: the model list surfaced only
the default agent's catalog and `spawn` never received an agent (`SpawnInput.agentId` was never parsed).
This change is pure **reachability wiring**, no new launch behavior:

- **Model→adapter routing — Codex startable from a model-only pick.** `spawn` now resolves its adapter in
  three steps: an explicit **`agentId`** wins → else the adapter that **owns the chosen model**
  (new `AgentRegistry.adapter(forModel:)`, catalog-driven) → else the **configured default**. So the app's
  flat model picker, which sends only a model id, lands a `gpt-5-codex` selection on the Codex adapter.
- **Two surfaces for the picker.** `OrchestraService.models(nil)` now returns the **union** across every
  enabled adapter (default agent first), keeping the flat/default-model surfaces (e.g. Settings) working;
  a new `agents()` + `AgentInfo` + [`agents` RPC](05-command-reference.md#server-only-built-in-methods)
  expose the **per-agent grouping** (`id`/`name`/`icon` + each one's catalog) the
  [Spawn sheet's agent picker](07-app-ui.md#the-spawn-sheet) needs. The `spawn` Command gains an explicit
  **`agent`** param; the app's `SpawnSheet` gains an Agent segmented control that scopes the Model picker,
  and `BoardModel` fetches `agents` and threads `agent` through spawn (`ORCH_SHOW=spawn` seeds a mock agent
  catalog for the headless screenshot).
- **Read-only-first still holds.** Codex is now *launchable* but still ships **read-only only** — B1 clamps
  every Codex launch to `-s read-only -a never`. Write access + approvals remain the model-providers axis's
  live remainder ([chapter 10](10-roadmap.md)). New tests (`CodexAdapterTests`) pin `adapter(forModel:)`,
  the union `models()`, `agents()`, a model-only spawn landing on Codex, the default preserved, and an
  explicit `agentId` winning. (As-built: see [Agent adapters](04-cards-worktrees-sessions.md#agent-adapters).)

Landing after Codex became startable is **skill-injection — wiring `DelegationDocs` into the launch path**
(commit `7490e5e`, branch `deleg/04-skill-injection`;
`notes/plans/2026-07-01-delegation-skill-injection.md`). D2 had authored and vendored the delegation
guidance but left it inert — a loader bound to **no** launch path (the one open wire flagged repeatedly
above). This change binds it: every newly-launched card now receives its per-agent guidance. The decisions
that keep it safe:

- **`prepareToLaunch`, not the seed — a standing side effect keyed on the agent.** The materialization is a
  best-effort step each adapter adds to its existing `prepareToLaunch` (already the home of trust + Claude's
  read-only settings), *independent of `ctx.seed`* — so it reaches **every** card, not just handoff/fork
  ones. Content is chosen by `DelegationDocs.forAgent(id)` (keyed on the adapter's **own** `id`), so there is
  **no `if claude` / `if codex` branch in core**; the destination path is each adapter's own packaging
  knowledge, exactly as `ClaudeTrust` vs `CodexTrust` split. A shared
  `DelegationDocs.install(agentId:at:)` DRYs the load-and-write.
- **Each agent's native discovery location — no global install, no clobber, no dirty worktree.** Claude
  writes the **skill** to `<cwd>/.claude/skills/orchestra-delegation/SKILL.md` — the per-card project-skill
  location Claude Code discovers, under the gitignore-conventional `.claude/`, so the tracked worktree stays
  clean and **no `~/.claude` global install** is needed. Codex writes the **`AGENTS.md`** to the Orchestra-owned
  isolated `CODEX_HOME` — the **global (top) level** of Codex's `AGENTS.md` precedence, merged *above* any
  project `AGENTS.md` — so it never clobbers the user's own project `AGENTS.md` (one file per directory) nor
  touches the worktree.
- **Additive and behavior-preserving.** The delegation step **never throws** into the launch path
  (`install` mirrors the loader's nil/error tolerance: absent resource or any FS failure → no-op, returns
  `false`), and it is **idempotent** — a re-launch atomically overwrites Orchestra's own managed file with
  the same bytes. Crucially, `start`/`resume` argv and `env` stay **byte-identical**; the only new effect is
  the written file. Tests pin all of it: `DelegationDocsTests` covers `install` (writes the right variant,
  creates parent dirs, idempotent, graceful on an unwritable path); `AdapterTests`/`CodexAdapterTests` pin
  that Claude gets the skill variant and Codex the `AGENTS.md` variant, that Codex never writes into the
  worktree cwd, that it coexists with the trust `config.toml` write, and that argv/env are unchanged.

With this the [context-continuity](../notes/designs/context-passing-topologies.md) / agent-integration
delegation stack is fully wired end-to-end: the tools (D1), the surfaces that drive them (D3), the guidance
that says *when* to reach for them (D2), and now its automatic delivery on every launch. As with the entries
above it deepens axis 3's *richer Orchestra→agent context injection* rather than closing a whole axis, so
that row keeps its structured-sub-status remainder open ([chapter 10](10-roadmap.md)).

Landing after the forest is the **agent-buttons simplification + inbox editor**
(`notes/plans/2026-07-01-agent-buttons-simplification.md`;
[design](../notes/designs/2026-07-01-agent-buttons-simplification-design.md)). D3 had shipped a board
**Fan-out** button and per-card **Send / Handoff / Fork** buttons; this change prunes that surface back to
what the user actually reaches for, on the principle that the natural-language → MCP path already covers
the delegation moves and the board chrome should stay minimal. Three moves:

- **The Handoff, Fork, and board Fan-out buttons are removed** (`FanoutSheet.swift` deleted; the
  `BoardModel.handoff`/`fork`/`fanout` wrappers and `showFanout` state dropped). The underlying tools are
  **untouched** — `handoff`, `spawn`, and `batch-spawn` still work over MCP/CLI — so *reset the context*
  (handoff) and *explore a slice, then get data back* (fork) are served by just talking to the agent. The
  per-card header now shows only **Inbox** + **Archive** (plus View-changes / close).
- **Send → a durable [inbox](03-data-model.md#the-inbox-store-f3) editor.** The one-shot Send composer
  becomes an **Inbox** popover that manages the whole queue: list, **reorder** (up/down chevrons), inline
  **edit**, **delete**, and **append**. The `Inbox` actor gains `remove`/`update`/`reorder`, exposed as
  four registry commands — [`inbox` / `inbox-edit` / `inbox-remove` / `inbox-reorder`](05-command-reference.md#registry-commands)
  — which therefore surface as MCP tools and CLI verbs for free (the same registry-single-source property
  every command has). `reorder` refills only the target card's slots in the shared append-ordered array,
  so other cards' interleaving is preserved; a non-permutation of the card's ids is rejected, not silently
  dropped.
- **The delegation docs steer the removed Fork's use case.** Both bundled guidance files
  (`delegation-skill.md` / `delegation-agents.md`) now surface `spawn`'s `cwd` + `access: readOnly` + `seed`
  options and default an **exploratory/planning fork to a lightweight read-only freeform card in the same
  directory** (no worktree, nothing to clean up) that reports back via `wait` + inbox drain — so the
  natural-language path reliably reproduces what the Fork button did. Worktree-fork (`spawn` with
  `repo` + `branch`) stays documented for when the fork will change files and wants its own branch/PR.

Deliberate scope cuts: **no live count badge** on the Inbox button (the count shows inside the popover
header, `Inbox — N queued` — a live badge would need a new per-card subscription), and reorder uses
up/down **chevrons**, not drag-and-drop (more robust inside a themed popover; the `inbox-reorder` backend
is gesture-agnostic, so drag can be added later with no server change). Like the entries above this is a
UI/surface change, not a whole axis, so it stays here as history.

Landing after the forest is **axis 7 — code review on the board** (commit `bf1c7c1`;
`notes/designs/code-review-on-board/`), the **first whole extensibility axis built end to end** rather
than a forest sub-PR — so its [roadmap row](10-roadmap.md) migrates here. It surfaces an agent's changes
*inside* Orchestra — a diffstat on the card footer and a read-only rendered diff in the inspector — so a
glance or quick review no longer requires "View changes → Zed". The build is deliberately **lean** (refined
at the 2026-07-01 L3 gate): there is **no** structured/machine-readable diff payload and **no** MCP `diff`
verb — an agent already has a shell in its cwd and runs `git diff` itself, so re-serving it would be dead
weight. Its decisions:

- **Generic `DiffProvider` seam — difftastic default, git fallback.** A `DiffProvider` protocol
  (`Sources/OrchestraCore/Diff/`) has two read-only jobs, both from git: a cheap `DiffStat`
  (`git diff --numstat`) for the footer, and a rendered **ANSI** diff string for the inspector — produced by
  **difftastic** (`difft`, structural/syntax-aware, `DFT_DISPLAY=inline`) when it is on `PATH`, else git's
  own colored diff (`-c color.ui=always`). Both emit ANSI, so one app-side SGR→`AttributedString` parser
  (`ANSIText`) renders either; `difft` is **never a hard dependency** (`Proc.toolExists` gate). Both jobs key
  off the same `git diff <range>`, so the footer stat and the inspector render never disagree (untracked,
  never-added files show in neither until staged/committed — a documented limitation).
- **App-only endpoints, not registry commands.** `diffText`/`diffStat` are **server-only built-in
  `ControlServer` methods** (the `openInZed` shape) — the inspector is the only consumer, so they are
  deliberately **not** `CommandRegistry` commands and therefore never surface as MCP or CLI tools (see
  [server-only methods](05-command-reference.md#server-only-built-in-methods)). Everything guards on the
  shipped `Task.origin`: a non-`.worktree` card (`.scratch`/`.borrowed`, which may have no git baseline)
  degrades cleanly to no stat and an empty Diff view — never a fabricated stat. `diffText` caps a huge
  render (256 KB) with an "open in Zed" sentinel so the pane stays responsive.
- **Baseline toggle; parent-relative is a thin stub.** The diff is taken against one of `DiffBase` —
  `.working` (vs `HEAD`), `.branch` (vs the default-branch merge-base — the PR diff, and the default), or
  `.parent` (vs the card's parent branch, for a stacked card). `parentBranch` ships as a **nil-default
  stub** on `Task` — `.parent` falls back to `.branch` until
  [stacked branches](../notes/designs/stacked-branches-and-guardian-handoff.md) populates it — and the
  inspector only offers the **Parent** segment once a card carries one. This makes axis 7 the seam
  [axis 5](10-roadmap.md) (the automated PR-review phase) reviews through.
- **Event-driven refresh off the normalized funnel — adapter-agnostic.** The footer diffstat recomputes on
  real per-card activity, not a timer: `OrchestraService.report()` — the one normalized funnel every adapter
  feeds (it sees a `StatusReport`, never a `tool_name`) — calls a per-card `scheduleDiffStat` debounce
  (~750 ms) after it persists a delta, plus on card selection. `recomputeDiffStat` persists + emits
  `taskUpserted` **only when the stat changed**, so the funnel → schedule → recompute → emit chain
  self-terminates (no feedback loop). Because the trigger keys off *activity*, not which tool ran, Claude and
  Codex refresh identically with **no adapter code touched** — the same adapter-agnostic principle A2's
  telemetry seam established.

The app side adds the **Agent | Diff** toggle to the [inspector header](07-app-ui.md#the-inspector), the
`DiffInspectorView` ([in-app diff view](07-app-ui.md#the-in-app-diff-view): baseline toggle + ANSI-rendered
read-only diff + "Open in Zed"), and the [card-footer diffstat](07-app-ui.md#cards) (`Nf +N −M`, green/red,
replacing the model name when a stat exists). Editing stays Zed's job (an explicit non-goal), and **inline
review comments/approvals remain [axis 5](10-roadmap.md)**. The two new `Task` fields are recorded in
[chapter 3](03-data-model.md#the-task-card). Layered design:
[`notes/designs/code-review-on-board/`](../notes/designs/code-review-on-board/index.md) (L1 design → L2
contract → L3 implementation + L3 tests).

Landing after the forest is **reopen — un-finishing a Done card**
(commit `c13e718`, branch `reopen-done-cards`). Archived cards were **terminal and read-only** — the only
actions on a Done row were copy-the-chat-link / copy-the-branch. This change makes archive reversible: a
**Reopen** action recreates the run dir the archive reclaimed and brings the agent back live. Its
decisions keep it small and provider-neutral:

- **Recreate the run dir, then reuse the existing recovery primitives — no new revival path.**
  `OrchestraService.reopen(_:source:)` first gives the card its cwd back per `origin` (the archive
  removed it): `worktrees.ensure(repo:branch:)` for a `.worktree` card — trivially possible because
  [archive keeps the branch](#ownership-orchestra-deletes-only-what-it-made) — a `mkdir` for `.scratch`,
  and nothing for `.borrowed` (never removed). It then unarchives the card (`archived=false`,
  `status=.waiting`, `deadReason`/`deadDetail` cleared) **keeping its stored column**, and revives the
  agent by delegating straight to the shipped [`resume`/`restart`](04-cards-worktrees-sessions.md#recovery-resume-and-restart)
  seam — `resume` when `isResumable` (the transcript survived), else a blank `restart`. So reopen adds
  *zero* revival mechanism; it is a thin composition over the crash-recovery code the daemon already runs.
- **Agent-agnostic and idempotent.** Because it rides `resume`/`restart` — which every adapter already
  implements — there is **no** Claude/Codex branch in `reopen`; a Codex card reopens through the same
  call. A non-archived card is returned unchanged, so a double-fire is a no-op.
- **One Command, surfaced everywhere; the app closes the loop.** A single `reopen` `Command`
  (`{ref}` → the updated `Task`) is added to the [registry](05-command-reference.md#registry-commands),
  so it auto-surfaces as an MCP tool and a CLI verb (the C2 full-set guard: `"reopen"` is added to
  `CommandsTests.expected`, plus a dispatch test). In the app, `BoardModel.reopen(_:)` calls the RPC,
  applies the returned card to move it **off the Done list onto the board**, selects it (opening the live
  inspector), and closes the [Done popover](07-app-ui.md#onboarding-settings-recovery-and-popovers); the
  popover row gains an accent **Reopen** pill. `ReopenTests` pins the resumable / non-resumable /
  idempotent branches. Like the entries above, this is a lifecycle/surface change, not a whole axis, so it
  stays here as history.

Also landing after the forest is **`send-wakes-idle-card` — waking an idle native (Claude) card via
resume-seed** (commit `7d8037c`, branch `send-wakes-idle-card`). C1/C2 wired `send` to `wake` a card right
after enqueuing, but the `nativeReinvoke` (Claude) transport treated *every* idle case as a no-op push: it
assumed a background `orchestra wait` whose exit the harness re-invokes on. That holds for the **reactive
fan-out** (a watcher card always has a live wait), but **not** for a plain `send`/queue onto a genuinely idle
`.waiting` Claude card — with no in-flight turn and no live wait, the message sat inbox-durable until some
unrelated future turn. This closes that gap without adding a fourth mechanism:

- **The idle-no-wait case wakes via resume-seed — reusing F1, not a new path.** `wake`'s `nativeReinvoke`
  branch now calls `resumeSeedWake`, which relaunches the card through the shipped
  [`resumeInCard`](#one-seed-four-topologies) primitive (the same engine `handoff` uses): `claude --resume`
  with the drained inbox folded into the opening turn. Delivery still rides the durable inbox (F3) — the
  relaunch only *starts the turn*, so no content is ever typed into the TUI. It is gated to fire **only** when
  the card is `.waiting`, resumable, not archived, not mid-relaunch (`recovering`), and **not** already
  watching children — because a watcher's background `orchestra wait` will re-invoke it on exit, and
  relaunching would kill that live wait and break the fan-out. So Claude now has **two** `nativeReinvoke`
  mechanisms, keyed on wait-state: harness-reinvoke (a live wait) vs resume-seed relaunch (no wait).
- **One `wake`, no per-caller special-casing.** `send` (a just-queued message) and the fan-out `concludeCard`
  (a child's conclusion) now funnel through the **single** `wake(id)` primitive. To keep the watcher no-op
  correct, `concludeCard` now wakes the watcher **before** clearing its registry entry, so `wake` sees the
  still-live wait and defers to the wait-exit re-invoke rather than racing it with a resume that would kill
  the wait. `wake` is idempotent and non-intrusive by construction — it acts only on a card that is idle with
  no turn already coming (`recovering` is claimed synchronously so a concurrent wake defers) — so it can be
  called freely.
- **The send-keys pane-gate is now adapter-owned.** So core's generic wake never names a Codex type, the
  detect-and-defer pane check moved behind a new defaulted `Adapter.canNudge(pane:)` (default `false` — a
  non-send-keys agent never reads its pane); `CodexAdapter` delegates to `CodexComposer`, which moved under
  `Sources/OrchestraCore/Agents/`, and `sendKeysWake` now asks the adapter rather than `CodexComposer`
  directly.

`SendWakeTests` pins the resume-seed happy path plus the running / live-watcher / unresumable defers. This
remains a **stopgap on both transports** — Codex's `sendKeys` leans on a fragile TUI pane-scraper and
Claude's no-wait wake on a heavy relaunch; the agent-agnostic target is a real `controlChannel` `turn/start`
RPC (the already-frozen enum variant) that retires both, tracked in
[agent-provider-interface.md §8](../notes/designs/agent-provider-interface.md). Like the entries above, this
is one live-delivery refinement, not a whole axis, so it stays here as history.

Also landing after the forest is the **column-aware SessionStart orientation + self-move guidance**
(commit `dad7451`, branch `automatic-column`). Until now an agent had to be *told* which phase it was in;
this makes the board tell it. At session start each agent is handed a one-line **orientation** naming its
board **column** (Plan/Implementation/Review), its **access mode** (read-write vs read-only), and its own
**card id** — so a card opened in any lane starts on the right footing without instruction, and can `move`
itself as the work changes phase. It deepens axis 3's *richer Orchestra→agent context injection* on the
existing hook channel, and its decisions keep it agent-agnostic and non-coercive:

- **The brief is pure, live, and agent-agnostic.** `SessionBrief.sentence(column:access:shortId:)` composes
  the orientation as a pure, synchronous value — trivially testable and callable from the `_report` hook
  process — and the daemon exposes it through a new **`sessionBrief` RPC**
  ([server-only, not a Command](05-command-reference.md#server-only-built-in-methods), mirroring `drain`)
  that reads the card's column **live** from the store. So a **reopened or dragged card reflects its
  *current* lane**, not the launch-time `startIn` — the whole point is that the board is the source of truth
  the agent reads at open time.
- **It rides the SessionStart hook's `additionalContext`, not a positional turn.** The brief is *not* folded
  into the launch prompt — a hook covers both a launched-with-prompt card and an idle provisional one
  **without submitting an unsolicited turn**. Claude's existing SessionStart hook (`_report --event session`)
  additionally prints the brief as `hookSpecificOutput.additionalContext`, additively — the session→waiting
  report is byte-for-byte unchanged. A mid-turn `compact` is skipped (the agent already has its bearings).
  This is the open-time counterpart to the F3 Stop-drain's turn-end inbox inject.
- **Codex reaches it through a Claude-parity hook, orientation-only.** Codex now gets its own managed
  hooks file: `HooksRenderer.renderCodex` renders the bundled `codex-hooks.json` (SessionStart →
  `_report --event orient`) at daemon start and on config change, and each Codex card's `prepareToLaunch`
  installs it into the pinned `$CODEX_HOME/hooks.json` — but **never clobbers a foreign user `hooks.json`**
  (`CodexHooks.installIfSafe` writes only when the destination is absent or already Orchestra's, keyed on
  the `_report --event orient` sentinel). The `orient` event is **orientation-only** — it prints the brief
  and sends **no** telemetry, so Codex telemetry stays the [daemon-side rollout tail](#shipped-feature-history)
  (B2) rather than gaining a second, conflicting source. Same brief, byte-identical envelope, both agents.
- **A nudge, not a leash.** The sentence tells the agent to begin on its column's footing and to **keep its
  column honest** by moving itself (`move <thisCard> --col plan|impl|review`) as work crosses a real phase
  boundary — a *suggestion*, since a stale column misleads whoever is supervising, but never a constraint.
  The delegation [skill + AGENTS.md](04-cards-worktrees-sessions.md#the-codex-adapter) gain a matching
  "your column is your phase — start on it, and keep it honest" section, so the auto-injected guidance
  (skill-injection, above) and the SessionStart orientation reinforce the same behavior.

`SessionBriefTests` pin the brief's column/mode wording and the Claude `additionalContext` envelope, and a
control round-trip test pins the `sessionBrief` RPC. Verified end-to-end against an isolated daemon. Like the
entries above, this is one context-injection increment, not a whole axis, so it stays here as history while
axis 3's structured sub-status + more agent commands stay open ([chapter 10](10-roadmap.md)). (It also
foreshadows [axis 1's configurable columns](10-roadmap.md) and [axis 5's automated review phase](10-roadmap.md):
once agents route on their own column, a phase-driven column becomes actionable.)

The roadmap of what comes next — the extensibility axes the system is being designed toward — is
[chapter 10](10-roadmap.md).
