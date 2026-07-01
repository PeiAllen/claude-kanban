# 3. Data model

This chapter is the reference for Orchestra's persisted state: the `Task` (card) schema, the enums that
classify it, how it is stored and migrated, the configuration and on-disk paths, and the error and
event types. The types live in `Sources/OrchestraCore/Model.swift`, `Config.swift`, `TaskStore.swift`,
`Inbox.swift`, and `Errors.swift`.

## The `Task` (card)

A `Task` is the single persisted record behind every card. Its fields:

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `UUID` | Identity. The tmux session is `orchestra-<id>`. |
| `title` | `String` | Display-authoritative title (derived from the first prompt). |
| `titleProvisional` | `Bool` | If `true`, the next real prompt may replace the title. |
| `desc` | `String` | Live one-line blurb pushed by the agent's hooks (pane-parse fallback). |
| `repo` | `String` | Allowlisted repo root (worktree cards). Context-only for borrowed cards. |
| `branch` | `String` | Working branch (worktree cards). |
| `cwd` | `String` | **The one directory** the agent and its shells run in. |
| `origin` | `CardOrigin` | `worktree` \| `scratch` \| `borrowed` — how `cwd` came to be. |
| `access` | `CardAccess` | `readWrite` \| `readOnly`. |
| `agentId` | `String` | Which adapter runs it (default `"claude-code"`). |
| `model` | `AgentModel` | Selected model (launch id + display label + family). |
| `startIn` | `StartIn` | `plan` \| `impl` — where the agent began. |
| `column` | `Column` | Current board column. |
| `order` | `Int` | Sort position within the column. |
| `status` | `AgentStatus` | `waiting` \| `running` \| `done` \| `dead`. |
| `deadReason` | `DeadReason?` | Set together with `status = .dead`. |
| `deadDetail` | `String?` | Extra detail (e.g. for `resumeFailed`). |
| `ctxPct` | `Double` | Context-window usage, 0–100 (Claude pushes it via the statusLine; Codex derives it from the rollout tail ÷ its offline model window). |
| `agentSessionId` | `String?` | The agent-native session id (current). |
| `priorSessionIds` | `[String]` | Superseded session ids (after `/clear`, resume rollover, etc.). |
| `initialPrompt` | `String` | The spawn prompt, persisted verbatim. |
| `archived` | `Bool` | `true` once finished — off the board, in the Done popover. |
| `createdAt` / `updatedAt` | `Date` | Timestamps. |

### Classifying enums

- **`Column`** — `plan`, `impl`, `review` (display: Plan / Implementation / Review). There is no `done`
  case; finishing sets `status = .done` + `archived = true`.
- **`AgentStatus`** — `waiting`, `running`, `done`, `dead`.
- **`DeadReason`** — why a card died:
  - `agentExited` — a `SessionEnd` with reason exit/logout (usually mid-life and resumable),
  - `sessionVanished` — the tmux session is gone with no `SessionEnd` (crash or external kill),
  - `rebootUnrevived` — the startup sweep couldn't auto-revive it,
  - `resumeFailed` — a resume attempt failed (see `deadDetail`).
- **`CardOrigin`** — `worktree`, `scratch`, `borrowed`.
- **`CardAccess`** — `readWrite`, `readOnly`.
- **`StartIn`** — `plan` or `impl`.

### Identity and references

A card can be named three ways, all resolvable by `TaskRef`:

- **short id** — first 6 chars of the UUID, lowercased,
- **full UUID**,
- **URI** — `orchestra://task/<shortId>-<slug>`, where `slug` is the slugified title (this is the
  "Copy chat link" value and the deep-link the app registers).

`resolve(ref, in: tasks)` throws `unknownTask` if nothing matches and `ambiguousTask` if a short id
matches more than one card.

## Persistence and migration

`TaskStore` persists the whole board as a **pretty-printed JSON array** of `Task` at
`~/Library/Application Support/Orchestra/tasks.json`.

- **Atomic writes.** Every mutation writes a `.tmp` file and `replaceItemAt`s it into place, creating
  the parent directory as needed.
- **Corruption-safe load.** A malformed `tasks.json` is moved aside to `.bak` and the store starts from
  `[]` rather than crashing.
- **Operations.** `all`, `get`, `create` (auto-assigns `order`), `nextOrder`, `move` (re-orders into a
  column), `update` (applies a mutation and bumps `updatedAt`), `remove`.

### Schema migration

The model is **forward- and backward-compatible** through `Codable` defaults so old `tasks.json` files
load cleanly:

- The legacy `worktree: String` field is **decode-only**; it maps onto the newer `cwd`. On encode the
  store always writes `cwd` + `origin`, never the bare `worktree` (the PR2 schema change — see
  [Design decisions](09-design-decisions.md)).
- Optional fields decode with sane defaults: `titleProvisional=false`, `desc=""`, `origin=.worktree`,
  `access=.readWrite`, `agentId="claude-code"`, `status=.running`, `ctxPct=0`, `priorSessionIds=[]`,
  `archived=false`.

This is why a board created before borrowed/scratch cards existed still opens: every new field has a
default, and the only pre-existing cards are `.worktree`.

## The inbox store (F3)

Alongside `tasks.json`, the daemon keeps a second durable store — the **`Inbox`** (`Inbox.swift`), a
sibling to `TaskStore` built on the same actor-over-JSON pattern (lazy load, atomic write, malformed →
`.bak` + `[]`). It holds a flat, append-ordered array of `InboxMessage` (`{id, cardId, text, createdAt}`)
at `~/Library/Application Support/Orchestra/inbox.json`, giving **FIFO-per-card** delivery via a stable
filter on `cardId`. `enqueue` appends, `peek` reads without removing, and `drain` returns + removes all of
a card's pending messages. Messages persist until drained, so they survive a daemon restart.

This is the durable merge-back channel for **F3** (see [Design decisions](09-design-decisions.md#one-seed-four-topologies)):
`send` enqueues here instead of typing into tmux, and the Claude Stop hook drains it into the agent at its
next turn-end (`OrchestraService.drainForStop`, the [`drain` RPC](05-command-reference.md#server-only-built-in-methods),
and the [`_report` Stop-drain](06-clients-cli-mcp.md#the-hooks--_report-channel)). The C1 plan is
[`notes/plans/2026-07-01-c1-inbox-stopdrain.md`](../notes/plans/2026-07-01-c1-inbox-stopdrain.md).

## Configuration and paths

`Config` (`Config.swift`) is loaded/saved by `ConfigStore` at `config.json` with the same atomic-write,
default-on-malformed discipline.

| Setting | Default | Meaning |
|---------|---------|---------|
| `reposRoot` | `~/Documents/Projects` | Allowlist anchor — where repos are scanned and permitted. |
| `worktreesRoot` | `~/.orchestra/worktrees` | Where worktrees are cut. |
| `defaultModel` | (unset) | Preferred model launch id. |
| `defaultAgentId` | `"claude-code"` | Which adapter new cards use. |
| `allowlist` | `[]` | Extra permitted directories beyond the two roots. |
| `maxConcurrentRevivals` | `4` | Throttle on simultaneous session revivals at startup. |
| `revivalGraceSeconds` | `15` | How long a resume waits for the `SessionStart(resume)` confirmation. |
| `statusLineMode` | `passthroughGlobal` | How the agent's status line is rendered (see below). |
| `customStatusLine` | (unset) | The command for `statusLineMode = .custom`. |

Derived paths (all keyed off `$HOME`, so state follows the user, not the bundle):

| Path | Location |
|------|----------|
| Data dir | `~/Library/Application Support/Orchestra/` |
| Socket | `…/orchestrad.sock` |
| Config | `…/config.json` |
| Tasks | `…/tasks.json` |
| Inbox | `…/inbox.json` |
| Log | `…/orchestrad.log` |
| Rendered hooks | `…/claude-hooks.json` |
| Worktrees | `~/.orchestra/worktrees/<repo>/<branch>` |
| Scratch root | `~/.orchestra/scratch/` (not user-configurable) |
| tmux socket | `orchestra` (override with `$ORCHESTRA_TMUX_SOCKET`) |

`allowedRoots` is `[reposRoot, worktreesRoot] + allowlist` — the set `PathResolver` checks every repo
and worktree path against (see [the security boundary](04-cards-worktrees-sessions.md#pathresolver-the-security-boundary)).

### Status-line modes

`statusLineMode` chooses how Orchestra renders the agent's status line:

- **`passthroughGlobal`** — render the user's own `~/.claude/settings.json` `statusLine` verbatim
  (falling back to the Orchestra default on failure/timeout).
- **`custom`** — render `customStatusLine` (same fallback).
- **`orchestraDefault`** — the minimal built-in (`model · ctx%`); the universal fallback.

## Errors

`OrchestraError` is the typed error surface returned over RPC:

`unknownTask`, `ambiguousTask`, `unknownAgent`, `pathNotAllowed`, `branchInUse`, `toolMissing`
(git/tmux/claude/zed not found), `worktreeDirty`, `resumeFailed`, `zedMissing`, `invalidParams`, and
`io` (filesystem/subprocess failure).

## Events and the activity feed

The daemon emits an `Event` after every meaningful mutation:

- `taskUpserted(Task)` — a card was created or changed,
- `taskRemoved(UUID)` — a card was removed,
- `activity(ActivityItem)` — a feed entry.

An `ActivityItem` is a timestamped, task-linked record with a **source** (`app`/`cli`/`mcp`/`agent`/
`daemon`) and a **kind** (`spawned`/`moved`/`archived`/`statusChanged`/`dead`/`recovered`/`command`/
`warning`). The `warning` kind is the surface for advisory notices — currently the **authMode soft-warn**
emitted when a subscription-auth adapter fans out past its concurrency threshold (see
[Design decisions](09-design-decisions.md#authmode-advise-on-fan-out-never-cap)); it never blocks the
action it warns about. The app's Activity popover renders these; the daemon keeps the most recent 200 in
a ring buffer that is replayed to new subscribers.

### The report types

The agent's `_report` channel carries a `StatusReport`, a unified patch with two halves:

- the **event half** (`EventReport`) — causally-ordered fields: `sessionId`, `transcriptPath`,
  `sessionSource`, `endReason`, `promptText`;
- the **snapshot half** (`SnapshotReport`) — a seq-stamped atomic snapshot: `ctxPct`, `modelId`,
  `modelDisplay`, `status`, `desc`, `sessionName`.

How those halves are merged into the card (event half applied unconditionally and ordered; snapshot
half seq-gated against a monotonic cursor) is detailed in
[Cards, worktrees & sessions](04-cards-worktrees-sessions.md) and `OrchestraService+Report.swift`.
