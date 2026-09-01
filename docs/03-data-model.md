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
| `title` | `String` | The card's name, and the **SSOT** for it — derived at spawn from the card's own identity (branch → read-only target → prompt → directory) unless an explicit source set it. Pushed to the agent session as `--name` at every (re)launch. See [card naming](09-design-decisions.md#card-naming-the-title-is-the-ssot). |
| `titleSource` | `TitleSource` | Where `title` came from: `branch` \| `attached` \| `prompt` \| `explicit`. `explicit` (a `spawn` title, `set-title`, or a mirrored in-session `/rename`) **pins** the title against every derived default. |
| `awaitingFirstPrompt` | `Bool` | If `true`, this session has never received a genuine user prompt. A blank launch has no positional prompt, and its live turn state remains `unavailable` until current provider evidence arrives. Set by a promptless spawn, `restart`, a blank `reopen`, and `SessionStart(clear)`; cleared by the first prompt. Lifecycle state, not a naming concept. A promptless (provisional) card is the human's first move, so it seeds [`humanPaced`](#the-task-card) `true` at launch — but the stall exemption keys on `humanPaced`, not this flag (which is sticky on Codex). |
| `lastSessionName` | `String?` | The last session name seen for this card — the `--name` a launch pushed, or the last value the agent reported. The `session_name` mirror is a **delta** against this, so a live session echoing its launch name can't overwrite a newer title. |
| `desc` | `String` | **Volatile** one-line blurb of what the agent is doing now, reported as metadata (Claude hooks or the Codex rollout tail; pane-parse fallback). The report pipeline overwrites it every snapshot and `restart`/`/clear` blank it. |
| `note` | `String?` | **Durable** authored one-liner about what this card IS — e.g. `Wave 2/4 — native inbox delivery`. Set only by `spawn(note:)` / `set-note`, never by telemetry, and survives restart/clear/handoff. nil ⇒ none; an empty `set-note` clears it. See [desc vs note](09-design-decisions.md#desc-vs-note-volatile-status-vs-durable-narrative). |
| `pendingQuestion` | `PendingQuestion?` | The agent's **declared** open question (`{text, declaredAt}`) — set by [`needs-input`](05-command-reference.md#registry-commands) when it ends a turn blocked on a decision only the card's owner can make. It clears only when an identified distinct next turn starts. A same-session reconnect, provider resolution, opening the harness, sending a message, resolving a native prompt, and native inbox delivery do not clear it. `declaredAt` supplies display age; the two fields travel as one value. nil ⇒ no open question. See [the declaration model](09-design-decisions.md#done-is-declared-merge-request-and-needs-input). |
| `repo` | `String` | Allowlisted repo root (worktree cards). Context-only for borrowed cards. |
| `branch` | `String` | Working branch (worktree cards). |
| `parentBranch` | `String?` | Stacked-branch parent — the `.parent` [diff baseline](#classifying-enums). A **cache** derived from the git-config lineage store: `set-parent`, `spawn --base`, and converge write it; nil means the card has no parent link. |
| `treeStat` | `TreeStat?` | Daemon-maintained branch-tree status, carrying **two orthogonal dimensions**. Parent-facing: this card vs ITS parent — `state` (`inSync` / `stale` / `restackNeeded` / `mergeRequested`), `behind`, `parentIsRemote`, plus the merge-request `nudges`/`mergeStalled`. Child-facing (the wave-progress bar): `mergedChildren` (the `n` — children merged and reaped, from the git-config counter), `plannedChildren` (the `m` — the orchestrator's declared plan size via [`set-planned`](05-command-reference.md#registry-commands), 0 = unset), and `drained` (the wave finished by merges — the last lineage child left by a merge-classified removal and none remain; nudge input only). A parentless root with children still carries a stat (neutral `inSync` base) so its counters broadcast. nil = neither dimension has anything to report. See [the tree counters](09-design-decisions.md#tree-counters-daemon-observed-child-progress). |
| `cwd` | `String` | **The one directory** the agent and its shells run in. |
| `origin` | `CardOrigin` | `worktree` \| `scratch` \| `borrowed` — how `cwd` came to be. |
| `access` | `CardAccess` | `readWrite` \| `readOnly`. |
| `agentId` | `String` | Which adapter runs it (default `"claude-code"`). |
| `model` | `AgentModel` | Selected model (launch id + display label + family). |
| `startIn` | `StartIn` | `plan` \| `impl` — where the agent began. |
| `column` | `Column` | Current board column. |
| `order` | `Int` | Sort position within the column. |
| `phase` | `Phase` | The **persisted lifecycle SSOT**. `creatingWorktree` \| `launching` \| `live(AgentState)` \| `relaunching` \| `dead(DeadReason)` \| `archived(teardownComplete:)`. The `transition()` funnel is its sole writer; provider-neutral `AgentSignal`s reduce the value carried by `live`. |
| `sessionEpoch` | `Int` | Monotonic per-card session generation, bumped on each (re)launch entry so a stale signal (a late hook, a liveness poll) from a superseded session is fenced out. |
| `phaseChangedAt` | `Date` | When the lifecycle phase or live `TurnStatus` last changed — live activity or human-need detail does not reset it. Drives status-relative timers and terminal-dwell checks. |
| `pendingSeed` | `String?` | Authored handoff context staged for the NEXT (re)launch, written by `resume(seed:)` and consumed+cleared on the `.live` landing (see [migration & persistence](#persistence-and-migration)). It never carries ordinary inbox rows. |
| `pendingModel` | `String?` | A [`--model` re-seat](05-command-reference.md#the---model-re-seat) staged for the NEXT (re)launch (`restart`/`handoff`/`resume`), consumed+cleared on the `.live` landing exactly like `pendingSeed`. Separate from `model` because it is the **launch intent**, and it is the one thing `report()` cannot clobber: the report path owns `model` and is not epoch-fenced, so the *dying* session's last statusline would otherwise revert the override before the relaunch read it (see [migration & persistence](#persistence-and-migration) and [ch. 9](09-design-decisions.md#report-vs-the-launch-intent-pendingmodel-and-the-epoch-fence)). |
| `deadReason` | `DeadReason?` | Set together with `phase = .dead(_)`; carries the terminal reason. |
| `deadDetail` | `String?` | Extra detail (e.g. for `resumeFailed`/`spawnFailed`). |
| `ctxPct` | `Double` | Context-window usage, 0–100 (Claude pushes it via the statusLine; Codex derives it from the rollout tail ÷ its offline model window). |
| `diffStat` | `DiffStat?` | Daemon-maintained branch diffstat (`{filesChanged, insertions, deletions}`) for the card footer and the inspector header (axis 7), measured against the card's default baseline — parent-relative when it has a parent branch, else branch-relative. Nil for a non-git / zero-change / not-yet-computed card. |
| `humanPaced` | `Bool` | Compatibility bit for the current client stall row: the card is the human's to pace, so per-card quiescence does not amber it. A human prompt sets it; an authored handoff seed clears it. Native inbox delivery does not alter it. The launch's own machine prompt is generation-marked so the prompt report does not misclassify it as human input. This bit is separate from `AgentState`; the proposed root-level stalled watchdog and removal of this compatibility rule are deferred. |
| `agentSessionId` | `String?` | The current provider-native conversation identity: Claude's seeded session id or Codex's app-server thread id. A Codex hook invocation id and rollout filename are never alternative authorities. |
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
  freeform/scratch delegated card idles `.live(AgentState.waiting)` when its turn ends — exactly like a
  worktree card — rather than being inferred done; success is agent-signalled (the delegate `send`s its
  result, and the orchestrator `archive`s the card once it consumes that result).
  [`reopen`](05-command-reference.md#registry-commands)
  reverses it — `archived` back to `false`, phase walked back onto the board via the funnel,
  `deadReason`/`deadDetail` cleared — while keeping the card's stored `col`, so it returns to the column
  it was archived from.
- **`Phase`** — the persisted lifecycle enum (Stage 2). Wire form is a `{ "name": <case>, "detail": <value> }`
  object; `detail` present only for the payload-carrying cases (`live`, `dead`, `archived`):
  - `creatingWorktree` — materializing the cwd (worktree / scratch / borrow); **every** spawn enters here,
  - `launching` — cwd ready, bringing the agent session up,
  - `live(AgentState)` — the harness process is up and the payload is Orchestra's current provider-neutral
    observation of its turn, activity, and optional provider human need,
  - `relaunching` — a restart/resume in flight,
  - `dead(DeadReason)` — terminal-ish: session gone, awaiting recovery,
  - `archived(teardownComplete: Bool)` — off the board; the Bool distinguishes an archive whose
    worktree/session teardown is still pending from one fully torn down.
  A coarse `Phase.Kind` (`creatingWorktree`/`launching`/`live`/`relaunching`/`dead`/`archivedPending`/
  `archivedComplete`) flattens the `archived` Bool for stepper dispatch and terminal/bump checks;
  `isTerminal` is `dead(*)` or `archived(*)`.
- **`AgentState`** — the complete current snapshot attached only to `Phase.live`: `turnStatus`, optional
  `activity`, and optional `humanNeed`. Leaving `live` discards all three; entering `live` starts
  unavailable and then reconstructs them from current structured provider observation.
- **`TurnStatus`** — Orchestra's view of the top-level harness turn: `running`,
  `waiting(WaitingInfo)`, or `unavailable`. A wait may carry `AutomaticResume`, meaning the provider has
  committed to another turn without human or Orchestra input. `Task.workInFlight` derives `true` for a
  running turn or an automatic-resume wait, `false` for an ordinary wait, and nil for unavailable.
- **`ProviderHumanNeed`** — an optional display-only provider fact: `.permission`, `.input`, or
  `.unspecified`. It is orthogonal to turn state. `Task.requiresHuman` is the pure OR of its presence and
  the separate durable `pendingQuestion` declaration.
- **`PhaseDisplayKey`** — a coarse **display-only, non-wire, non-Codable** label derived from `phase` on
  demand (`Task.phaseDisplay`), never persisted, so the display vocabulary can evolve without touching the
  durable model: `starting` / `launching` / `relaunching` / `running` / `idle` / `unavailable` /
  `dead` / `done`. The being-born phases surface honestly (a spawning card reads `.starting`/`.launching`,
  not a fake `.running`). Provider-human presentation comes from `AgentState.humanNeed`, not from this
  lifecycle-derived display key.
- **`DeadReason`** — why a card died (set alongside `phase = .dead(_)`):
  - `agentExited` — a `SessionEnd` with reason exit/logout (usually mid-life and resumable),
  - `sessionVanished` — the tmux session is gone with no `SessionEnd` (crash or external kill),
  - `rebootUnrevived` — the startup sweep couldn't auto-revive it,
  - `resumeFailed` — a resume attempt failed (see `deadDetail`),
  - `spawnFailed` — the initial spawn never came up (worktree/launch failure before first life).
- **`CardOrigin`** — `worktree`, `scratch`, `borrowed`.
- **`CardAccess`** — `readWrite`, `readOnly`.
- **`StartIn`** — `plan` or `impl`.
- **`DiffBase`** — the baseline for a card's [code-review diff](09-design-decisions.md#shipped-feature-history)
  (axis 7): `working` (vs `HEAD`), `branch` (vs the default-branch merge-base — the PR diff, the default),
  or `parent` (vs the card's `parentBranch`, for a stacked card; falls back to `branch` when it has no parent link).

### Identity and references

A card can be named with a short id, a full UUID, or either of two URI forms, all resolvable by `TaskRef`:

- **short id** — first 6 chars of the UUID, lowercased,
- **full UUID**,
- **short URI** — `orchestra://task/<shortId>`, the compact self-identifying form copied by the board
  card-reference badge and the inspector's "Copy chat link" action,
- **descriptive URI** — `orchestra://task/<shortId>-<slug>`, where `slug` is the slugified title; this
  remains a valid deep link and the full form returned by `Task.ref()`.

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

### Schema migration — legacy status snapshots become live-but-unavailable

The current cutover replaces both the original `status`/`waitReason` fields and the intermediate
`Phase.live(RunState)` payload with `Phase.live(AgentState)`. Compatibility lives only in
`Task.init(from:)` and `Phase.init(from:)`; there is no second runtime reducer or compatibility writer.
Every record — whether it arrived via the `{rev, tasks}` envelope or a bare array — routes through these
decoders. Their contract:

- **`id` is required; the `phase` field is the one non-tolerant field.** A record throws (and `FailableTask`
  drops just that record) when `id` is absent OR when `phase` carries an unknown value — `phase` is decoded
  with an unguarded `try`, unlike every other field. The one current unknown-`phase` case is a legacy
  `.dead(.completed)` record: `DeadReason.completed` was removed as a clean on-disk break (no migration), so
  such a record no longer decodes and self-drops (accepted — see [chapter 9](09-design-decisions.md#done-is-not-observable--success-is-agent-signalled-not-inferred)).
  Every field other than `id`/`phase` is `decodeIfPresent` with a safe default, so a partial/garbage record
  is **kept** as a safe card rather than stranding the whole board.
- **Garbage enum fields default, never throw.** Tolerant enum/decodable fields (`origin`, `access`, `model`,
  `startIn`, `column`, `deadReason`) are `try?`-guarded so a present-but-renamed/removed rawValue falls back
  to the same safe default the memberwise init uses (`.worktree`, `.readWrite`, `unknown` model, `.impl`,
  `.impl`, nil) — one garbage field can never drop an otherwise-recoverable record.
- **Live legacy snapshots lose only their unprovable turn detail.** A stored intermediate
  `live({name: running|waiting, ...})` value decodes as `live(AgentState(turnStatus: unavailable))`. The
  harness lifecycle remains live, but Orchestra waits for fresh structured observation before claiming
  whether a top-level turn is open.
- **Legacy request arrays are not trusted.** A stored `activeRequests` payload also decodes to a live,
  unavailable state. Current provider evidence must establish the optional `humanNeed`; a persisted
  request list cannot prove either a current prompt or a current turn.
- **Pre-phase seed.** When the `phase` key is absent, `phase` is seeded from the older
  `status`/`waitReason`/`deadReason`/`archived` keys. `waitReason` is accepted for decoding but cannot be
  trusted after the required clean daemon restart, so both old live statuses become unavailable:

  | legacy record | migrated `phase` |
  |---|---|
  | `archived == true` | `.archived(teardownComplete: true)` |
  | `status == "running"` | `.live(AgentState(turnStatus: .unavailable))` |
  | `status == "waiting"` | `.live(AgentState(turnStatus: .unavailable))` |
  | `status == "dead"` | `.dead(deadReason ?? .agentExited)` — the preserved terminal reason |
  | nil / legacy `"done"` / unrecognized `status` | `.dead(.rebootUnrevived)` — the safe recoverable terminal, never a throw (a genuinely retired card carries `archived == true`, handled by the first row) |

- **Envelope `rev` preserved.** The `{rev, tasks}` envelope's `rev` loads as-is; a bare-array file loads at
  `rev = 0`. Encode writes only the current `Phase.live(AgentState)` form, never either legacy status shape.

Other schema compat is unchanged: the legacy `worktree: String` field is decode-only (mapped onto `cwd`; the
store always writes `cwd` + `origin`), and optional fields decode with sane defaults, so a board created
before borrowed/scratch cards existed still opens.

> **Note on `pendingSeed`.** Wired in PR4b: `resume(id, seed:)` (driving handoff's `resumeInCard`)
> persists the authored context as `pendingSeed` in the **same** funnel patch as
> `transition(.relaunching)`; `restart` clears it (a blank restart carries no seed). It is consumed and
> cleared on the `.live` landing at each lifecycle-owned landing site: the `RelaunchStepper`, the
> `LaunchStepper` (a reopened resumable card), and the reconciler's same-epoch *adopt* path. Each clears it in the same
> `mutate` closure that writes `.live`; a `resumeFailed` leaves it in place so a retried relaunch still
> carries the seed.

> **Note on `pendingModel`.** It mirrors `pendingSeed` field-for-field: written in the same funnel patch as
> `transition(.relaunching)` by `restart`/`resume` (and `handoff` through `resumeInCard`), encoded only when
> present (`encodeIfPresent`, so an older board decodes unchanged), consumed at the same three `.live`
> landings — `RelaunchStepper`, `LaunchStepper`, and the reconciler's *adopt* path — through the shared
> `consumeModelReseat(_:_:)`, and left in place by a failed launch so the retry still carries the re-seat.
> The one thing it adds beyond `pendingSeed` is that consuming it **re-asserts `model`** from the request,
> because a stale statusline can have moved `model` while the card was `.relaunching`. `finishLaunch` builds
> the launch argv from `pendingModel ?? model.id`, so the intent — not the display field — is what actually
> launches.

## The inbox store

Alongside `tasks.json`, the daemon keeps a second durable store — the **`Inbox`** (`Inbox.swift`), a
sibling to `TaskStore` built on the same actor-over-JSON pattern (lazy load, atomic write, malformed →
`.bak` + `[]`). It holds an append-ordered array of `InboxMessage`
(`{id, cardId, text, source?, dedupKey?, createdAt, state}`) at
`~/Library/Application Support/Orchestra/inbox.json`, giving **FIFO per card**.

`send` succeeds when it durably admits a `queued` row; it does not claim that a provider or model has seen
the text. A sender attached to the card's live provider handle later makes the row `handedOff` only when the
native harness accepts its request. That state is advisory history, never proof that a model read or acted on
the message, and the store retains at most 100 handed-off rows per card. `inbox` returns unresolved rows by
default; `includeHistory` also returns that bounded history.

The only stored states are `queued`, `failed`, and `handedOff`. A failed FIFO head deliberately pauses later
rows until a human retries, edits, or removes it. Editing an unresolved row makes it queued again;
`handedOff` history is immutable except for removal; and reordering operates only on unresolved rows after
failed rows are resolved. Source is human-facing provenance — Human, Card, Orchestra, or legacy Unknown —
not an authorization or delivery guarantee. Neither this store nor its sender owns runtime status,
`pendingQuestion`, attention, session wakeups, or `wait`.

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
| `autoInstallMCPGlobally` | `false` | On the next card launch, add missing `orchestra` MCP entries to Claude and Codex global config, install user-scoped `orchestra` and `orchestra-mcp` shims in `~/.local/bin`, and add an idempotent PATH block to a shell profile. Existing entries and files are left unchanged. |
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
and worktree path against (see [the security boundary](04-cards-worktrees-sessions.md#process-and-path-safety)).

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

### Metadata reports and agent-state signals

Claude's `_report` hook channel carries metadata plus a current-session observation in one RPC.
`StatusReport` is the metadata/lifecycle patch, with two halves:

- the **event half** (`EventReport`) — causally-ordered fields: `sessionId`, `transcriptPath`,
  `sessionSource`, `endReason`, `promptText`;
- the **snapshot half** (`SnapshotReport`) — a seq-stamped atomic metadata snapshot: `ctxPct`, `modelId`,
  `modelDisplay`, `desc`, and `sessionName`.

How those halves are merged into the card (event half applied unconditionally and ordered; snapshot
half seq-gated against a monotonic cursor) is detailed in
[Cards, worktrees & sessions](04-cards-worktrees-sessions.md) and `OrchestraService+Report.swift`.

Claude's current-session hook observations and Codex app-server messages go through
`Adapter.agentSignals(from:context:)`. Adapters interpret provider vocabulary and emit normalized
`AgentSignal`s; `AgentStateReducer` is the only generic fold, and `transition()` atomically persists its
output as the new `Phase.live(AgentState)`. Every signal carries the launch `sessionEpoch`; Codex sources
are additionally bound to the provider thread id, and Claude hooks are checked against the current session
and top-level turn. The Codex rollout tail and hooks remain metadata/orientation only. There is no status
field in `StatusReport` and no second Core status reducer.

Claude same-prompt continuation activity is normalized as `turnReactivated`, which restores `running`
without becoming a distinct-turn boundary or clearing `pendingQuestion`. A global provider snapshot may
submit a waiting reconciliation only for an exact Claude session that stayed running with the same
in-memory observation generation throughout the subprocess call; the generation is a correlation fence,
not a second status copy.

For a fresh Codex launch, the structured observer may start while `agentSessionId` is nil. It makes one
`thread/list` call scoped to the exact card cwd and durable launch cutoff, filters out child and ephemeral
threads, and binds only when exactly one candidate remains; ambiguity stays `unavailable`. A later filtered
`thread/started` can establish or replace the binding (including `/clear`). Core then persists that id and
rearms the observer against the exact thread, whose `thread/resume` response establishes running or waiting.
