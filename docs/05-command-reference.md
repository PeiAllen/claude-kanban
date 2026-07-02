# 5. Command reference

Every action Orchestra exposes lives in **one place** — the `CommandRegistry`
(`Sources/OrchestraCore/Commands.swift`). The CLI dispatches to it, the MCP bridge generates one tool
per entry from it, and the app calls the same methods. This chapter is the canonical list, plus the
server-only built-in methods and the wire protocol.

A `ref` argument is any [card reference](03-data-model.md#identity-and-references): a short id, a full
UUID, or an `orchestra://task/<shortId>-<slug>` URI.

## Registry commands

| Command | Parameters | What it does |
|---------|------------|--------------|
| `list` | `col?` (`plan`/`impl`/`review`) | List cards, optionally filtered by column. Read-only; not logged to the activity feed (it would flood it). |
| `spawn` | `prompt` (required), `repo?`, `branch?`, `model?`, `agent?` (`claude-code`/`codex`), `col?` (`plan`/`impl`), `cwd?`, `access?` (`readWrite`/`readOnly`), `scratch?` (bool), `seed?` | Spawn a new agent. Worktree mode (`repo`+`branch`), freeform mode (`cwd`), or scratch mode (`scratch:true`). Auto-titles from the prompt; status starts `waiting` if provisional, else `running`. `agent` picks the adapter backend; omit it and Orchestra **infers the agent from `model`** (the adapter that catalogs that model id), else falls back to the configured default agent — this is what makes **Codex** startable from a model-only selection. A `seed` (PR D3) is authored context folded **ahead of** the prompt into the launch turn (bounded by the 10 000-char live-delivery cap) — this is how a **Fork** hands a new card the parent's slice. |
| `move` | `ref` (required), `col` (required: `plan`/`impl`/`review`) | Move a card to a column (auto-orders within it). |
| `send` | `ref` (required), `message` (required) | Queue a message to the card's durable **inbox** (F3), then **wake** the card (F2) so an *idle* agent drains it now rather than at its next unprompted turn. Content still rides the inbox (Stop-hook drain / session seed / resume seed), never typed into tmux — `wake` only starts a turn. Also the **append** action of the app's [inbox editor](07-app-ui.md#the-inspector). |
| `inbox` | `ref` (required) | List a card's pending [inbox](03-data-model.md#the-inbox-store-f3) messages (`{id, text, createdAt}`) in FIFO order. Read-only (`Inbox.peek`); backs the [inbox editor](07-app-ui.md#the-inspector)'s list. |
| `inbox-edit` | `ref` (required), `id` (required: message UUID), `text` (required) | Edit the text of one queued message in place (`Inbox.update`); `id`/`cardId`/`createdAt` are preserved. |
| `inbox-remove` | `ref` (required), `id` (required: message UUID) | Remove one queued message by id (`Inbox.remove`). |
| `inbox-reorder` | `ref` (required), `ids` (required: array of message UUIDs) | Reorder a card's queued messages (`Inbox.reorder`); `ids` is the full new order and must be a permutation of the card's pending message ids. Refills exactly that card's array slots, so other cards' interleaving is preserved. |
| `wait` | `refs` (required: array of refs), `watcher?` | Block until **one** of the watched cards concludes — reaches Done or a clean agent exit — and return that conclusion; the caller re-issues on the cards that remain. Backs the reactive fan-out (F2 / merge-watch). If `watcher` is set, each conclusion also coalesces into that card's [inbox](03-data-model.md#the-inbox-store-f3) (F3) and wakes it. |
| `handoff` | `ref` (required), `context` (required) | Clean-context handoff (F1): kill and resume **this** card in a fresh process, keeping the **same** session id, seeded with `context` folded ahead of the card's pending inbox. Delegates to the C3 [resume-in-card seam](09-design-decisions.md#shipped-feature-history) — a *resume, not a blank restart*. |
| `status` | `ref` (required) | Return the card plus its derived tmux liveness. |
| `archive` | `ref` (required) | Finish a card: kill the session, clean the run dir per origin, set `done`/`archived`. |
| `reopen` | `ref` (required) | Bring an archived (Done) card back onto the board: recreate the run dir the archive reclaimed, unarchive (keeping its column, clearing stale dead state), then `resume` its transcript when resumable else `restart` a fresh session. Idempotent on a non-archived card. Backs the [Done popover](07-app-ui.md#onboarding-settings-recovery-and-popovers)'s **Reopen** button. |
| `restart` | `ref` (required) | Fresh blank session in the same worktree (new session id; no prompt re-handed). |
| `resume` | `ref` (required) | Re-attempt `claude --resume` of the card's existing session. |
| `shell` | `ref` (required) | Open a shell window in the card's `cwd`; returns the tmux target to attach to. |
| `inspect` | `ref` (required) | Open a throwaway **read-only** `claude` in the card's `cwd` (locked-down sandbox, edit tools denied, no hooks). |
| `closeShell` | `ref` (required), `window` (required, e.g. `shell-1`) | Close a shell window opened via `shell`. |
| `exec` | `ref` (required), `cmd` (required), `timeout?` (seconds) | Run one shell command in the card's `cwd` via `/bin/sh -c`; returns stdout/stderr/exit. Worktree cards are allowlist-gated; borrowed/scratch are sandbox-trusted. Default timeout 120 s. |
| `sessions` | `ref` (required) | Debug handles: every tmux target (socket/session/windows with attach lines), the agent-native session id, transcript path, prior ids, and the resume argv. |
| `batch-spawn` | `tasks` (required: array of `{prompt, repo, branch, model?, col?, seed?}`) | Spawn many agents at once; failed entries are reported, the rest still spawn. The **fan-out** primitive: one card per prompt line, each on a suffixed `<branch>-<n>`, each optionally seeded. Reachable from the CLI/MCP only — the board **Fan-out** button D3 shipped was [later removed](09-design-decisions.md#shipped-feature-history). |
| `trust` | `path` (required) | Grant a **human's** write-trust for a directory (record it in the [trust ledger](03-data-model.md#the-trust-ledger-t1)) so agents may run there with write access. A human must approve — the MCP tool elicits a decision from the agent's own client; the CLI verb gates on an interactive terminal. An agent can only *trigger* it, **never self-grant** (`.agent`/`.daemon` sources are denied → `trustDenied`). |
| `trustState` | `path` (required) | **Read-only** query (PR D3): returns `{trusted}` for a directory — a pure [trust ledger](03-data-model.md#the-trust-ledger-t1) lookup (`OrchestraService.isPathTrusted`) that **records nothing**. The app [`SpawnSheet`](07-app-ui.md#the-spawn-sheet) uses it to warn and force read-only on an untrusted freeform dir; granting stays the human-only `trust` above. |

### Notes on key commands

- **`spawn` picks the mode from its params.** `scratch:true` → a scratch card; a `cwd` → a borrowed/
  freeform card; `repo`+`branch` → a worktree card. `access:"readOnly"` makes any of them read-only.
- **`archive` cleans up by origin.** Worktree: `git worktree remove` (kept if dirty, and only if no
  other live worktree card shares it). Scratch: unconditional `rm -rf` (double-gated). Borrowed: nothing
  is deleted.
- **`reopen` is the inverse — recreate the run dir, then revive.** Archive is no longer terminal:
  `reopen` re-`ensure`s the worktree (the archive kept its branch) or re-`mkdir`s the scratch dir,
  unarchives the card back to its original column, then reuses the existing `resume`/`restart`
  recovery primitives — a *resume* when the transcript survived, else a blank *restart*. Agent-agnostic
  (no adapter-specific code) and idempotent. See [recovery, resume, and restart](04-cards-worktrees-sessions.md#recovery-resume-and-restart).
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
  folded into the opening turn. (`notes/plans/2026-07-01-c1-inbox-stopdrain.md`; the wake dispatcher is
  C2/C4, extended by `send-wakes-idle-card`.)
- **`wait` is a conclusion-watch, read from real card state — never git.** As of C2 (F2 / merge-watch),
  `wait` blocks until the first of `refs` **settles terminal** — moved to Done/archived, or a clean agent
  exit — and returns that `Conclusion` (`{cardId, ref, kind ∈ {done, exited}}`). A transient crash that is
  later revived is deliberately **not** a conclusion, and conclusion is read from real card state, never
  `git merge-base` (which false-positives a 0-commit branch as "merged"). `OrchestraService` is the single
  authority that marks a card concluded (from `archive`→Done and the clean-exit report branch); `MergeWatch`
  is a **subscriber** it feeds — no polling, no file/git watching. `wait` is single-shot on purpose: when
  one child concludes it returns, and the caller (an orchestrator card) re-issues on the cards that remain,
  so several children can conclude concurrently without a barrier. With `watcher` set, each conclusion also
  routes into that card's durable inbox (coalescing at its next turn-end) and wakes it (F2). This is what
  the reactive fan-out / stacked-PR DAG composes from. (`notes/plans/2026-07-01-c2-wake-mergewatch.md`;
  `notes/designs/agent-provider-interface/02-contract.md` §Area 4.)
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
  across all four topologies — and the card-vs-native-subagent line — is vendored as a per-agent
  delegation skill / AGENTS.md (PR D2) and now **auto-materialized into every launched card** by each
  adapter's `prepareToLaunch` (skill-injection; Claude a `.claude/skills` project skill, Codex an
  `AGENTS.md` in its isolated `CODEX_HOME`), see [chapter 9](09-design-decisions.md#shipped-feature-history).
  (`notes/plans/2026-07-01-d1-mcp-delegation-tools.md`;
  `notes/designs/agent-provider-interface/02-contract.md` §Area 4.)
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
  (`notes/plans/2026-07-01-t2-trust-grant-surfaces.md`;
  `notes/designs/agent-provider-interface/02-contract.md` §Area 3.)

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
| `report` | The internal endpoint the agent's `_report` helper POSTs `StatusReport`s to. |
| `diffText` | Render a card's worktree diff as an ANSI string for the inspector's [Diff view](07-app-ui.md#the-inspector) (`{ref, base?}` → String, `base` one of `working`/`branch`/`parent`, default `branch`). **App-only** (axis 7): the `openInZed`-shape internal endpoint, deliberately **not** a registry command, so it never surfaces as an MCP/CLI tool — an agent reads a diff by running `git diff` in its own cwd. Non-`.worktree` cards return `""`; a huge render is capped (256 KB) with an "open in Zed" sentinel. |
| `diffStat` | Recompute + return a card's footer diffstat (`{ref, base?}` → `{filesChanged, insertions, deletions}` or null). The on-selection refresh; the same **app-only** internal endpoint (also refreshed event-driven off the report funnel — see [chapter 9](09-design-decisions.md#shipped-feature-history)). |
| `drain` | Internal F3 plumbing (**not user-facing**): the Claude Stop hook fetches the card's pending [inbox](03-data-model.md#the-inbox-store-f3) payload here. Resolves `ref`, calls `drainForStop`, and returns `{reason: <payload-or-null>}`. Deliberately not a registry command, so it is invisible to the CLI/MCP. |

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
