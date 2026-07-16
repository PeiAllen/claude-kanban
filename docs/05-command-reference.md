# 5. Command reference

Every action Orchestra exposes lives in **one place** — the `CommandRegistry`
(`Sources/OrchestraCore/CommandRegistry.swift`), with the shared verb schema catalog (`kind`/`phaseGate`)
in `Sources/OrchestraKit/CommandCatalog.swift`. The CLI dispatches to it, the MCP bridge generates one tool
per entry from it, and the app calls the same methods. This chapter is the canonical list, plus the
server-only built-in methods and the wire protocol.

A `ref` argument is any [card reference](03-data-model.md#identity-and-references): a short id, a full
UUID, or an `orchestra://task/<shortId>-<slug>` URI.

## Registry commands

| Command | Parameters | What it does |
|---------|------------|--------------|
| `list` | `col?` (`plan`/`impl`/`review`) | List cards, optionally filtered by column. Read-only; not logged to the activity feed (it would flood it). |
| `spawn` | `prompt` (required), `repo?`, `branch?`, `model?`, `agent?` (`claude-code`/`codex`), `col?` (`plan`/`impl`), `cwd?`, `access?` (`readWrite`/`readOnly`), `scratch?` (bool), `seed?` | Spawn a new agent. Worktree mode (`repo`+`branch`), freeform mode (`cwd`), or scratch mode (`scratch:true`). Auto-titles from the prompt; on readiness the card lands `live(.waiting(.humanTurn))` if provisional, else `live(.running)`. `agent` picks the adapter backend; omit it and Orchestra **infers the agent from `model`** (the adapter that catalogs that model id), else falls back to the configured default agent — this is what makes **Codex** startable from a model-only selection. A `seed` (PR D3) is authored context folded **ahead of** the prompt into the launch turn (bounded by the 10 000-char live-delivery cap) — this is how a **Fork** hands a new card the parent's slice. |
| `move` | `ref` (required), `col` (required: `plan`/`impl`/`review`) | Move a card to a column (auto-orders within it). |
| `send` | `ref` (required), `message` (required) | Queue a message to the card's durable **inbox** (F3), then **wake** the card (F2) so an *idle* agent drains it now rather than at its next unprompted turn. Content still rides the inbox (Stop-hook drain / session seed / resume seed), never typed into tmux — `wake` only starts a turn. A message over `StopDrain.maxMessageChars` (~the 10 000-char delivery budget) is **rejected** with `invalidParams` at enqueue — put large content in a worktree file and reference it — so any accepted message delivers whole. Also the **append** action of the app's [inbox editor](07-app-ui.md#the-inspector). |
| `inbox` | `ref` (required) | List a card's pending [inbox](03-data-model.md#the-inbox-store-f3) messages (`{id, text, createdAt}`) in FIFO order. Read-only (`Inbox.peek`); backs the [inbox editor](07-app-ui.md#the-inspector)'s list. |
| `inbox-edit` | `ref` (required), `id` (required: message UUID), `text` (required) | Edit the text of one queued message in place (`Inbox.update`); `id`/`cardId`/`createdAt` are preserved. |
| `inbox-remove` | `ref` (required), `id` (required: message UUID) | Remove one queued message by id (`Inbox.remove`). |
| `inbox-reorder` | `ref` (required), `ids` (required: array of message UUIDs) | Reorder a card's queued messages (`Inbox.reorder`); `ids` is the full new order and must be a permutation of the card's pending message ids. Refills exactly that card's array slots, so other cards' interleaving is preserved. |
| `wait` | `refs` (required: array of refs), `watcher?` | Block until **one** of the watched cards concludes — reaches Done, a read-only freeform/scratch delegated card finishes its agent turn, or a clean agent exit — and return that conclusion; the caller re-issues on the cards that remain. Backs the reactive fan-out (F2 / merge-watch). If `watcher` is set, each conclusion also coalesces into that card's [inbox](03-data-model.md#the-inbox-store-f3) (F3) and wakes it. |
| `handoff` | `ref` (required), `context` (required), `model?` | Clean-context handoff (F1): kill and resume **this** card in a fresh process, keeping the **same** session id, seeded with `context` folded ahead of the card's pending inbox. Delegates to the C3 [resume-in-card seam](09-design-decisions.md#shipped-feature-history) — a *resume, not a blank restart*. `model` additionally **re-seats** the card onto that model while the context rides across — the self-escalation path (see [the `--model` re-seat](#the---model-re-seat)). |
| `status` | `ref` (required) | Return the card plus its derived tmux liveness. |
| `archive` | `ref` (required) | Finish a card: record the intent (`phase = .archived(teardownComplete: false)`, `archived=true`) and return; the reconciler's Teardown stepper kills the session, cleans the run dir per origin, and flips the phase to `.archived(teardownComplete: true)`. |
| `reopen` | `ref` (required) | Bring an archived (Done) card back onto the board: recreate the run dir the archive reclaimed, unarchive (keeping its column, clearing stale dead state), then `resume` its transcript when resumable else `restart` a fresh session. Idempotent on a non-archived card. Backs the [Done popover](07-app-ui.md#onboarding-settings-recovery-and-popovers)'s **Reopen** button. |
| `restart` | `ref` (required), `model?` | Fresh blank session in the same worktree (new session id; no prompt re-handed). `model` **re-seats** the card onto that model for the new session — deliberately *without* the old context (see [the `--model` re-seat](#the---model-re-seat)). |
| `resume` | `ref` (required), `model?` | Re-attempt resuming the card's existing agent session (each adapter's own resume argv — `claude --resume`, `codex resume`). `model` **re-seats** the card onto that model as it resumes (see [the `--model` re-seat](#the---model-re-seat)). |
| `shell` | `ref` (required) | Open a shell window in the card's `cwd`; returns the tmux target to attach to. |
| `inspect` | `ref` (required) | Open a throwaway **read-only** `claude` in the card's `cwd` (locked-down sandbox, edit tools denied, no hooks). |
| `closeShell` | `ref` (required), `window` (required, e.g. `shell-1`) | Close a shell window opened via `shell`. |
| `exec` | `ref` (required), `cmd` (required), `timeout?` (seconds) | Run one shell command in the card's `cwd` via `/bin/sh -c`; returns stdout/stderr/exit. Worktree cards are allowlist-gated; borrowed/scratch are sandbox-trusted. Default timeout 120 s. |
| `sessions` | `ref` (required) | Debug handles: every tmux target (socket/session/windows with attach lines), the agent-native session id, transcript path, prior ids, and the resume argv. |
| `batch-spawn` | `tasks` (required: array of `{prompt, repo, branch, model?, col?, seed?}`) | Spawn many agents at once; failed entries are reported, the rest still spawn. The **fan-out** primitive: one card per prompt line, each on a suffixed `<branch>-<n>`, each optionally seeded. Reachable from the CLI/MCP only — the board **Fan-out** button D3 shipped was [later removed](09-design-decisions.md#shipped-feature-history). |
| `trust` | `path` (required) | Grant a **human's** write-trust for a directory (record it in the [trust ledger](03-data-model.md#the-trust-ledger-t1)) so agents may run there with write access. A human must approve — the MCP tool elicits a decision from the agent's own client; the CLI verb gates on an interactive terminal. An agent can only *trigger* it, **never self-grant** (`.agent`/`.daemon` sources are denied → `trustDenied`). |
| `trustState` | `path` (required) | **Read-only** query (PR D3): returns `{trusted}` for a directory — a pure [trust ledger](03-data-model.md#the-trust-ledger-t1) lookup (`OrchestraService.isPathTrusted`) that **records nothing**. The app [`SpawnSheet`](07-app-ui.md#the-spawn-sheet) uses it to warn and force read-only on an untrusted freeform dir; granting stays the human-only `trust` above. |

### Verb kinds and the phase gate

Every command above also classifies itself as one of three **kinds** (`CommandSchema.kind`,
`Sources/OrchestraKit/CommandCatalog.swift`) and declares a **`phaseGate`** — a deny-by-default *allow-set*
of the target card's `Phase.Kind` (see [the data model](03-data-model.md#the-task-card)). Both are
required on every schema, so a new verb must classify itself before it can ship:

- **Query** — read-only, retry-free, never touches `phase`. `list`, `inbox`, `status`, `tree`, `sessions`,
  `trustState`, `capture`.
- **Mutation** — completes inline and returns its result; may hop off-actor (a shell command, a tmux
  attach) but never changes `phase`. `move`, `send`, `inbox-edit`/`-remove`/`-reorder`, `wait`, `shell`,
  `inspect`, `closeShell`, `exec`, `send-keys`, `trust`, `set-parent`, `synced`, `shipped`,
  `merge-request`, `borrow`, `release`.
- **Convergence** — the only kind that touches `phase`. The synchronous half persists an **intent** — one
  `transition()` call — and returns immediately; the reconciler's phase-keyed
  [`PhaseStepper`s](02-architecture.md#the-convergence-model) drive the card the rest of the way. `spawn`,
  `batch-spawn`, `archive`, `reopen`, `resume`, `restart`, and `handoff` are Convergence — none of them
  awaits a worktree checkout, an agent bring-up, or a teardown duty before its RPC returns.

`phaseGate` is enforced once, at the single dispatch chokepoint (`CommandRegistry.dispatch`): for any
non-query verb that names a target `ref`, the card's *current* `Phase.Kind` is checked against the
allow-set **before** the handler runs — a gated-out call throws `phaseGated` and never reaches its handler.
A `Phase.Kind` absent from a verb's set is denied by default, so a future kind is denied until a schema is
updated to admit it (the fail-safe direction). `spawn`/`batch-spawn`/`trust`/`trustState`/`wait`/`list` name
no single pre-existing target card, so they skip the gate.

The seven Convergence verbs and what each persists:

| Verb | Allowed phases | Intent persisted |
|------|-----------------|-------------------|
| `spawn`, `batch-spawn` | *(creates a card — ungated)* | new card enters `.creatingWorktree` |
| `archive` | any (idempotent re-archive) | `→ .archivedPending` (+ `archived = true`) |
| `reopen` | `archivedPending`, `archivedComplete` | `→ .creatingWorktree` |
| `restart`, `resume` | `live`, `dead`, `relaunching` | `→ .relaunching` |
| `handoff` | `live`, `dead` | `→ .relaunching` (seeded) |

The interactive/session verbs — `shell`, `inspect`, `closeShell`, `exec`, `send-keys` — plus several
tree-lineage verbs (`set-parent`, `synced`, `shipped`, `merge-request`, `borrow`, `release`) share a
`live`/`dead`-only gate, so they are **denied on the being-born phases** — `creatingWorktree`, `launching`,
`relaunching` — where there is no worktree or session yet to shell into, inspect, or run a command in.

### Notes on key commands

- **`spawn` picks the mode from its params.** `scratch:true` → a scratch card; a `cwd` → a borrowed/
  freeform card; `repo`+`branch` → a worktree card. `access:"readOnly"` makes any of them read-only.
- **`archive` cleans up by origin.** Worktree: `git worktree remove` (kept if dirty, and only if no
  other live worktree card shares it). Scratch: unconditional `rm -rf` (double-gated). Borrowed: nothing
  is deleted.
- **`reopen` is the inverse — record the reopen intent, then let the reconciler revive.** Archive is no
  longer terminal: `reopen` transitions the card `→ .creatingWorktree` through the funnel (unarchiving it
  back to its original column and clearing dead metadata) and returns; the reconciler's steppers then
  re-materialize the run dir (re-`ensure` the worktree — the archive kept its branch — or re-`mkdir` the
  scratch dir) and relaunch, with `deriveLaunchFlavor` choosing a *resume* when the transcript survived
  (`isResumable`) else a blank launch. Agent-agnostic (no adapter-specific code) and idempotent. See
  [recovery, resume, and restart](04-cards-worktrees-sessions.md#recovery-resume-and-restart).
- **`exec` vs `shell`.** `exec` is a one-shot non-interactive command with a captured result; `shell`
  opens an interactive window you attach a terminal to. `inspect` is `shell` + a read-only agent.
- **`send` is durable, not keystrokes.** As of C1 (F3), `send` enqueues to the card's persistent
  [inbox](03-data-model.md#the-inbox-store-f3) rather than typing into the agent's tmux window. The
  message is drained into the agent at its next turn-end (the Claude Stop hook), survives a daemon
  restart, and coalesces with other queued messages. **After enqueueing, `send` also `wake`s the card**
  (the same F2 `wake` the [merge-watch](09-design-decisions.md#shipped-feature-history) uses), so a message
  to an *idle* agent starts a turn immediately instead of sitting durable until the agent's next unprompted
  turn. The wake only *triggers* a turn — content still rides the inbox, never the keystroke — and no-ops
  when the card is busy, drafting, mid-relaunch, or already watching children on a background `orchestra
  wait`. For a send-keys (Codex) card it fires the content-free nudge; for a `nativeReinvoke` (Claude) card
  that is genuinely idle with no live wait it **resume-seeds** — relaunches `claude --resume` with the inbox
  folded into the opening turn. (The wake dispatcher is C2/C4, extended by `send-wakes-idle-card`.)
- **`wait` is a conclusion-watch, read from real card state — never git.** As of C2 (F2 / merge-watch),
  `wait` blocks until the first of `refs` **settles terminal** — moved to Done/archived, a read-only
  freeform/scratch delegated card reports task completion (Codex `task_complete` / `turn_complete`, Claude
  `TaskCompleted` — not Claude `Stop`), or a clean agent exit — and returns
  that `Conclusion` (`{cardId, ref, kind ∈ {done, exited}}`). A transient crash that is
  later revived is deliberately **not** a conclusion, and conclusion is read from real card state, never
  `git merge-base` (which false-positives a 0-commit branch as "merged"). `OrchestraService` is the single
  authority that marks a card concluded (from `archive`→Done, the delegated turn-completion branch, and the clean-exit report branch); `MergeWatch`
  is a **subscriber** it feeds — no polling, no file/git watching. `wait` is single-shot on purpose: when
  one child concludes it returns, and the caller (an orchestrator card) re-issues on the cards that remain,
  so several children can conclude concurrently without a barrier. With `watcher` set, each conclusion also
  routes into that card's durable inbox (coalescing at its next turn-end) and wakes it (F2). This is what
  the reactive fan-out / stacked-PR DAG composes from.
- **An idle card is not a concluded one — nothing reclaims it for you.** Those three branches are the
  *whole* of conclusion authority, so a worktree child told to `send` a result back and stop (a review-pair
  reviewer, a research fork) ends its turn `waiting`, not concluded: it keeps its agent process, worktree,
  tmux session, and branch until someone acts. The daemon never garbage-collects a live-but-idle card, so
  the parent that spawned it must `archive` it once it has taken the result.
- **`handoff` is the F1 seam's first surface.** As of D1, `handoff` is a thin `Command` that resolves the
  ref and delegates to `OrchestraService.resumeInCard(seed:)` (shipped by C3) — it does **not** start a
  new card. The named card is killed and resumed in a fresh, clean-context process that keeps its session
  id (so the vendor transcript carries forward), with `context` folded ahead of the card's drained pending
  inbox as the resumed session's opening turn. It auto-surfaces as an MCP tool (registry↔MCP parity stays
  green with no test edit); the CLI verb is the one hand-wired surface (`orchestra handoff <ref>
  <context...>`). This is the *same-card* (replace-the-thread) topology; the new-card **Fork/Fan-out**
  start-actions (a `spawn`/`batch-spawn` with a `SpawnInput.seed`) plus the Handoff/Send **card actions**
  landed as PR D3 (see [chapter 9](09-design-decisions.md#shipped-feature-history)). The dedicated
  Handoff/Fork/Fan-out **buttons have since been removed** — those moves stay reachable via the
  natural-language → MCP path — and the per-card Send button became an
  [inbox editor](07-app-ui.md#the-inspector) (the *agent-buttons simplification*, ch. 9). The *when-to-use* guidance for `spawn`/`handoff`/`wait`
  across all four topologies — and the card-vs-native-subagent line — is vendored as shared per-agent
  guidance (PR D2). Each launch packages it through the provider-native surface: Claude as
  `.claude/skills` project skills and Codex as launch-scoped `developer_instructions`, so Codex leaves its
  global `AGENTS.md` alone; see [chapter 9](09-design-decisions.md#shipped-feature-history).
- **`trust` is human-only — an agent can never self-grant.** As of T2, `trust` records a *human* grant
  into the [trust ledger](03-data-model.md#the-trust-ledger-t1), filling the `needsGrant` gap the core's
  `resolveTrust` (T1) leaves for a borrowed dir the user hasn't approved (see
  [Trust boundaries](09-design-decisions.md#trust-boundaries-allowlist-for-worktrees-sandbox-for-the-rest)).
  The record only happens after a human approves at an **interactive surface** — the MCP tool elicits a
  decision from the agent's own client (`requestElicitation`), and the CLI verb `orchestra trust <path>`
  gates on a tty and refuses non-interactively (there is **no `--trust` flag**). Core's
  `SurfaceGrantResolver` is the gate of last resort: it approves `.cli`/`.mcp`/`.app` sources (a human
  already answered) and **denies `.agent`/`.daemon`** (→ `trustDenied`, code 1011) — one rule that is
  both the *autonomy-exemption* and the *no-self-grant* guarantee. Granting an already-trusted path is an
  idempotent no-op. See [CLI & MCP](06-clients-cli-mcp.md#the-orchestra-cli) for the two surfaces.

### The `--model` re-seat

`restart`, `handoff`, and `resume` each take an optional **`model`** (the CLI spelling is `--model <id>`;
the MCP tool arg is generated from the same [catalog](#registry-commands) schema, so both surfaces carry
it). It **re-seats a card onto a different model in place** — same card, same worktree, same branch,
same session lineage — which is how an agent that discovers its task needs a stronger model **escalates
itself** instead of spawning a successor card. Both vendors were probed for real: `claude --resume <sid>
--model X` and `codex resume <sid> -m X` genuinely re-bind the model.

- **`handoff --model` carries the context across** (the summary rides as the resumed session's opening
  turn) — the escalation path. **`restart --model` deliberately drops it** (a blank session is the point).
  **`resume --model`** re-attaches the existing session on the new model.
- **Own-adapter models only.** The id is resolved against the card's **own** agent's catalog
  (`resolveModelOverride`, `OrchestraService+Recovery.swift`), because `agentId` is pinned by the vendor
  transcript being resumed — a Claude card handed a Codex id would become `claude --model gpt-…` and die at
  the process. An unknown id (or an explicitly empty one) is **rejected with `invalidParams`** *before* the
  first mutation, so a refused re-seat leaves the card completely untouched — notably its durable inbox,
  which `handoff` otherwise drains destructively. The vendor's **dated** form of a catalog id
  (`claude-haiku-4-5-20251001` for `claude-haiku-4-5`) resolves to the catalog entry, keeping the launch id
  canonical and preserving the model's catalog metadata — including the `contextWindow` that is the `ctxPct`
  denominator for the *token-reporting* agents (Codex; Claude pushes its percentage directly); a mistyped
  suffix is an error, not a substitution.
- **The launch reads the intent, not the display field.** The override is persisted as
  [`Task.pendingModel`](03-data-model.md#the-task-card) — the *launch intent*, mirroring `pendingSeed` —
  and it is `pendingModel`, never `model`, that `finishLaunch` builds the argv from. `model` is written
  eagerly too, so the board reflects the re-seat at once, but nothing depends on that write surviving: a
  stale report may revert it, and the `.live` landing re-asserts it from the intent. See
  [report() vs the launch intent](09-design-decisions.md#report-vs-the-launch-intent-pendingmodel-and-the-epoch-fence)
  for why the intent has to live in its own field.

## Server-only built-in methods

These are handled directly by `ControlServer` and are **not** registry commands (so today they are
visible to the app but not auto-exposed as MCP tools — unifying this is part of
[Roadmap axis 3](10-roadmap.md)):

| Method | Purpose |
|--------|---------|
| `ping` | Liveness check. |
| `version` | Daemon version. |
| `subscribe` | Register the connection for the event stream; replays the recent-activity ring buffer. |
| `getConfig` / `setConfig` | Read / patch the daemon `Config` (re-derives the resolver + worktree manager). |
| `models` | The selectable models. With an `agentId` param, just that adapter's catalog; without, the **union across every enabled adapter** (default agent's models first) so a flat picker can list Claude + Codex together. |
| `agents` | The selectable **agents** for the Spawn sheet's agent picker: each enabled adapter's `{id, name, icon, models}` (default agent first) — the per-agent grouping of the flat `models` union. |
| `archivedList` | The archived (Done) cards, newest first. |
| `openInZed` | Open a card's worktree in Zed, with a branch-vs-base multi-file diff. |
| `openNotes` | Open a card's **worktree** as an **Obsidian vault** — the same `~/.claude/open-obsidian-vault.sh` recipe the `/open-notes` Claude command runs (seed a default config, register the vault, launch Obsidian). Seeds one Obsidian tab per note: the gitignored `notes/` vault (plans + designs, scanned off disk since git can't see ignored files) plus any other markdown the branch changed, capped. `OrchestraService.openNotes` passes the card's worktree (`Task.cwd`); `Launcher.openNotes` path-gates it through the resolver before running the script. Backs the inspector's [**Open notes** button](07-app-ui.md#the-inspector). |
| `report` | The internal endpoint the agent's `_report` helper POSTs `StatusReport`s to. |
| `diffText` | Render a card's worktree diff as an ANSI string for the inspector's [Diff view](07-app-ui.md#the-inspector) (`{ref, base?}` → String, `base` one of `working`/`branch`/`parent`, default `branch`). **App-only** (axis 7): the `openInZed`-shape internal endpoint, deliberately **not** a registry command, so it never surfaces as an MCP/CLI tool — an agent reads a diff by running `git diff` in its own cwd. Non-`.worktree` cards return `""`; a huge render is capped (256 KB) with an "open in Zed" sentinel. |
| `diffStat` | Recompute + return a card's footer diffstat (`{ref, base?}` → `{filesChanged, insertions, deletions}` or null). The on-selection refresh; the same **app-only** internal endpoint (also refreshed event-driven off the report funnel — see [chapter 9](09-design-decisions.md#shipped-feature-history)). |
| `hook` | Internal hook-channel plumbing (**not user-facing**): the single entry point the `_report` edge client calls, replacing the former `report`/`drain`/`sessionBrief`. Takes a typed `{ref, event, report?, source?}` and dispatches both directions in the adapter-free `OrchestraService.handleHook` — applies the telemetry `report` (send), and for `session` returns the live orientation ([`SessionBrief`](04-cards-worktrees-sessions.md), skipped on `compact`) or for `stop` the drained [inbox](03-data-model.md#the-inbox-store-f3) — returning `{response: <HookResponse-or-null>}` for the client to encode. The drain payload carries a channel-neutral **provenance header** and `[k/N]`-numbers a batch, delivering only the *whole messages that fit* the 10 000-char budget (overflow stays queued). Deliberately not a registry command, so it never surfaces on the CLI/MCP. |

## The wire protocol

Clients speak **newline-delimited JSON-RPC 2.0** over the unix-domain socket (default
`~/Library/Application Support/Orchestra/orchestrad.sock`, override `$ORCHESTRA_SOCK`):

```jsonc
// request  (id omitted ⇒ notification, no reply)
{ "jsonrpc": "2.0", "id": 1, "method": "spawn", "params": { … }, "source": "cli" }

// response
{ "jsonrpc": "2.0", "id": 1, "result": { … } }
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32000, "message": "…" } }

// server → client event (after subscribe)
{ "jsonrpc": "2.0", "method": "event", "params": { "taskUpserted": { … } } }
```

`source` (`app`/`cli`/`mcp`/`agent`) is how the activity feed attributes each action. Error codes:
`-32700` parse error, `-32601` method not found, `-32000` internal/typed `OrchestraError`. Dates are
ISO-8601 on the wire.

For how the CLI and MCP turn these into commands you can run, see [CLI & MCP](06-clients-cli-mcp.md).
