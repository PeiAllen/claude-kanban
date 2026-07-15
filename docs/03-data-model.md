# 3. Data model

This chapter is the reference for Orchestra's persisted state: the `Task` (card) schema, the enums that
classify it, how it is stored and migrated, the configuration and on-disk paths, and the error and
event types. The types live in `Sources/OrchestraKit/` (`Model.swift`, `Config.swift`, `Errors.swift`)
and `Sources/OrchestraCore/` (`TaskStore.swift`, `Inbox.swift`).

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
| `parentBranch` | `String?` | Stacked-branch parent — the `.parent` [diff baseline](#classifying-enums). A **cache** derived from the git-config lineage store: `set-parent`, `spawn --base`, and converge write it; nil means the card has no parent link. |
| `treeStat` | `TreeStat?` | Daemon-maintained child-lineage status for the branch tree (`synced` / `restackNeeded` / …); nil = none or not yet computed. |
| `cwd` | `String` | **The one directory** the agent and its shells run in. |
| `origin` | `CardOrigin` | `worktree` \| `scratch` \| `borrowed` — how `cwd` came to be. |
| `access` | `CardAccess` | `readWrite` \| `readOnly`. |
| `agentId` | `String` | Which adapter runs it (default `"claude-code"`). |
| `model` | `AgentModel` | Selected model (launch id + display label + family). |
| `startIn` | `StartIn` | `plan` \| `impl` — where the agent began. |
| `column` | `Column` | Current board column. |
| `order` | `Int` | Sort position within the column. |
| `phase` | `Phase` | The **persisted lifecycle SSOT** (Stage 2 — replaces the retired `status`/`waitReason` pair). `creatingWorktree` \| `launching` \| `live(RunState)` \| `relaunching` \| `dead(DeadReason)` \| `archived(teardownComplete:)`. The `transition()` funnel is its sole writer. |
| `sessionEpoch` | `Int` | Monotonic per-card session generation, bumped on each (re)launch entry so a stale signal (a late hook, a liveness poll) from a superseded session is fenced out. |
| `phaseChangedAt` | `Date` | When `phase` last changed — drives phase-relative timers and terminal-dwell checks. |
| `pendingSeed` | `String?` | Handoff/seeded-wake seed staged for the NEXT (re)launch, written by `resume(seed:)` and consumed+cleared on the `.live` landing (see [migration & persistence](#persistence-and-migration)). |
| `pendingModel` | `String?` | A [`--model` re-seat](05-command-reference.md#the---model-re-seat) staged for the NEXT (re)launch (`restart`/`handoff`/`resume`), consumed+cleared on the `.live` landing exactly like `pendingSeed`. Separate from `model` because it is the **launch intent**, and it is the one thing `report()` cannot clobber: the report path owns `model` and is not epoch-fenced, so the *dying* session's last statusline would otherwise revert the override before the relaunch read it (see [migration & persistence](#persistence-and-migration) and [ch. 9](09-design-decisions.md#report-vs-the-launch-intent-pendingmodel-and-the-epoch-fence)). |
| `deadReason` | `DeadReason?` | Set together with `phase = .dead(_)`; carries the terminal reason. |
| `deadDetail` | `String?` | Extra detail (e.g. for `resumeFailed`/`spawnFailed`). |
| `ctxPct` | `Double` | Context-window usage, 0–100 (Claude pushes it via the statusLine; Codex derives it from the rollout tail ÷ its offline model window). |
| `diffStat` | `DiffStat?` | Daemon-maintained branch diffstat (`{filesChanged, insertions, deletions}`) for the card footer (axis 7). Nil for a non-git / zero-change / not-yet-computed card. |
| `agentSessionId` | `String?` | The agent-native session id (current). |
| `priorSessionIds` | `[String]` | Superseded session ids (after `/clear`, resume rollover, etc.). |
| `initialPrompt` | `String` | The spawn prompt, persisted verbatim. |
| `archived` | `Bool` | `true` once finished — off the board, in the Done popover. |
| `createdAt` / `updatedAt` | `Date` | Timestamps. |

### Classifying enums

- **`Column`** — `plan`, `impl`, `review` (display: Plan / Implementation / Review). There is no `done`
  case; archiving now routes through the `transition()` funnel like every other `Convergence` verb: `archive`
  persists the intent (`phase = .archived(teardownComplete: false)`, companion `archived = true` in the same
  patch) and returns, and the reconciler's `TeardownStepper` drives `.archivedPending → .archivedComplete`
  (kill the session, release a borrow/worktree, reclaim the run dir, cancel debounces/watches, nudge
  children). The `archived` Bool mirror is retained alongside `phase` for display/filtering. A read-only
  freeform/scratch delegated card
  can also conclude to `.dead(.completed)` without being archived when its agent reports task completion
  (for example Codex `task_complete` / `turn_complete` or Claude `TaskCompleted`, not Claude `Stop`).
  [`reopen`](05-command-reference.md#registry-commands)
  reverses it — `archived` back to `false`, phase walked back onto the board via the funnel,
  `deadReason`/`deadDetail` cleared — while keeping the card's stored `col`, so it returns to the column
  it was archived from.
- **`Phase`** — the persisted lifecycle enum (Stage 2). Wire form is a `{ "name": <case>, "detail": <value> }`
  object; `detail` present only for the payload-carrying cases (`live`, `dead`, `archived`):
  - `creatingWorktree` — materializing the cwd (worktree / scratch / borrow); **every** spawn enters here,
  - `launching` — cwd ready, bringing the agent session up,
  - `live(RunState)` — the agent is up; sub-state in `RunState`,
  - `relaunching` — a restart/resume in flight,
  - `dead(DeadReason)` — terminal-ish: session gone, awaiting recovery,
  - `archived(teardownComplete: Bool)` — off the board; the Bool distinguishes an archive whose
    worktree/session teardown is still pending from one fully torn down.
  A coarse `Phase.Kind` (`creatingWorktree`/`launching`/`live`/`relaunching`/`dead`/`archivedPending`/
  `archivedComplete`) flattens the `archived` Bool for stepper dispatch and terminal/bump checks;
  `isTerminal` is `dead(*)` or `archived(*)`.
- **`RunState`** — the running sub-state of a `live` card (the mid-life detail that used to live in
  `status`/`waitReason`): `running` (actively working) or `waiting(WaitReason)` (blocked, carrying *why*).
  Custom `{name, detail?}` Codable, `detail` only on `.waiting`.
- **`WaitReason`** — why a card is `.live(.waiting(_))`: `permission` (blocked on tool approval) or
  `humanTurn` (finished its turn / idle, waiting on the human).
- **`PhaseDisplayKey`** — a coarse **display-only, non-wire, non-Codable** label derived from `phase` on
  demand (`Task.phaseDisplay`), never persisted, so the display vocabulary can evolve without touching the
  durable model: `starting` / `launching` / `relaunching` / `running` / `idle` / `needsPermission` /
  `dead` / `done`. The being-born phases surface honestly (a spawning card reads `.starting`/`.launching`,
  not a fake `.running`). `Task.waitReason` derives the `WaitReason` (nil unless `.live(.waiting(_))`).
- **`DeadReason`** — why a card died (set alongside `phase = .dead(_)`):
  - `agentExited` — a `SessionEnd` with reason exit/logout (usually mid-life and resumable),
  - `sessionVanished` — the tmux session is gone with no `SessionEnd` (crash or external kill),
  - `rebootUnrevived` — the startup sweep couldn't auto-revive it,
  - `resumeFailed` — a resume attempt failed (see `deadDetail`),
  - `completed` — the agent finished its work and the card was retired to Done,
  - `spawnFailed` — the initial spawn never came up (worktree/launch failure before first life).
- **`CardOrigin`** — `worktree`, `scratch`, `borrowed`.
- **`CardAccess`** — `readWrite`, `readOnly`.
- **`StartIn`** — `plan` or `impl`.
- **`DiffBase`** — the baseline for a card's [code-review diff](09-design-decisions.md#shipped-feature-history)
  (axis 7): `working` (vs `HEAD`), `branch` (vs the default-branch merge-base — the PR diff, the default),
  or `parent` (vs the card's `parentBranch`, for a stacked card; falls back to `branch` when it has no parent link).

### Identity and references

A card can be named three ways, all resolvable by `TaskRef`:

- **short id** — first 6 chars of the UUID, lowercased,
- **full UUID**,
- **URI** — `orchestra://task/<shortId>-<slug>`, where `slug` is the slugified title (this is the
  "Copy chat link" value and the deep-link the app registers).

`resolve(ref, in: tasks)` throws `unknownTask` if nothing matches and `ambiguousTask` if a short id
matches more than one card.

## Persistence and migration

`TaskStore` persists the whole board as a **pretty-printed JSON envelope** `{ "rev": Int, "tasks": [Task] }`
at `~/Library/Application Support/Orchestra/tasks.json`. The `rev` is the board-global monotonic version
(PR1) stamped on every event and snapshot; a pre-upgrade **bare-array** `tasks.json` still loads (decoded
as the tasks with `rev = 0` — the one on-disk compat kept).

- **Atomic writes.** Every mutation writes a `.tmp` file and `replaceItemAt`s it into place, creating
  the parent directory as needed. `persist()` is the single funnel that bumps `currentRev` and encodes the
  `{rev, tasks}` envelope.
- **Element-wise, corruption-tolerant load.** `load()` decodes the envelope's `tasks` **element-by-element**
  through a `FailableTask` wrapper: a single throwing/corrupt record **drops itself** (logged) and the rest
  of the board loads intact. The board is moved aside to `.bak` and started from `[]` **only when the
  top-level JSON is itself unparseable** — never for a single bad record.
- **Operations.** `all`, `get`, `create` (auto-assigns `order`), `nextOrder`, `move` (re-orders into a
  column), `update` (applies a mutation, bumps `updatedAt`, and — since PR1 — skips the persist + rev-bump
  on a no-op mutation), `remove`.

### Schema migration — the one-time `status`/`waitReason` → `phase` mapping

The Stage-2 flag-day retired the `status`/`waitReason`/`AgentStatus` triple in favor of `phase` +
`RunState`. The one-time on-disk migration that carries a pre-Stage-2 `tasks.json` forward lives **inside
`Task.init(from:)`** — the card's own tolerant custom decoder — **not** a separate `LegacyStoredBoard`
structural pass (superseding the plan's approach, because Task 2.1 had already given `Task` a hand-written
`init(from:)`). Every record — whether it arrived via the `{rev, tasks}` envelope or a bare array — routes
through this single migrating init. Its contract:

- **`id` is the only required field.** An id-less record is genuinely unrecoverable and is the *sole* drop
  case (it throws, and `FailableTask` drops just that record). Every other field is `decodeIfPresent` with a
  safe default, so a partial/garbage record is **kept** as a safe card rather than stranding the whole board.
- **Garbage enum fields default, never throw.** Tolerant enum/decodable fields (`origin`, `access`, `model`,
  `startIn`, `column`, `deadReason`) are `try?`-guarded so a present-but-renamed/removed rawValue falls back
  to the same safe default the memberwise init uses (`.worktree`, `.readWrite`, `unknown` model, `.impl`,
  `.impl`, nil) — one garbage field can never drop an otherwise-recoverable record.
- **Migrating seed.** When the `phase` key is **absent** (a pre-Stage-2 record), `phase` is seeded from the
  legacy `status`/`waitReason`/`deadReason`/`archived` keys — read leniently as `String?` (the fields no
  longer exist on the type) so a garbage status still decodes to a safe phase. A record that already carries
  `phase` decodes it directly (no migration). The mapping (fail-safe, top-to-bottom precedence):

  | legacy record | migrated `phase` |
  |---|---|
  | `archived == true` | `.archived(teardownComplete: true)` |
  | `status == "running"` | `.live(.running)` |
  | `status == "waiting"` | `.live(.waiting(waitReason ?? .humanTurn))` — a nil/unknown wait reason (common for idle cards) maps to `.humanTurn`, never a fake permission wait |
  | `status == "done"` | `.dead(.completed)` |
  | `status == "dead"` | `.dead(deadReason ?? .agentExited)` — the preserved terminal reason |
  | nil / unrecognized `status` | `.dead(.rebootUnrevived)` — the safe terminal, never a throw |

- **Envelope `rev` preserved.** The `{rev, tasks}` envelope's `rev` loads as-is; a bare-array file loads at
  `rev = 0`. Encode is custom (the decode-only legacy keys make Codable synthesis impossible) and writes
  every stored property — deliberately **not** `status`/`waitReason`, which no longer exist on the wire.

Other schema compat is unchanged: the legacy `worktree: String` field is decode-only (mapped onto `cwd`; the
store always writes `cwd` + `origin`), and optional fields decode with sane defaults, so a board created
before borrowed/scratch cards existed still opens.

> **Note on `pendingSeed`.** Wired in PR4b: `resume(id, seed:)` (driving handoff's `resumeInCard` and
> seeded-wake) persists the folded seed as `pendingSeed` in the **same** funnel patch as
> `transition(.relaunching)`; `restart` clears it (a blank restart carries no seed). It is consumed and
> cleared on the `.live` landing, at each of the four sites that can perform one: the `RelaunchStepper`,
> the `LaunchStepper` (a reopened resumable card), the reconciler's *adopt* path, and — since the
> [`--model` re-seat](05-command-reference.md#the---model-re-seat) — `report()` itself, when a stamped
> current-generation report lands a card the steppers left behind. Every one of them clears it in the same
> `mutate` closure that writes `.live`; a `resumeFailed` leaves it in place so a retried relaunch still
> carries the seed.

> **Note on `pendingModel`.** It mirrors `pendingSeed` field-for-field: written in the same funnel patch as
> `transition(.relaunching)` by `restart`/`resume` (and `handoff` through `resumeInCard`), encoded only when
> present (`encodeIfPresent`, so an older board decodes unchanged), consumed at the same four `.live`
> landings — `RelaunchStepper`, `LaunchStepper`, the reconciler's *adopt* path, and `report()`'s own
> landing when the report is stamped with the current generation — through the shared
> `consumeModelReseat(_:_:)`, and left in place by a failed launch so the retry still carries the re-seat.
> The one thing it adds beyond `pendingSeed` is that consuming it **re-asserts `model`** from the request,
> because a stale statusline can have moved `model` while the card was `.relaunching`. `finishLaunch` builds
> the launch argv from `pendingModel ?? model.id`, so the intent — not the display field — is what actually
> launches.

## The inbox store (F3)

Alongside `tasks.json`, the daemon keeps a second durable store — the **`Inbox`** (`Inbox.swift`), a
sibling to `TaskStore` built on the same actor-over-JSON pattern (lazy load, atomic write, malformed →
`.bak` + `[]`). It holds a flat, append-ordered array of `InboxMessage` (`{id, cardId, text, createdAt}`)
at `~/Library/Application Support/Orchestra/inbox.json`, giving **FIFO-per-card** delivery via a stable
filter on `cardId`. `enqueue` appends, `peek` reads without removing, `drain` returns + removes all of a
card's pending messages, and `drainFirst(cardId, count:)` removes only the first `count` (in FIFO order),
leaving the rest queued — the hook for the Stop-drain's *whole-messages-to-fit* delivery (deliver the
messages that fit this turn's 10 000-char budget, defer the overflow to the next turn-end; see
[Design decisions](09-design-decisions.md#shipped-feature-history)). Messages persist until drained, so they
survive a daemon restart. Three
editor mutators — `remove(id)`, `update(id, text:)` (text only; id/cardId/createdAt preserved), and
`reorder(cardId, orderedIds:)` (a permutation of that card's ids, refilling only its own array slots so
other cards' interleaving is untouched) — back the app's [inbox editor](07-app-ui.md#the-inspector) and
the [`inbox*` commands](05-command-reference.md#registry-commands).

This is the durable merge-back channel for **F3** (see [Design decisions](09-design-decisions.md#one-seed-four-topologies)):
`send` enqueues here instead of typing into tmux (then [wakes the card](09-design-decisions.md#shipped-feature-history)
so an idle agent drains promptly rather than at its next unprompted turn; `send` rejects a message over
`StopDrain.maxMessageChars` at enqueue so any accepted one delivers whole — the inbox is a nudge channel, not
a document transfer), and the Claude Stop hook drains it
into the agent at its next turn-end (`OrchestraService.drainForStop`, dispatched by the [`hook` RPC](05-command-reference.md#server-only-built-in-methods)
on the `stop` event — see the [`_report` Stop-drain](06-clients-cli-mcp.md#the-hooks--_report-channel)).

## The trust ledger (T1)

A third durable store — the **`TrustLedger`** (`Agents/TrustLedger.swift`) — is Orchestra's
provider-agnostic source of truth for **which directories agents may *write* in**. It is the same
actor-over-JSON pattern (lazy load, atomic temp+replace write, malformed → `.bak` + empty) at
`~/Library/Application Support/Orchestra/trust-ledger.json`, a map of **canonicalized path → `Entry`
(`{grantedBy, grantedAt}`)**. `isTrusted(path)` is a membership check; `record(path, grantedBy:)` adds
an entry (idempotent — a no-op if already present). `grantedBy` (`TrustGrantor`) records *how* trust
was acquired: **`repoRegistration`** (a worktree's source repo — registering a repo to run agents is
the trust act), **`orchestra`** (auto-trust of a scratch dir Orchestra made empty and owns), or
**`human`** (an explicit grant through the [`trust` surfaces](05-command-reference.md#registry-commands), PR T2).

Only the **core** reads it — in `OrchestraService.resolveTrust(origin:cwd:repo:)`, which maps a card's
`origin` to a `TrustDecision` (`.trusted` | `.needsGrant`) carried onto the launch as
`AdapterContext.trustCwd`; **adapters never read the ledger**, they only *apply* that bool into their
native trust flag (see [Cards, worktrees & sessions](04-cards-worktrees-sessions.md#the-claude-code-adapter)
and [Design decisions](09-design-decisions.md#trust-boundaries-allowlist-for-worktrees-sandbox-for-the-rest)).
The ledger + resolver landed as **PR T1**; the human-grant surfaces that fill a `needsGrant` as **PR T2**
(both in [chapter 9](09-design-decisions.md#shipped-feature-history)). A later read-only path — PR D3's
`OrchestraService.isPathTrusted`, surfaced as the [`trustState`](05-command-reference.md#registry-commands)
query — lets a client (the app [`SpawnSheet`](07-app-ui.md#the-spawn-sheet)) *check* trust without
recording anything; granting still only happens through the human `trust` surfaces.

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
| `worktreeAddTimeout` | `600` | Wall-clock bound (s) on `git worktree add` — generous; worst known checkout ≈9s. |
| `sessionLaunchTimeout` | `30` | Wall-clock bound (s) on a launch; a card `launching`/`relaunching` past it is classified dead. |
| `controlTimeout` | `15` | Wall-clock bound (s) on tmux control verbs + fast git queries. |
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
| Trust ledger | `…/trust-ledger.json` |
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
(git/tmux/claude/zed not found), `worktreeDirty`, `resumeFailed`, `zedMissing`, `invalidParams`,
`io` (filesystem/subprocess failure), and `trustDenied` (code 1011 — a `needsGrant` directory's trust
was not approved by a human; see [the `trust` command](05-command-reference.md#registry-commands)).

## Events and the activity feed

The daemon emits an `Event` after every meaningful mutation:

- `taskUpserted(Task)` — a card was created or changed,
- `taskRemoved(UUID)` — a card was removed,
- `activity(ActivityItem)` — a feed entry.

An `ActivityItem` is a timestamped, task-linked record with a **source** (`app`/`cli`/`mcp`/`agent`/
`daemon`) and a **kind** (`spawned`/`moved`/`archived`/`statusChanged`/`dead`/`recovered`/`command`/
`warning`). The `warning` kind is the surface for advisory notices — the **authMode soft-warn** emitted
when a subscription-auth adapter fans out past its concurrency threshold (see
[Design decisions](09-design-decisions.md#authmode-advise-on-fan-out-never-cap)), and the **trust**
notices (PR T2): the actionable *"runs untrusted (sandboxed) … run `orchestra trust`"* emitted when a
`needsGrant` card spawns, and the *"Trusted … (human grant)"* confirmation on an approved grant. None of
them blocks the action it warns about. The app's Activity popover renders these; the daemon keeps the
most recent 200 in a ring buffer that is replayed to new subscribers.

### The report types

The agent's `_report` channel carries a `StatusReport`, a unified patch with two halves:

- the **event half** (`EventReport`) — causally-ordered fields: `sessionId`, `transcriptPath`,
  `sessionSource`, `endReason`, `promptText`;
- the **snapshot half** (`SnapshotReport`) — a seq-stamped atomic snapshot: `ctxPct`, `modelId`,
  `modelDisplay`, `run` (a `RunState?` — the agent's observed `.running`/`.waiting(reason)`, which
  **replaces the retired `status`/`waitReason` pair** so `AgentStatus` is off the wire entirely), `desc`,
  `turnCompleted`, `sessionName`. `report()` maps a present `run` onto a `.live(run)` phase write through
  the `transition()` funnel (it no longer writes `phase` directly).

How those halves are merged into the card (event half applied unconditionally and ordered; snapshot
half seq-gated against a monotonic cursor) is detailed in
[Cards, worktrees & sessions](04-cards-worktrees-sessions.md) and `OrchestraService+Report.swift`.
