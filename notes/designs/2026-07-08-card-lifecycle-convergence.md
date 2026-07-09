# Card Lifecycle Convergence — Design Spec

- **Status:** APPROVED + FINALIZED against `main` @ `f1aa568` (2026-07-09, card `4c2ec0`)
- **Date:** 2026-07-08 (finalized 2026-07-09)
- **Author:** card `025288` (design/lifecycle-convergence); finalization card `4c2ec0` (impl/lifecycle-convergence)
- **Approved direction:** "Intent + convergence" (approach B), approved after a deep adversarial review of branch `fix/spawn-hang-standalone`
- **Scope of this doc:** the full target design + a migration outline. The task-by-task plan lives in `notes/plans/2026-07-08-card-lifecycle-convergence.md`.
- **Finalization note (2026-07-09):** re-grounded on `main` @ `f1aa568` (the branch-tree merge landed after this spec was drafted). Corrections folded in: (a) the named timeout knobs (`sessionLaunchTimeout`/`worktreeAddTimeout`/`defaultControlTimeout`) do **not** exist on main — launches and checkouts are **unbounded** today, so this design *introduces* the knobs (§P3); (b) `provisioning` (flag + dict) never existed on main — it is branch-only; on main the uncoordinated variables are `status` + the `recovering` set (+ the branch would have added two more); (c) `reconcileLiveness`'s per-tick `sessions.list()` runs **on-actor** on main (the off-actor version was branch-only); (d) main is still **N:1** card↔branch (the 1:1 hard refusal `7bcde48` was reverted to a warning by `c099a82`; co-located sibling cards are an intentional, tested feature) — the refcount in §P3 is therefore *correct against main*, and 1:1 remains the separate worktree-coupling design's call; (e) branch-tree added new state machines + on-actor git sites this design must coexist with (§4 "Branch-tree surface", §9). Anchors in §2/§4/§9 are updated to `f1aa568`; anchors marked *(branch)* cite the discarded `fix/spawn-hang-standalone`.

---

## 1. TL;DR

Orchestra's card lifecycle is **edge-triggered** and spread across **uncoordinated variables with no single writer** (`status` + the in-memory `recovering` set on main; the discarded branch added two more). Branch `fix/spawn-hang-standalone` made spawn non-blocking (good) but layered more variables on top, and a review found **15 confirmed lifecycle bugs** — including worktree data-loss, a parent `wait` that hangs forever, a provisioning→zombie session collision, and a persisted flag that never reconciles after a daemon restart.

The fix is to make lifecycle **state-triggered and convergent**:

1. **One persisted `phase` per card**, written only through a single `transition()` funnel that validates edges, with a per-launch **epoch** that makes stale liveness signals harmless — this *deletes* the `recovering` set, grace timers, and the `provisioning` flag/dict.
2. **Slow verbs become persisted intent driven by an idempotent reconciler** — the phase *is* the intent; a crash-restart re-drives it. `reopen`/`archive`/`resume` stop freezing the actor.
3. A **`WorktreeRegistry` actor** serializes worktree ensure/release with on-demand sibling counts and one removal policy (incl. borrows, with persisted registrations) — no more races, no more force-removing dirty/shared trees.
4. A **monotonic board `rev`** + client-minted ids + per-RPC deadlines make sync gap-detectable and retries idempotent.
5. An **actor-hygiene sweep** moves all subprocess/file IO off the single service actor.
6. A **UI contract** driven by one `displayState(phase, connection)` gates in-flight actions and tells the truth about failures.

Everything is **capability-gated** (works for `claude-code` *and* `codex`), takes a **clean wire break** (the daemon + all clients ship together; only on-disk state is migrated), and keeps the **single `OrchestraService` actor**.

---

## 2. Motivation

### 2.1 Root cause

A card's lifecycle today is the uncoordinated product of multiple variables, each written from multiple sites with no funnel. On **main** there are two; the discarded branch would have added two more:

| Variable | Kind | Declared | Writers (confirmed) |
|---|---|---|---|
| `status: AgentStatus` | persisted enum `{waiting, running, done, dead}` | `Model.swift` (`AgentStatus` :18) | hooks/telemetry `report`, liveness fallback, spawn, markDead |
| `recovering: Set<UUID>` | in-memory guard | `OrchestraService.swift:96` | spawn `:409-410`, resume/restart, reconcile gate `+Recovery.swift:241` |
| `provisioning: Bool?` *(branch-only)* | persisted flag | branch `Model.swift` | 5 sites on the branch |
| `provisioning: [UUID: Task]` *(branch-only)* | in-memory job dict | branch `OrchestraService.swift` | 5 sites on the branch |

Note the two branch variables *share the name* `provisioning` while being different variables. There is **no single writer**, so any two of them can disagree, and none survive a process restart coherently. On main the same disease presents differently: spawn persists the card `.running`/`.waiting` **before** the session exists (`OrchestraService.swift:409-410` guards the window with `recovering`), and worktree/session launches are **unbounded** — a wedged git or tmux freezes the actor forever.

### 2.2 The 15 confirmed bugs

All confirmed against `main` + `fix/spawn-hang-standalone`. Grouped by the pillar that fixes each. Anchors are current `main` @ `f1aa568` unless marked *(branch)*.

| # | Bug | Evidence | Fixed by |
|---|---|---|---|
| 1 | **Worktree data-loss.** Provision cleanup force-removes worktrees (`force: true`, no sibling/dirty guard) at 3 sites *(branch)*, unlike archive which guards. Main's spawn **orphan-rollback** (`:345-351`) also force-removes the just-cut branch+tree. | provision *(branch)* `OrchestraService.swift:352/:372/:448`; archive sibling filter `OrchestraService.swift:697`, `force:false` `:701`, dirty-keep `:702`; orphan rollback `:345-351` | P3 |
| 2 | **Parent `wait` hangs forever.** `dead(spawnFailed)` never reaches `concludeCard`, so a blocked parent is never released. `isConcluded` counts only `archived`/`.done`/`dead+agentExited`. | `markDead` (`+Recovery.swift:298-304`) never touches `mergeWatch`; `concludeCard` (`+Wake.swift:61`) only from clean exit; `isConcluded` `+Wake.swift:136-140` | P1 |
| 3 | **Provisioning→zombie session.** `openShell`/`inspect` `/bin/sh` keep-alive claims the agent's session name during the pre-launch window; the agent never launches; card flips `.running`. | `OrchestraService.swift:734/:773` (`ensure(argv:["/bin/sh"])`); name collision `SessionManager.swift:28` + short-circuit `:57`; neither checks the launch window | Verb `phaseGate` (§6, lands Stage 4 **with** non-blocking spawn — the window and its gate ship together) |
| 4 | **Stale whole-object writes.** `report()` writes the whole Task from a stale snapshot (`$0 = task`), clobbering any concurrent field mutation. | `+Report.swift:10` snapshot, `:133` `$0 = task` | P1 (delta write) + P1 funnel |
| 5 | **Restart mid-provision never reconciles.** `recoverSessions` reconciles only session-liveness; an in-flight spawn's intermediate state doesn't survive a daemon restart (branch: a persisted `provisioning:true` sticks forever). | `+Recovery.swift:14-49`; reconcile gates on in-memory `recovering` only `:241` | P2 |
| 6 | **Concurrent same-branch `git worktree add` races.** `ensure` is check-then-act with no lock; loser → `branchInUse` → failure. *Codex variant:* during a card's `agentSessionId==nil` window, telemetry `discover(cwd:)` can bind a **sibling card's rollout** to the new card. | `WorktreeManager.ensure:23-72`, no lock; `branchInUse:69`; adoption via bare `fileExists` `:29` | P3 (+ P1 gate for the Codex variant) |
| 7 | **Reconcile stale-snapshot TOCTOU.** Reads `store.all()`, suspends on `sessions.list()`, then kills based on the stale snapshot. | `+Recovery.swift:236-243`; list `:239`; `markDead` on stale `t` `:243` | P2 |
| 8 | **Unbounded external processes.** `git worktree add`/`remove`/`prune`, `tmux new-session`, and control verbs run with **no timeout at all** on main — a wedged git/tmux hangs the operation (and the actor) forever. | `WorktreeManager.swift` (no timeout args); prune fallback `:146`; `SessionManager` launches unbounded | P3 (introduces the wall-clock knobs) |
| 9 | **No launch-timeout story.** The named knobs (`sessionLaunchTimeout`, `worktreeAddTimeout`, `defaultControlTimeout`) **do not exist on main** — they were branch-only. Spawn, resume, restart, and reopen all launch unbounded, on-actor. The redesign introduces one set of Config knobs applied uniformly to spawn/resume/restart/reopen. | `+Recovery.swift:89/:177` (no timeout); spawn `OrchestraService.swift:422` | P1 + P3 + P5 |
| 10 | **`reopen` freezes the actor unbounded.** Recreates the worktree synchronously on-actor with no timeout — a huge/wedged checkout freezes every RPC indefinitely. | `+Recovery.swift:204` (fn), `:211` (`worktrees.ensure`, no timeout) | P2 |
| 11 | **Fresh spawn has no agent-up confirmation.** `sessions.ensure` returning (tmux exit 0) is treated as success. | `OrchestraService.swift:422` | P1 (Ready signal) |
| 12 | **Half-created worktree adopted.** `ensure` adopts any dir at the path via a bare `fileExists`. | `WorktreeManager.swift:29` | P3 (materialized marker) |
| 13 | **Whole-file writes.** `TaskStore.persist` rewrites all of `tasks.json` (incl. archived) per mutation. | `TaskStore.swift:55-67` | P5 (split + debounce) |
| 14 | **No sync versioning.** No `rev`/seq on client events or `boardSnapshot`; reconnect replays only a 200-item activity ring; late stale events clobber fresh state (last-write-wins). | ring `ControlServer.swift:16`/`BoardStore.swift:625-632`; unversioned `BoardSnapshot` `Model.swift:707-722`; `BoardStore.apply` `:587` | P4 |
| 15 | **No idempotency / no deadline.** Spawn mints the id server-side (`UUID()` `OrchestraService.swift:254`); a retry over dropped SSH = duplicate card. `ControlClient.call` awaits unbounded (`:152-168`); no ping keepalive. | mint `:254`; `ControlClient.call:152-168`; no heartbeat | P4 + P6 |

> A **per-card `seq` does exist**, but only on the agent→daemon `SnapshotReport` status-hook channel (`Model.swift:512-513`) — it is **not** on the client-facing `Event` stream or `BoardSnapshot`. Bug #14 is specifically about the *client* wire.

### 2.3 Why "intent + convergence"

The recurring failure shape is: an **edge** (a verb firing once) mutates several variables, then something (a race, a restart, a stale signal, a clobbering write) leaves them inconsistent with **no mechanism to repair them**. The cure is to make the persisted state *declarative* (the phase is the intended outcome) and add a **reconciler** whose job is to make reality match that intent, idempotently, from any starting point — including a cold restart.

---

## 3. Goals, non-goals, constraints

### Goals
- One coherent, persisted, single-writer lifecycle that survives daemon restarts.
- Kill all 15 bugs; make the *classes* of bug (races, stale writes, unreconciled flags, actor freezes) structurally impossible or self-healing.
- A **typed verb contract** so verb differences are well-defined and future verbs are easy to add correctly.
- Fail-safe defaults: on uncertainty, **keep** the card and the worktree; never destroy.

### Non-goals
- Rewriting the transport (stays newline-JSON-RPC over UDS; iOS stays on the shared-SSH `nc -U` bridge).
- Per-card executors / multiple actors. The single `OrchestraService` actor stays.
- Cross-version interop (an old client talking to a new daemon). We ship the daemon + all clients together; only on-disk state is migrated. Breaking the wire *is* in scope.

### Hard constraints
| Constraint | Why | Enforcement |
|---|---|---|
| **Agent-agnostic** | Claude *and* Codex are priority targets (repo `CLAUDE.md`). The current provisioning tests are Claude-only. | Every mechanism is capability-gated via `adapter.capabilities.*`; matrix tests run both agents. |
| **Break the wire freely; simplicity first** (updated 2026-07-08) | Single-user; Allen controls the daemon and every client and prefers dropping back-compat to reduce complexity. The wire is **not** frozen. | Restructure `Event`/`BoardSnapshot` as needed; make `phase` the field and **remove** `status`; make client-minted `id` **required**. Ship the daemon + all clients together. The **only** compat kept is a one-time defaulting read of the existing on-disk `tasks.json` so Allen's live board survives the upgrade — a *state migration*, not client compat. |
| **Single service actor** | Simplicity; avoids a concurrency rewrite. | No per-card executors; all blocking IO hops off-actor via `offActor`. |
| **Full test suite (~680 tests) stays green at every stage** | Each migration stage ships independently. | Stage gates run the full `swift test` suite. |

---

## 4. Current architecture (as-is, grounded)

- **Transport.** Newline-delimited JSON-RPC 2.0 over a UDS (`RPC.swift`, `ControlServer.swift`). iOS uses `SSHControlTransport` — one shared SSH session, one child channel running `nc -U <sock> || socat …` (`App-iOS/Terminal/SSHControlTransport.swift:65`). No seq/rev on events; no client RPC deadline; no keepalive.
- **State of record.** `TaskStore` (an actor) holds `[Task]` in memory and rewrites all of `tasks.json` atomically on every mutation (`TaskStore.swift:55-67`). Archived cards are a `Task.archived` bool in the same array. No board `rev`.
- **Service.** `OrchestraService` — a single actor (`OrchestraService.swift:6`) — owns spawn/recovery/report/wake/diff/notes. Many blocking calls run **on-actor** (see §9), including the every-2s `reconcileLiveness`'s `sessions.list()` (`+Recovery.swift:239`). Liveness runs every 2s from `orchestrad/main.swift:57-60` (`reconcileLiveness` + `pollTelemetry`).
- **Capability seam (already present).** `adapter.capabilities.resumeConfirmation` is `.sessionStartHook` (Claude waits for the SessionStart hook) vs `.relaunchLiveness` (Codex treats a clean `ensure` as confirmation) — `+Recovery.swift:96-116`, `AgentCapabilities.swift:47-49`. Telemetry transport is gated on `capabilities.telemetry == .fileTail`. `AgentCapabilities.swift:3` states the "no `if agentId ==`" contract. **We extend this seam, we don't invent it.**
- **Verb registry.** `CommandRegistry.build()` is a `[String: Command]` table; `Command = {schema, run}`. `CommandSchema` carries only `{name, summary, params, exposure∈{.all,.appOnly}}` (`CommandCatalog.swift:14-22`). 32 verbs are registered (incl. the seven branch-tree verbs `set-parent/tree/synced/shipped/merge-request/borrow/release`). Non-registry endpoints (`boardSnapshot`, `listDir`, the takeover trio, …) are a hardcoded switch in `ControlServer.swift:106-267` with a `default:` falling through to the registry.
- **Branch-tree surface (landed after this spec was drafted; must coexist).** Cards gained `parentBranch` + `treeStat` (`TreeState {inSync, stale, restackNeeded, mergeRequested}`) — a **parallel per-card state machine** about branch-vs-parent sync, cached from the git-config lineage SSOT (`BranchLineage` actor) and recomputed off the report funnel via 750ms debounces (`+Report.swift:141-142`, `+Tree.swift:369-384` computes edges *inside* the `store.update` closure to avoid lost updates). Per-card background loops with startup rebuild: remote watch loops (`+Remote.swift:167-208`, rebuilt by `rebuildRemoteWatches`) and merge-request re-nudge timers (`+MergeRequest.swift:63-95`, rebuilt by `rebuildMergeRequestNudges`). Startup order (`orchestrad/main.swift:47-53`): `sweepOrphanScratch → sweepOrphanBorrows → recoverSessions → rebuildRemoteWatches → rebuildMergeRequestNudges`. **Borrow**: a bare parent branch can be borrowed into a throwaway `orch-borrow-<branch>` worktree (`WorktreeManager.borrow:82-117`), exactly-one-borrower keyed on canonical path (`+Borrow.swift:43-52`); archive sweeps open borrows (`OrchestraService.swift:665-668`). The **owning-agent rule**: the daemon never merges/commits — agents do; the daemon only writes lineage + inbox nudges.
- **UI.** Actions are fire-and-forget (`_ = try? await`); archive toasts "Archived" even on failure (`BoardStore.swift:704-707`); nothing gated on connection/launch-in-flight; double-click Spawn double-spawns (`SpawnSheet.swift:302-321`); mac terminal attaches once with an empty `processTerminated` (`AgentTerminalView.swift:173`); the **iOS terminal has a good bounded-backoff retry loop** (`IOSTerminalView.swift` Coordinator, `:313-348`) — the model to copy.

---

## 5. The design — six pillars

### P1 — One persisted `phase` + a single transition funnel + epochs

**The phase enum** (persisted on `Task`; `phase` is *the* lifecycle field on the wire):

```
enum Phase {
  case creatingWorktree            // materializing the card's cwd (worktree add / scratch mkdir / borrowed no-op)
  case launching                   // cwd ready; waiting for the agent to come up
  case live(RunState)              // session up + agent confirmed; RunState = .running | .waiting(WaitReason)
  case relaunching                 // resume/restart/handoff in flight
  case dead(DeadReason)            // terminal, not running (reason incl. .completed); session MAY still exist (revivable)
  case archived(teardownComplete: Bool)  // terminal, dismissed by a human; teardown progress is persisted
}
```

`creatingWorktree` means "materialize the card's cwd", generically: `git worktree add` for `.worktree` cards, `mkdir` for `.scratch`, a no-op for `.borrowed` — so **every** spawn and reopen enters here (instantaneous for non-worktree cards). One entry point, no special cases.

**The state machine** (the only legal edges; the funnel rejects the rest):

```mermaid
stateDiagram-v2
  [*] --> creatingWorktree: spawn (all card kinds)
  creatingWorktree --> launching: cwd materialized
  creatingWorktree --> dead: materialize failed (spawnFailed)
  launching --> live: Ready signal / N liveness ticks
  launching --> dead: launch failed / timeout (spawnFailed)
  live --> live: status hook (running <-> waiting)
  live --> relaunching: resume / restart / handoff
  live --> dead: agent exited / session vanished / completed
  relaunching --> relaunching: supersede (newer resume/restart/wake; epoch++)
  relaunching --> live: relaunch confirmed
  relaunching --> dead: relaunch failed (resumeFailed)
  dead --> relaunching: restart
  dead --> live: REVIVAL - epoch-current agent signal only (never a verb)
  dead --> archived: archive
  live --> archived: archive
  creatingWorktree --> archived: archive (supersedes)
  launching --> archived: archive (supersedes)
  relaunching --> archived: archive (supersedes)
  archived --> archived: teardown completes (pending -> complete)
  archived --> creatingWorktree: reopen (re-materialize)
  dead --> [*]
  archived --> [*]
```

Three edges deserve their rationale spelled out (all from the adversarial review):
- **`relaunching → relaunching` (supersede).** Today an overlapping second resume deliberately *displaces* the first (`+Recovery.swift:315-327`, the `.superseded` waiter — dropping it instead wedges recovery; "the idle-Claude bug"). User restarts, daemon-initiated wakes, and handoffs all contend for relaunch; newest-wins is the tested semantics. The edge is nearly free: epoch++ deterministically orphans the in-flight attempt (its completion signal now carries a stale epoch and is dropped).
- **`dead → live` (revival, signal-path only).** Today a `.done` card's session stays alive by design and a new prompt revives it to `.running` (`+Report.swift:64-65,111`). The revival edge preserves that, and self-heals a timeout misclassification (a `launching` card classified `dead(.spawnFailed)` whose session comes up seconds later proves itself alive). It is legal **only** from the funnel's signal path with a *current-epoch* agent signal — no verb can drive it.
- **`archived(pending) → archived(complete)`.** Archive's teardown is a seven-duty list, not one edge; persisting its completion is what makes a crash mid-teardown re-drivable without re-spamming duties that already ran (see §P2 Archive teardown).

**The funnel is the single writer:**

```
enum TransitionResult { case applied; case noop            // already in the target phase (idempotent retry)
                        case rejected(from: Phase, to: Phase) }
@discardableResult
func transition(_ id: UUID, to: Phase, observedEpoch: Int? = nil) async -> TransitionResult
```

- The **only** place phase is written. Every verb, hook, and the reconciler go through it. It also stamps a persisted **`phaseChangedAt`** timestamp on every applied transition — the reconciler's crash-surviving timeout clock (§P2).
- **Validates edges** against the machine above and **reports the outcome**: `.applied`; `.noop` when the card is already in the target phase (a retried `archive` of an archived card is idempotent success, not an error); `.rejected` for an illegal edge (e.g. a *verb* asking for `dead → live`), which is logged and never applied. Verbs map `.rejected` to a **typed RPC error** (the client learns the verb did nothing) and `.noop` to success; async signals (hooks, liveness) ignore the result. Three semantically different cases, three visible outcomes — a silent drop can't masquerade as success.
- **Epoch guard.** Each entry into a **launch-bound phase** (`creatingWorktree`, `launching` when entered directly, `relaunching` — including the supersede self-edge) increments a persisted `sessionEpoch: Int` **before** any launch work begins. (`creatingWorktree` counts too: reopen enters there, and a late `SessionEnd` from the pre-archive session must already be stale during the checkout window — bumping only at `launching` would leave a ghost-kill hole.) Liveness ticks and `SessionEnd`/hook signals carry the epoch they observed; if `observedEpoch != current`, the funnel ignores the signal. A stale `SessionEnd` from a just-killed process carries the *old* epoch, so it is discarded **deterministically** — no timer, no race. **How signals learn their epoch:** (a) *hooks* — the launch environment stamps `ORCH_EPOCH` into the session, and the hook payload echoes it back (agent-agnostic: it's plumbing, not an agent feature); (b) *liveness* — the reconciler stamps each card's epoch into its observed-session snapshot at capture time, and the pre-kill fresh probe re-reads the current epoch, so a relaunch between snapshot and kill invalidates the kill; (c) *session identity* — the stamped env is also **readable back** (`tmux show-environment -t <session> ORCH_EPOCH`), which is how adoption and the N-tick fallback verify they are looking at the *current* epoch's session and not a dying predecessor (§P2). **Nil-epoch discipline:** a *kill-class* signal (SessionEnd / vanished) with no epoch (e.g. from a session launched pre-upgrade, before `ORCH_EPOCH` existed) never transitions a card directly — it must pass the fresh off-actor pre-kill probe first; nil-epoch *status* signals may pass. This deterministic ordering (epoch++ strictly before launch) also closes the branch's reopen race — an "early" readiness callback from the *new* session carries the *current* epoch and simply applies; there is no pending-confirmation buffer to wipe.
- **`concludeCard` fires on a non-terminal → terminal transition** (`dead` for any reason, incl. `.completed`, or `archived` from a non-terminal phase). This is the structural fix for bug #2: a parent's `wait` resolves whether the child completed or crashed. The non-terminal→terminal guard means `dead → archived` does **not** re-conclude (no duplicate inbox nudge + spurious wake), and `archived(pending) → archived(complete)` doesn't either. The wire `Conclusion` carries `{kind, deadReason?}` — `dead(reason)` derives its kind from the reason (`.completed → done`, others → failed/exited), `archive` of a non-terminal card is `.done`. `wait`'s inline short-circuit on an already-terminal child **unregisters** that child from the caller's watch (today it leaks the registration and re-delivers on a later archive). If a `dead` card *revives* (the revival edge) and later dies again, it legitimately concludes again — that's honest, not a bug.
- **Entering `live` runs the pending-wake check** (`wakeIfPending`): a message `send` while the card was `creatingWorktree`/`launching` sits in the durable inbox; the transition into `live` is the single point that guarantees it gets delivered/woken — no path-specific release sites to forget (the branch had exactly this bug: a bare `recovering.remove` skipped `wakeIfPending` and stranded the first prompt).

**What this deletes:** the `recovering: Set` (`OrchestraService.swift:96`) and the `scheduleRecoveringRelease`/`releaseRecovering` grace timers — plus it obviates the discarded branch's `provisioning: Bool?` field and `provisioning: [UUID: Task]` dict (never on main). Their jobs are subsumed by `phase` + `epoch` + the reconciler.

**`phase` replaces `status`.** Because we ship the daemon + all clients together (no cross-version interop), the old `AgentStatus {waiting, running, done, dead}` enum is **removed from the model and the wire** — it does not survive as a derived/mirrored field. `phase` is the single lifecycle field; every client renders from it via `displayState` (P6). This deletes the whole "which of four legacy buckets does creating/launching/relaunching collapse to" problem — those are simply distinct `phase` cases.

`WaitReason {permission, humanTurn}` (the "why is it waiting" detail) is **folded into the phase**: `live(.waiting(WaitReason))`. It is meaningful only inside `live(.waiting)`, so making it an associated value (rather than a free-floating field that had to be nil'd elsewhere) removes a class of "stale reason" bug. `RunState` becomes:

```
enum RunState: Codable, Equatable { case running; case waiting(WaitReason) }
```

**On-disk migration (the one compat we keep).** On first load after the upgrade, a card's persisted `status`/`waitReason` is read once to seed its `phase`: `running → live(.running)`; `waiting → live(.waiting(reason ?? .humanTurn))` (**`waitReason` is optional on disk and genuinely nil on idle cards — nil maps to `.humanTurn`, never to the unknown-record bucket**); `done → dead(.completed)`; `dead → dead(existing deadReason ?? .agentExited)` (**preserve the persisted reason — don't rewrite `sessionVanished`/`resumeFailed` history**); `archived → archived(teardownComplete: true)` (its resources were torn down under the old regime). The migration also **stamps a materialized marker onto every worktree path a migrated card references** — every pre-upgrade tree is marker-less by definition, and without this step the registry's "marker-less → re-create" rule would destroy Allen's live board on first boot (the review's C1). An upgrade-fixture test boots a pre-upgrade board containing a *dirty* worktree and asserts every byte survives. This preserves Allen's live board; it is a state migration, not a client-compat layer, and the old `status` field is dropped from the schema afterward.

**Ready signal (fixes #11), capability-gated.** `launching → live` fires on the agent's readiness signal, per `adapter.capabilities`:
- **Claude:** the `SessionStart` hook (`handleHook` `OrchestraService.swift:485`). `source == .startup` is currently dropped (`+Report.swift:52`); the funnel now consumes it as the `launching → live` trigger (still not a *status* change — it is a *phase* transition).
- **Codex:** the rollout `session_meta` line via the ~2s file-tail (`CodexAdapter.sessionId(fromRollout:):296`, parse `:94-95`). *(Note: the brief mentioned a "Codex 0.135+ SessionStart hook" for readiness — that does not exist in the code today; the Codex SessionStart hook carries orientation + a Stop drain only. Readiness = the rollout tail.)* **Rollout binding is time-scoped, not just phase-scoped:** telemetry `discover(cwd:)` may bind a rollout to a `launching` card only if the rollout file's creation/mtime **postdates the card's `phaseChangedAt`** (the current launch); with multiple candidates, newest-after-launch; on ambiguity, bind nothing (the N-liveness fallback still carries readiness). Phase-scoping alone is insufficient — after a mass reboot every co-located sibling's *stale* rollout sits in the same cwd, and a legitimately-launching card must not adopt one (the review's Codex mis-binding variant of #6, reboot case).
- **Fallback (any agent):** N consecutive liveness ticks with the session alive. This is the floor for agents with no readiness capability, and the safety net if a hook is missed.

**Readiness lands on the right `RunState`:** a *prompted* spawn transitions `launching → live(.running)`; a *provisional* (no-prompt) spawn transitions to `live(.waiting(.humanTurn))` — never `.running` for a card with nothing to run.

The same phase machine and the same **newly-introduced** timeout knobs apply to spawn, resume, restart, and reopen — main currently has *no* launch timeouts at all. §P3 introduces three wall-clock knobs (`worktreeAddTimeout` 600s — generous rather than activity-aware; a single-user tool doesn't need an idle-reset watchdog, and the worst known checkout is ~9s; `sessionLaunchTimeout` 30s; `controlTimeout` 15s for tmux control verbs + fast git queries), additive-optional in `Config` so an old `config.json` still decodes. Timeouts are **enforced by the reconciler from the persisted `phaseChangedAt`** — not by an in-flight task's clock — so they survive a daemon crash (a card can't cycle `launching`→crash→`launching` forever unclassified). A card that exhausts its phase timeout transitions to `dead(.spawnFailed/.resumeFailed)` with the git/tmux stderr — **or an explicit timeout note** — as `deadDetail`. **The N-liveness readiness fallback is N=3** (≈6s at the 2s cadence), which must stay well under `sessionLaunchTimeout` or the fallback could never fire before the timeout kills the card — the crash-recovery table's "the fallback catches a missed hook" depends on this inequality.

### P2 — Slow verbs = persisted intent, driven by an idempotent reconciler

**Principle:** the phase *is* the intent. `creatingWorktree` means "this card should have a live worktree + agent"; `archived` means "this card's resources should be released." A **reconciler** (extending `reconcileLiveness`) drives reality toward the phase, idempotently, so a crash-restart simply re-drives whatever was in flight.

**Steppers are keyed by phase, not by verb.** Verbs only `transition()`; the reconciler owns one idempotent stepper per transitional phase — **Materialize** (`creatingWorktree`), **Launch** (`launching`), **Relaunch** (`relaunching`), **Teardown** (`archived(pending)`). This is what makes phase + persisted card fields *sufficient* to recover: after a crash there is no "which verb was in flight?" question. Two derived-from-state rules make the steppers verb-agnostic:
- **Launch flavor:** any launch step derives resume-vs-blank from persisted card state alone — `agentSessionId` present + transcript on disk → resume; else blank start; `initialPrompt` is submitted only if the card has never been prompted. (So a crashed *reopen* re-drives as a resume, not a blank spawn; `restart` gets a blank because its sync part cleared `agentSessionId` in the same patch as its transition.)
- **Seed delivery:** `handoff` and seeded wakes persist a **`pendingSeed`** on the card in the *same patch* as `transition(.relaunching)` — the inbox drain folds drained messages into it, so the payload never exists only in memory. It is cleared **only on readiness at the current epoch**; a crash or `resumeFailed` keeps it for the next relaunch attempt.

**The reconciler's driving discipline** (per 2s tick, all off-actor):
- Any card in a transitional phase with **no in-flight step** is stepped — driving belongs to the reconciler loop, not to a launch-time detached task that can silently die and strand the card. **At most one in-flight step per card**; a superseding intent cancels/joins the running step at its next await.
- **Resource epilogue:** after any resource-acquiring await inside a step (worktree ensured, session created), the step re-checks the phase **on-actor**; if a newer intent superseded it (now terminal), it immediately releases what it just acquired. This closes the "ensure lands after archive's release already ran → leaked tree/session" window.
- **Timeouts from `phaseChangedAt`** (see §P1) — the reconciler classifies a card that has sat in a launch-bound phase past its knob, even across daemon crashes.
- **Failure budget:** a per-card in-memory attempt counter with capped backoff; repeated step failures emit a visible activity and degrade to a slow retry — never a hot loop, never a silent giving-up. (Transient git errors like an `index.lock` collision get a retry rather than instantly killing a spawn.)
- **Orphan-session sweep:** any observed `orchestra-<uuid>` session whose card is **archived or nonexistent** → fresh off-actor epoch-stamped probe → kill. (A `dead` card's session is *legal* — that's the revival edge / today's `.done`-keeps-session behavior.) This is the mechanism behind `test_archiveRacesLaunch_reclaimsSession`: a session created by a superseded launch step is reclaimed within a tick even if the teardown step already ran.
- **Fail-safe verification (fixes #7).** Before **any kill**, the reconciler does a **fresh, off-actor, per-card** has-session probe **stamped with the epoch** — not a decision from a stale snapshot.

  > **Design tension, resolved.** Today `reconcileLiveness` uses **one** batched `sessions.list()` snapshot per pass — but runs it **on-actor** (`+Recovery.swift:239`; P5 moves it off-actor). The fresh per-card probe is therefore scoped to **pre-kill only** (kills are rare) and runs **off-actor**. The common per-tick path keeps using the cheap batched snapshot (off-actor after P5); only a candidate-for-death card pays for a confirming probe. This does **not** reintroduce the freeze P5 removes.

- **Liveness is phase-gated.** Session-vanished detection applies **only to `live` cards**. A `creatingWorktree`/`launching`/`relaunching` card legitimately has no (or a half-born) session — it is governed by its **launch timeout**, not by liveness; a `dead`/`archived` card is at rest. This is what structurally replaces the branch's "hold `recovering` across the whole provision + through failure cleanup" dance: there is no window in which a session-less being-born card can be false-killed, and no spurious `sessionVanished` can race a `spawnFailed` classification (the funnel would reject the second terminal write anyway).

### P3 — `WorktreeRegistry` actor

A new actor that is the **sole** owner of worktree lifecycle. Nothing else touches `git worktree` directly.

| Property | Behaviour | Kills bug |
|---|---|---|
| Serialized `ensure` | Same-branch requests are serialized on the actor and **join the existing tree** instead of racing `git worktree add`. | #6 |
| Bounded git, wall-clock | Every git invocation is bounded by the new Config knobs (`worktreeAddTimeout` 600s for add, `controlTimeout` for the rest, incl. the prune fallback). A generous wall-clock knob replaces the earlier draft's idle-reset watchdog + `--progress` — activity-aware machinery a single-user tool doesn't need (worst known checkout ≈9s; if a 10-minute repo ever appears, bump the knob). | #8 (unbounded) |
| "materialized" marker | A worktree is only *adopted* if a materialized marker says it is complete — never via bare `fileExists`. **Marker-less arms (fail-safe):** *clean* dir → `git worktree prune` + re-create; *dirty* dir → **never removed** — the card goes `dead(.spawnFailed)` with a "manual cleanup needed" activity. (A dirty marker-less dir is indistinguishable from someone's uncommitted work; destroying it to satisfy an ensure would be the exact data-loss this design exists to kill. The migration stamps markers for all pre-upgrade trees — §P1 — so this arm is genuinely exceptional.) | #12, C1 |
| One removal policy via `release()` | Never remove while another non-archived card references the tree; never remove a dirty tree without explicit `force`; honor the created-flag; **idempotent to an already-missing tree** (no-op success). All teardown (spawn rollback, archive, reopen) routes through `release()`. | #1 |

This unifies today's split behaviour where **archive guards** (sibling scan + `force:false` + dirty-keep, `OrchestraService.swift:697-702`) but spawn's **orphan rollback force-removes** the just-cut branch+tree on a lineage-record failure (`OrchestraService.swift:345-351`) — and the discarded branch's provision cleanup force-removed at three more sites. After P3 there is exactly one policy and no failure path can destroy a shared/dirty tree.

**Sibling counts are computed on demand, not stored.** At each `release()` decision the registry scans the persisted cards (`store.all().filter { !$0.archived && references(path) }`) — the board is tens of cards, the scan is trivial, and a computed count **cannot drift** (a stored map would need updating on every card mutation path: archive, migration, reopen — exactly the multi-writer disease this design kills). Note a `dead` card **does** hold its reference (its tree must survive for `restart`); only `archived` releases it. There is no `rebuildRefcounts` boot step — nothing to rebuild. Cards are persisted at `transition(.creatingWorktree)` *before* `ensure` runs, so an in-flight spawn is visible to the scan.

**Why sibling-counting at all (finalization check, 2026-07-09):** main is confirmed **N:1** — the 1:1 hard spawn refusal (`7bcde48`) was reverted to a warning (`c099a82`, `OrchestraService.swift:281-287`) because co-located sibling cards on one worktree are an intentional, tested feature. The on-demand scan is the correct generalization of today's ad-hoc sibling scan. If the separate worktree-coupling design later enforces 1:1, the count simply pins at 0/1 — nothing here blocks that.

**Borrow trees belong to the registry too — with persisted registrations.** "Nothing else touches `git worktree`" includes the branch-tree borrow lifecycle: creating the throwaway `orch-borrow-<branch>` tree, the **exactly-one-borrower** rule (keyed on canonical path, today `+Borrow.swift:43-52`), release-only-your-registration, archive's open-borrow sweep, and the startup `sweepOrphanBorrows` all route through the registry (which delegates the git to `WorktreeManager` as before). Borrow registrations are **persisted** (`[borrowerCardId: path]`, atomic JSON beside the inbox) — today they are in-memory only, so the boot sweep's premise "nothing is legitimately borrowing at startup" is false after a daemon-only crash (tmux survives; a child agent may be mid-squash-merge inside the borrow tree) and the sweep **force-removes a live borrower's tree**. With persistence + the reordered boot (§P2 startup order), the sweep keeps any `orch-borrow-*` dir whose registered borrower is non-terminal. The owning-agent rule is untouched — the *agent* merges inside the borrow tree; the registry only owns the tree's lifecycle.

**Path safety (two hard rules).** (1) The registry refuses to *create* a path that escapes the worktrees root: the branch component is validated (no `..`/absolute components; component-wise prefix check on the computed path) so a maliciously-crafted branch name can't yield a card whose `cwd` escapes the allowlist. (2) The registry refuses to *remove* any path outside the roots it owns (worktrees root + `orch-borrow-*`) — a borrowed/out-of-tree dir is never rm'd by any cleanup path, no matter what a card's `cwd` says.

### P2·P3 — Degraded & missing-resource behavior (fail-safe)

What happens when a card's prerequisites have vanished — worktree deleted, branch gone, `tasks.json` corrupt? The governing rule: **self-heal toward the phase's intent if recoverable; otherwise transition to a safe terminal `dead(reason)` — never crash, hang, or destroy.** Missing resources are handled by the reconciler's steppers, not by ad-hoc call-site checks.

| Phase | Worktree missing / half-cut | Behavior |
|---|---|---|
| `creatingWorktree` | expected | `WorktreeRegistry.ensure` creates it (idempotent). Branch/repo gone → can't create → `dead(.spawnFailed)`. |
| `launching` / `relaunching` | tree vanished under a card that should be live | The stepper calls `ensure` **first** — the materialized marker re-creates the tree from the branch — then launches. **Observable:** emit an activity (`worktree missing → re-materialized from branch@<sha>`). Branch also gone → `dead(.spawnFailed/.resumeFailed)`. |
| `live` | tree vanished under a running agent | Do **not** silently recreate under a live agent (surprising), and do **not** claim liveness will notice — **it won't**: deleting a process's cwd kills nothing; the tmux session stays alive and only the agent's *tool calls* fail (the codebase documents this at `OrchestraService.swift:458-459`). Instead: a cheap cwd-exists probe on the tick **surfaces** it — a degraded activity/badge ("worktree missing — restart re-materializes it") and a useful error on `send`/wake. Never auto-kill (the agent may hold in-memory context worth a handoff); a subsequent `restart` re-materializes. |
| `dead` | at rest | No driving. `restart` → `relaunching` (self-heal above); `archive` → `release()`. |
| `archived` / any teardown | tree already gone | `release()` is **idempotent to a missing tree** — a no-op success, never a throw. `reopen` re-materializes. |

Two hard notes:
- **Unrecoverable work is surfaced, not hidden.** Re-materializing recovers to the branch's last commit; uncommitted changes in a *manually deleted* worktree are gone for good — the emitted activity says so. This is honest fail-safe, not silent "success."
- **Corrupt/missing `tasks.json` must never crash-loop the daemon — and recovery must not become destructive.** Atomic `replaceItemAt` prevents torn writes; on a genuinely unparseable file, **back it up with a timestamped name** (`tasks.json.corrupt-<ISO8601>` — a rev can't be read from an unreadable file, and today's single `.bak` is clobbered by a second corruption), log loudly, recover to empty, and keep running. Crucially, a recovered-from-corruption boot enters **conservative mode: adopt-only — no `release()` removals** — because an empty board + live tmux sessions + a working reconciler is exactly the state where re-spawning onto an existing branch adopts a tree at sibling-count 1 and a later archive would remove it out from under the lost card's still-live agent (the `sweepOrphanScratch` empty-store bail at `OrchestraService.swift:458-466` shows the codebase already knows "empty store ≠ nothing live"). Removals re-enable once ownership is positively re-established. This machinery lands **with the reconciler (Stage 4)**, not later. The on-disk migration (P1) maps an unknown/garbage legacy record to `dead(.rebootUnrevived)` — never drop the card, never throw.

### P2 — Crash recovery: any non-clean restart is just another reconciler start

The convergence guarantee is that a **SIGKILL / panic / power loss is not special** — on the next boot the reconciler re-drives every card from its persisted `phase`. This works only if the persisted state **plus what can be re-observed** is sufficient to reconstruct everything; nothing load-bearing may live only in memory.

**What survives vs. what is rebuilt:**

| State | On non-clean restart | Source of truth |
|---|---|---|
| `phase` (incl. `teardownComplete`), `sessionEpoch`, `phaseChangedAt`, `pendingSeed`, card fields, board `rev` | **Durable** | disk (`tasks.json`) |
| **Watch registry** (`[watcherId: Set<childId>]`) | **Durable** — persisted beside the inbox, reloaded at boot; already-terminal watched children get their conclusions delivered immediately on reload | disk *(new — today it is a plain in-memory dict, `OrchestraService.swift:63`, and an MCP watcher's `wait` silently dies with the daemon)* |
| **Borrow registrations** (`[borrowerCardId: path]`) | **Durable** — persisted by the registry; the orphan-borrow sweep keeps any `orch-borrow-*` dir whose registered borrower is non-terminal | disk *(new — today in-memory, and the boot sweep force-removes a live borrower's tree after a daemon-only crash)* |
| Worktrees + materialized marker | **Durable** | disk |
| **tmux sessions** | **Survive a daemon crash; gone on a machine reboot** | `tmux list-sessions` (the key fork below) + per-session `ORCH_EPOCH` identity readback |
| Worktree sibling counts | Nothing to rebuild — **derived on demand** from persisted cards at each `release()` decision | the store |
| Observed-session cache | Lost → **rebuilt** | one `tmux list-sessions` |
| In-flight stepper work, debounce timers, RPC continuations, reconciler loop, attempt counters | Lost → **re-driven / re-established** | the `phase` (intent) |

**The one fork that changes everything — daemon crash vs. machine reboot:**
- **Daemon crash (tmux alive):** `live`/`launching` cards **adopt** their surviving session at the *persisted* epoch — **no relaunch**. The reconciler launches only when the session is genuinely gone.
- **Machine reboot (tmux gone):** every session vanished; each card resumes/restarts per capability (`isResumable`), else → `dead(.rebootUnrevived)`.

**Per-phase reconciliation on the next boot:**

| Phase at crash | Recovery |
|---|---|
| `creatingWorktree` | Re-drive `ensure` (adopt if marker present, re-materialize if half-cut — see §P3 marker arms) → `launching`. Branch gone → `dead(.spawnFailed)`. (Fixes the #5 stuck-Creating.) |
| `launching` | Session alive **and its `ORCH_EPOCH` readback matches the persisted epoch** → adopt + await readiness / N-liveness → `live`. **A SessionStart hook that fired into the dead daemon is lost — the N-liveness fallback catches it.** Session gone → relaunch (idempotent `ensure`, no duplicate). |
| `live` | Session alive + epoch matches → **stay `live` at the persisted epoch** (adopt, never bump). Session gone → fresh pre-kill probe → `dead(.sessionVanished)`, or resume on a reboot per capability. |
| `relaunching` | Session alive: **read its `ORCH_EPOCH` back.** Matches the persisted epoch → the new session came up before the crash → `live`. **Older** → it is the pre-relaunch session not yet killed → **complete the relaunch** (kill + launch — this is the user's persisted intent, not an uncertainty-kill; adopting it would freeze the card, since all its signals carry the stale epoch). Session gone → launch (`ensure` re-materializes a missing tree first; `pendingSeed` still on disk is delivered). A stale `SessionEnd` from the killed *old* session carries the old epoch → **ignored** by the funnel. |
| `dead(reason)` | At rest (its session, if any, is *legal* — revival edge). Conclusion is **derived** from the phase, so nothing to re-drive on the daemon side (see requirement 2). |
| `archived(pending)` | **Re-drive the Teardown stepper** — the full duty list, not just `release()` (see "Archive teardown" below). `archived(complete)` is at rest; the orphan-session sweep is the backstop for anything that leaked. |

**Three requirements this imposes (each becomes a crash-restart test):**
1. **Adopt, don't relaunch.** A surviving session for a `live`/`launching` card is adopted at its persisted epoch; the reconciler relaunches *only* when the session is truly gone. This is **already** the behavior (`recoverSessions` skips alive sessions, `+Recovery.swift:23`) — the phase model carries it forward, adopting at the persisted epoch. Idempotency (stable card id + `ensure` short-circuiting on an alive session) guarantees re-driving never spawns a duplicate session or card.
2. **Conclusion is derived from the terminal phase — no stored "concluded" flag.** `isConcluded ≡ phase ∈ {dead(*), archived}`, read from persisted state. Entering a terminal phase notifies any *live* waiter; a parent that reconnects after a restart **re-issues `wait`**, and the daemon short-circuits on the persisted terminal phase. So a crash between "enter dead" and "notify" self-heals via the client re-issue — no persisted ack bit. Critically, **every** dead reason counts as concluded (incl. `.spawnFailed`): this is the true bug-#2 fix — today `isConcluded` only counts `done`/`archived`/`dead+agentExited` (`+Wake.swift:136`), so `spawnFailed`/`sessionVanished` silently hang the parent.
3. **The CLI-wait continuations stay in-memory; the MCP watch registry does NOT.** `MergeWatch` (`MergeWatch.swift:20`) holds live continuations, so it *cannot* be persisted — and doesn't need to be: a blocked CLI parent re-issues `wait` on reconnect (P4 deadline/keepalive tears down the dead call; the harness re-drives it — see [[orchestrator-nonblocking-wait]]), and the daemon answers from the persisted terminal phase. But the **MCP watch registry is different**: it is fire-and-forget (`wait` returns `{"watching": true}` and the parent goes idle expecting an inbox nudge at conclusion) — there is **no outstanding call to re-issue**. Today it is a plain in-memory dict (`OrchestraService.swift:63`; the earlier draft of this spec wrongly called it durable), so a daemon restart silently orphans every MCP watcher — bug #2's hang shape surviving the redesign. Fix: **persist the watch registry** (a tiny `[UUID: Set<UUID>]`, same atomic-JSON pattern as the inbox), reload at boot, and on reload immediately deliver conclusions for any watched child already in a terminal phase. *(The git-config lineage SSOT from the branch-tree work provides the persisted parent↔child link; the `wait` recovery above does not depend on it.)*

**Startup order (integration with the branch-tree rebuilds).** Phase reconciliation replaces `recoverSessions` in the boot sequence (`orchestrad/main.swift:47-53`), and the **borrow sweep moves after it**: `sweepOrphanScratch → phase reconciliation (adopt/re-drive, incl. Teardown re-drives) → registry.sweepOrphanBorrows (liveness-guarded: keeps any orch-borrow-* dir whose persisted registration names a non-terminal borrower) → watch-registry reload (deliver already-terminal conclusions) → rebuildRemoteWatches → rebuildMergeRequestNudges → one-shot treeStat recompute for non-terminal cards (a quiet board otherwise shows stale sync badges forever)`. Sweeping borrows *before* adoption — today's order — force-removes a live borrower's tree after a daemon-only crash; that ordering bug does not survive this design. The last rebuilds are already-landed, generation-guarded per-card loops — the reconciler coexists with them, it does not absorb them.

**Archive teardown (the Teardown stepper).** Teardown via `release()` is necessary but not sufficient — today's archive also **kills the session (`OrchestraService.swift:689` — a duty an earlier draft's list missed)**, cancels the card's treeStat/child-fanout debounces (`:671-672`), stops its remote watch loop, cancels its merge-request re-nudge timer, sweeps an open borrow (`:665-668`), and nudges live children that the parent branch is now bare (`:673-688`). The Teardown stepper performs the list in a fixed order — **kill session → release borrow → release tree → cancel in-memory loops → nudge children** — and each duty is individually idempotent: session kill (no-op if absent), releases (no-op-on-missing), loop cancels (in-memory), and the child nudge **carries an inbox dedup key** (`(childId, "parent-archived:<branch>")` — `Inbox.enqueue` gains an optional dedup key) so a re-driven teardown can't re-spam or spuriously re-wake children. Completion flips `archived(pending) → archived(complete)`, which is what bounds boot-time re-drives to genuinely unfinished teardowns.

### P4 — Sync contract: monotonic `rev` + idempotency + deadlines

| Mechanism | Detail | Kills bug |
|---|---|---|
| **Board `rev`** | `TaskStore` stamps a monotonic `rev` on every mutation. Every `Event` **and** `boardSnapshot` carries it. Clients apply iff `rev > lastSeen`; a gap → resync (fetch a fresh snapshot). | #14 |
| **Client-minted ids** | Spawn accepts an optional client-minted card id (message ids for `send`); the server dedups on it. A retry over dropped SSH is idempotent — no duplicate card. | #15 |
| **Per-RPC deadlines + ping keepalive** | `ControlClient.call` gets a deadline; a periodic ping detects a dead-but-open tunnel. Safe *because* mutations are now idempotent/reconcilable. | #15 |
| **Fast RPCs** | Every RPC enqueues intent and returns `(card, rev)` immediately; long outcomes arrive as phase-transition events. | actor-freeze-on-RPC |

**Wire mechanics (clean break).** `rev` is a first-class field on the `Event` type and on `BoardSnapshot` — the `Event` type may be restructured freely (add cases, add fields) since there are no old clients to placate. `phase`/`sessionEpoch` are required `Task` fields; the client-minted `id` is required on `spawn`/`send`. The only defaulting is the one-time on-disk read of a pre-upgrade `tasks.json` (see P1's migration note).

### P5 — Actor hygiene

The single service actor must **never** run a subprocess or blocking file IO on-actor. Move these off-actor (bounded) — see §9 for the full list with line numbers:

- diff render, diffstat recompute, changed-notes → off-actor.
- `exec` (up to 120s) → off-actor.
- `pollTelemetry`'s recursive `$CODEX_HOME/sessions` enumeration → off-actor.
- `prepareToLaunch`'s whole-`~/.claude.json` rewrite → off-actor.
- **`boardSnapshot` serves session state from the reconciler's observed cache** — no per-request 2×N tmux shelling (`OrchestraService.swift:805-820`).
- **`TaskStore` splits archived to an append-only file** and **debounces telemetry persists** — no whole-file rewrite (incl. archived) per delta (#13).

### P6 — UI contract

One function, `displayState(phase, connection)`, in `OrchestraKit` feeds every surface (mac + iOS). Each phase **declares its valid actions as data** (not per-button knowledge scattered in views):

- In-flight actions are **disabled** (fixes double-click Spawn, #15-UI).
- **Honest toasts** — no "Archived" on a failed archive; unknown outcomes show "resyncing…".
- A **stale-since banner** when `connection` is degraded (built on the new `rev`/keepalive signal).
- **Terminals attach when the phase says `live`**; the mac terminal copies the iOS bounded-backoff retry loop (`IOSTerminalView.swift:313-348`) instead of attaching once.
- **`validActions` is derived, not hand-maintained:** `displayState` computes each phase's valid actions from the verbs' `phaseGate`s in the shared `CommandCatalog` (+ UI-only extras) — one verb×phase table in the whole system, so daemon policy and UI gating cannot drift.

---

## 6. The verb contract (typed)

**Requirement (Allen's, explicit):** verb differences must be well-defined, typed, and organized so future verbs are easy to add correctly.

Three kinds, one declaration each:

```mermaid
classDiagram
  class VerbSpec {
    +String name
    +VerbKind kind
    +Set~Phase~ phaseGate
  }
  class QueryVerb {
    reads observed state
    read-only, retry-free
  }
  class MutationVerb {
    completes inline, idempotent
    may hop off-actor, never changes phase
    card writes are field-delta patches
  }
  class ConvergenceVerb {
    sync part = one transition() + returns (card, rev)
    the reconciler's phase-keyed stepper drives the rest
  }
  VerbSpec <|-- QueryVerb
  VerbSpec <|-- MutationVerb
  VerbSpec <|-- ConvergenceVerb
```

`VerbSpec` carries exactly three fields. The adversarial pruning pass cut two more that earned no keep: a `capability` requirement (the type doesn't exist in the codebase; all real capability gating lives in the adapters, where it already works) and a per-verb `converger` reference (the reconciler dispatches steppers **by phase**, never by verb — a verb→converger field would be decorative). Each verb's idempotency story is a doc comment on its declaration, not a schema field nothing reads. **Gate enforcement has one chokepoint:** the registry dispatch path checks `phaseGate` against the target card's phase before invoking the handler (verbs declare which param names their target card); a gated-out call returns a typed error naming the phase.

| Kind | Contract | Verbs (all 32 registered) |
|---|---|---|
| **QueryVerb** | Read-only: never writes card state, never changes `phase`. May do a *bounded, off-actor* subprocess read (tmux capture, git-config lineage read). Retry-free. | `list`, `status`, `sessions`, `capture`, `tree`, `trustState`, `inbox` |
| **MutationVerb** | Completes inline; **idempotent**; may hop off-actor for bounded git/tmux work; **never changes `phase`**. Protocol **requires** `phaseGate: Set<Phase>` + an idempotency story. Card-state writes go through the store as field-delta patches (never whole-object); `phase` writes are forbidden (compile-visible: only the funnel writes `phase`). | `move`, `send`, `trust`, `wait` (registers a durable watch; short-circuits on a terminal phase), `inbox-edit`, `inbox-remove`, `inbox-reorder`, `set-parent`, `synced`, `shipped`, `merge-request`, `borrow`, `release`, `shell`, `inspect`, `closeShell`, `exec`, `send-keys` (`rename` stays a status-hook projection — resolved decision §12.3) |
| **ConvergenceVerb** | Sync part **only** persists intent (a `transition()`) + returns `(card, rev)`. The reconciler's phase-keyed stepper (idempotent `step()`/`verify()`) drives the rest. | `spawn`, `batch-spawn`, `archive`, `reopen`, `resume`, `restart`, `handoff` |

Notes on the finalized classification: the seven branch-tree verbs are **Mutations** — they do slow git/gh work but complete inline from the client's view and never touch `phase` (their slow parts hop off-actor per P5). `shell`/`inspect` are Mutations *with a real phaseGate* — denying them during `creatingWorktree`/`launching`/`relaunching` **is** the bug-#3 fix, declared as data and enforced at the dispatch chokepoint. `tree` is a pure lineage read. `treeStat` (the branch-vs-parent sync state machine) deliberately stays **outside** `phase`: it is orthogonal to lifecycle (a `live` card can be `inSync` or `restackNeeded`), has its own landed writers with lost-update guards, and folding it in would multiply the phase matrix for zero safety gain.

**Two verbs are long-running by contract** — `wait` (the CLI transport holds the RPC open until a watched child concludes; the MCP transport registers the durable watch and returns inline) and `exec` (bounded at 120s). Both are exempt from the "completes inline" rule, are bounded + off-actor, and clients set matching per-RPC deadlines (the CLI `wait` deadline + re-issue is the P2 recovery story).

**The default gate policy** (so ~30 verbs × 8 phases are derived, not invented; `Set<Phase>` is the *allow-set* — an absent phase is denied, which means a future phase defaults to **deny**, the fail-safe direction):
- **Query verbs:** all phases.
- **Session-touching mutations** (`shell`, `inspect`, `closeShell`, `exec`, `send-keys`): deny `creatingWorktree`/`launching`/`relaunching` (bug #3); allow `live` and `dead` (post-hoc inspection of a surviving session); deny `archived`.
- **Lineage mutations** (`set-parent`, `synced`, `shipped`, `merge-request`, `borrow`, `release`): allow `live` + `dead`; deny being-born phases (the worktree may not exist) and `archived`.
- **Board mutations** (`move`, `send`, `trust`, `inbox-*`): all non-archived phases (`send` to a being-born card parks in the inbox — the wake-on-live rule delivers it).
- **`wait`:** all phases (short-circuits on terminal).
- **Convergence verbs:** the gate *is* the machine's entry edges — `spawn` (new id only), `archive` (any non-archived), `reopen` (`archived` only), `resume`/`restart` (`live`, `dead`, or `relaunching` = supersede), `handoff` (`live`, `dead`).

**Idempotent retry semantics, stated plainly:** there is **no automatic retrier** anywhere in this design — a deadline expiry surfaces as an error to the human/agent, who re-issues. Idempotency exists so that re-issue is always safe: a `spawn` retried with its client-minted id returns the existing card **as-is, whatever its phase** (even `dead(spawnFailed)` — honest); a retried `archive` of an archived card is `.noop` success; `batch-spawn` is **N independent spawn intents with N client-minted ids** (the batch RPC itself is not an intent — a partially-acked batch retried over dropped SSH dedups per item). `send` dedup is deliberately **not** built: without an auto-retrier, a re-sent message is user intent, and `InboxMessage.id` already exists if that ever changes.

**The stepper protocol (stateless — phase + persisted card fields are the whole input):**

```
protocol PhaseStepper {
  static var drives: Phase.Kind { get }             // creatingWorktree | launching | relaunching | archivedPending
  func step(_ card: Task, _ ctx: ConvergeContext) async throws  // idempotent: advance one edge toward the target
  func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool // has the target been reached?
}
```

A stepper holds **no per-card state** — `cardId` arrives as an argument, because crash-recovery's whole premise is that everything re-derives from the persisted card. `ConvergeContext` is a plain dependency bundle (store, registry, sessions, adapters, `transition`) so steppers are testable with stubs and steppable off-actor.

**Verb conflicts stop being pairwise races.** A newer intent supersedes an older one; the reconciler redirects. *Archive-during-provision* is just a newer intent: the funnel moves the card to `archived(pending)`, the running Materialize/Launch step observes it at its resource epilogue (or the next tick's Teardown step + orphan-session sweep does), and teardown routes through `WorktreeRegistry.release()`. No special-case race handling.

**Where it lives.** Extend `CommandSchema` (`CommandCatalog.swift` — in OrchestraKit, so all three clients share it at compile time) with `kind` + `phaseGate`; the steppers live with the reconciler (`OrchestraCore`), keyed by phase. The hardcoded non-registry switch in `ControlServer.swift` stays as-is — folding its read-only endpoints into the registry is cosmetic churn with no bug behind it (cut at finalization).

**Two suite-enforced matrix tests:**
1. **Phase-gate soundness** — every Mutation/Convergence verb declares a **non-empty** `phaseGate` consistent with the default gate policy above, and the dispatch chokepoint enforces it (probe one denied phase per verb). `Set<Phase>` semantics make an *unconsidered* new phase deny-by-default — the fail-safe direction — so completeness needs no "explicitly declared" ceremony (an earlier draft demanded one, which a Set cannot even represent).
2. **Stepper crash-convergence** — for every `PhaseStepper`, kill the daemon at each `step()` boundary, re-run the reconciler, and assert `verify()` becomes true. Iterates **phases**, the reconciler's real dispatch key. This is the structural guarantee behind P2.

---

## 7. Testing strategy

| Test | What it proves | Ties to |
|---|---|---|
| **Phase-edge property test** | Every legal edge applies; every illegal edge is rejected by the funnel. | P1 |
| **Epoch-stale-signal test** | A `SessionEnd`/liveness signal carrying an old epoch is ignored; the card is not killed. | P1 (replaces `recovering`) |
| **Stepper crash-restart tests** | Kill at each step of each `PhaseStepper` → reconciler converges. | P2, matrix test #2 |
| **Adoption-identity tests** | A `relaunching` card with a surviving *old-epoch* session: boot completes the relaunch (kill+launch), never adopts; a matching-epoch session is adopted. The N-tick fallback never promotes an old-epoch session. | P2 (epoch readback) |
| **Zombie-reclaim tests** | A session created after archive superseded its launch is killed within a tick (orphan-session sweep); an `archived(pending)` card crash-restarts into a full duty-list re-drive with **no duplicate child nudges** (inbox dedup key) and the session dead; a `dead(.completed)` card's surviving session is **not** killed and a new prompt revives the card (`dead → live`). | P1 revival + P2 sweep + Teardown |
| **Durable-registry tests** | MCP `wait` survives a daemon restart (watch registry reloaded; an already-concluded child delivers immediately); a borrow survives a daemon-only crash (registration persisted; sweep keeps the live borrower's tree). | P2 persisted registries |
| **Upgrade-fixture test** | A pre-upgrade board incl. a **dirty** worktree boots cleanly: every card mapped (nil `waitReason` → `.humanTurn`; `deadReason` preserved), markers stamped, **every byte of the dirty tree intact**. | P1 migration + C1 |
| **Batch idempotency** | A partially-acked `batch-spawn` retried with the same per-item ids creates no duplicate cards. | P4 |
| **Phase-gate completeness matrix** | Every verb declares a gate for every phase. | Verb contract test #1 |
| **`rev`-gap / stale-event transport tests** | A gap triggers resync; a late stale event (`rev ≤ lastSeen`) is dropped, not applied. | P4 |
| **Idempotent-spawn test** | Same client-minted id twice → one card. | P4 |
| **Slow-repo E2E fixture** | A ~28k-file repo (~9s checkout window) exercises race-free `WorktreeRegistry.ensure` under two same-branch spawns and a non-frozen actor during checkout. (Smoke, not proof — every race it exercises also has a deterministic stub test.) | P3, P5 |
| **Agent-agnostic coverage** | The Claude-only provisioning tests are extended to **Codex** (readiness via rollout tail, `.relaunchLiveness`). | Constraint |
| **Missing-resource / degraded tests** | Delete the worktree under a `relaunching` card → re-materialized (+ observable activity); delete branch too → `dead(.resumeFailed)`; `release()` on a missing tree → no-op success; corrupt `tasks.json` → timestamped backup + conservative-mode recovery; a dirty marker-less dir is never removed. | P2·P3 fail-safe |
| **Supersede-race tests (mined from the discarded branch)** | Archive fired during `creatingWorktree` (mid-checkout), during `launching`, and in the narrow post-session-create window → converges to `archived` with the session killed + tree released within a reconciler tick; no resurrection by a late success/failure flip (the funnel rejects the edge). Run for **worktree, scratch, and borrowed** spawns. | P1 + P2 verb-conflict model |
| **Stranded-message test** | `send` to a `creatingWorktree`/`launching` card → delivered (card woken) once it enters `live`; no path-specific release site to forget. | P1 wake-on-live |
| **Codex rollout-binding test** | A Codex card in `launching` next to a live sibling in the same repo does **not** adopt the sibling's rollout; binding only at `launching`+current-epoch or `live`. | P1 readiness scoping |
| **Path-safety tests** | A branch name with `..` components is rejected at `ensure`; no cleanup path removes a dir outside the registry's owned roots even if `cwd` points elsewhere. | P3 path safety |
| **Deterministic stubs over E2E (test doctrine)** | Race/crash tests use blockable seams (blockable `ensure`, sleep-injecting session stubs, kill-at-step hooks) — the E2E variants are smoke, not proof (the review demonstrated an E2E "regression test" that passed on unfixed code). | all |

---

## 8. Migration outline (each stage shippable; suite stays green)

**Base decision (Allen, 2026-07-09):** build the phase model **fresh on `main`** and **discard** the `fix/spawn-hang-standalone` branch. That branch is 13 unique commits off a pre-branch-tree `main`; its core (`provisioning` flag + `provisioning[id]` dict) is exactly what Stage 2 deletes, and its 15 bugs are properties of *that* implementation — a fresh build never introduces most of them. **This supersedes the original brief's "Stage 0 as a follow-up card on `fix/spawn-hang-standalone`."** Non-blocking spawn is delivered **correctly in Stage 2** (`creatingWorktree → launching → live` + the "Creating…" pill via `displayState`) rather than carried over. The branch is kept read-only to **mine its hard-won edge cases** (the `review:` / `found via live isolated-daemon verify` commits — archive-races-launch reclaim, clear-provisioning-on-dead) as a test checklist.

Detailed task breakdown is in the plan doc. Stage summaries (all on a fresh branch off `main`):

| Stage | Scope |
|---|---|
| **~~0 — P0 hotfixes~~ (dissolved)** | The P0 concerns (no force-remove of dirty/shared trees, conclude on spawn-fail, don't let `openShell` claim the session) are satisfied **by construction** — WorktreeRegistry (P3), funnel conclude-on-terminal (P1), and the phase gate (P6). No separate hotfix card; the branch is not merged. |
| **1 — Sync `rev` + delta writes** | Board `rev` in `TaskStore`; `report()` becomes a field-delta write (interim fix for #4's clobber). |
| **2 — Phase + funnel + epochs** | The phase enum, `transition()` funnel (+ `TransitionResult`), `sessionEpoch` + `phaseChangedAt`; **removes `status`** (one-time on-disk migration seeds `phase`, stamps markers, preserves `deadReason`). Spawn stays **synchronous** here — it walks the phases inline, so a failure classifies inline and the stage ships without the not-yet-built reconciler safety net. |
| **3 — WorktreeRegistry** | The registry actor + on-demand sibling counts + materialized marker (incl. the fail-safe marker-less arms) + one removal policy (incl. borrow trees, persisted borrow registrations, path safety); **introduces the wall-clock timeout knobs** (main has none). |
| **4 — Reconciler + steppers** | The phase-keyed steppers (Materialize/Launch/Relaunch/Teardown) + the reconciler's driving discipline (one step per card, epilogue, `phaseChangedAt` timeouts, backoff, orphan-session sweep); **delivers non-blocking spawn** (the window and its `phaseGate` ship together); startup phase reconciliation; persisted watch registry; `pendingSeed`; corrupt-`tasks.json` recovery + conservative mode; the verb contract + matrix tests. |
| **5 — Actor hygiene** | Off-actor sweep (incl. the branch-tree git probes); `TaskStore` telemetry-persist debounce (the archived-file split was cut at finalization — the debounce alone bounds #13's write amplification); snapshot-from-cache. |
| **6 — Idempotency + deadlines + UI** | Client-minted ids for spawn/send; per-RPC deadlines + ping; `displayState` UI gating + honest toasts + mac terminal retry loop. |

---

## 9. On-actor blocking call sites (P5 work list)

Confirmed sites that run subprocess/file IO directly on the `OrchestraService` actor (anchors @ `f1aa568`):

| Site | Call | File:line |
|---|---|---|
| spawn | `worktrees.ensure` (git checkout, **unbounded**) | `OrchestraService.swift:312` |
| spawn | `sessions.ensure` (tmux launch, **unbounded**) | `:422` |
| exec | `Proc.run(sh -c, timeout 120s)` | `:795` |
| diffText | `GitDiffProvider().render` | `+Diff.swift:18` |
| recomputeDiffStat | `GitDiffProvider().stat` (debounced onto a detached Task) | `+Diff.swift:42` |
| changedNotes | `launcher.changedNoteFiles` | `+Notes.swift:16` |
| pollTelemetry | rollout tail (recursive enumeration now lives in `CodexAdapter.rolloutFiles`), every 2s | `OrchestraService.swift:224`; `CodexAdapter.swift:282-284` |
| prepareToLaunch | `~/.claude.json` read-merge-rewrite (multi-MB parse) | `ClaudeCodeAdapter.swift:127`→`ClaudeTrust.apply:305`/`grant:314` |
| boardSnapshot | serial 2×N tmux verbs | `:805-820` |
| sweepOrphanScratch | `sessions.list()` | `:467/:482` |
| reopen | `worktrees.ensure` (**unbounded**) | `+Recovery.swift:211` |
| reconcileLiveness (every 2s) | batched `sessions.list()` | `+Recovery.swift:239` |
| **branch-tree (new):** `gitRemotes` | `Proc.run(git remote)` — on spawn's hot path *and* the report→treeStat funnel | `+ParentRef.swift:13-17` |
| **branch-tree (new):** local tree probes | `treeTip`/`treeBehind*`/`treeBaseIsAncestor`/`mergeBaseOID`/`revParseOID` | `+Tree.swift:501-541` |
| **branch-tree (new):** remote-redirect probes | `privateRefOID`/`localBranchOID`/`isAncestor` | `+Remote.swift:223-237` |
| **branch-tree (new):** `WorktreeManager` is a struct | *all* its `Proc.run` (ensure/borrow/remove/prune) runs on the caller's actor | `WorktreeManager.swift:5` |

Already off-actor (the model to follow): `GhProbe` (Task.detached, `GhProbe.swift:53-57`), `RemoteParents` (actor), `BranchLineage` (actor).

---

## 10. Docs (SSOT) to update

`docs/` is the project source of truth (auto-synced from `main`). Pages this design changes:

| Page | Sections |
|---|---|
| `docs/02-architecture.md` | `#the-control-plane`, `#request-flow-server-side`, `#the-client-transport-seam-and-reconnect` (the `rev` sync contract + deadlines); `#the-three-clients` (shared verb taxonomy); `#the-daemon-orchestrad` (WorktreeRegistry as a daemon component) |
| `docs/03-data-model.md` | `Task` schema — new `phase` + `sessionEpoch` fields; **`status` + `waitReason` removed** (folded into `phase`); note the one-time on-disk migration |
| `docs/04-cards-worktrees-sessions.md` | `#worktrees` (registry, marker arms, on-demand sibling counts, persisted borrows), `#sessions-tmux`, `#recovery-resume-and-restart` (the funnel replaces scattered transitions) |
| `docs/05-command-reference.md` | Verb catalog classified Query / Mutation / Convergence |
| `docs/09-design-decisions.md` | New: phase + epoch funnel; steppers; durable teardown. Amend `#11-worktree-card-ownership` for the registry's computed sibling check. |

---

## 11. Decisions made

| Decision | Why | Rejected alternative |
|---|---|---|
| One persisted `phase` + single `transition()` funnel | Single writer eliminates the 4-variable disagreement class | Keep separate vars, add more guards (today's approach — the bug source) |
| Per-launch `sessionEpoch` guard | Makes stale signals deterministically harmless | `recovering` set + grace timers (racy, in-memory, lost on restart) |
| `concludeCard` on entering **any** terminal phase | A parent's `wait` must resolve on crash *and* completion | Conclude only on clean exit (bug #2) |
| Reconciler drives intent; verbs persist it | Crash-restart re-drives in flight work; no orphaned flags | Edge-triggered verbs (today) |
| `WorktreeRegistry` is the sole git-worktree owner | One removal policy; serialized ensure + computed sibling check kill races + data-loss | Scattered `git worktree` calls with per-site guards |
| Board-global monotonic `rev` (first-class field on `Event`/`BoardSnapshot`) | Simple gap detection | Per-card rev (more state, still needs a global cursor for gaps) |
| Break the wire; `phase` replaces `status`; `WaitReason` folds into `live(.waiting)` | Single-user, we ship all clients together; deleting the compat layer + the down-projection removes real complexity | Additive-only / derived `status` (carries the frozen enum + a lossy projection forever) |
| Keep only a one-time on-disk `tasks.json` migration | Don't nuke Allen's live board on upgrade | Wipe state on upgrade (simpler, but loses the board) |
| Missing prerequisites → self-heal toward intent, else safe `dead(reason)` | Never crash/hang/destroy; re-materialize recovers to last commit and is observable | Fail hard on a missing tree (gives up recoverable work); or silently recreate (hides lost uncommitted work) |
| Refcount rebuilt from persisted card refs on startup | A crash can't leave a stale count | Persist the counter (drifts on crash) |
| Corrupt `tasks.json` → back up + recover, never crash-loop | Daemon stays up; board recoverable | Crash on parse error (unrecoverable boot loop) |
| Conclusion is derived from terminal `phase`; watch registry stays in-memory | `isConcluded ≡ terminal phase` + client `wait` re-issue self-heals across a crash; a persisted flag would be redundant | Persist a "concluded/notified" ack bit (extra state, still needs client re-issue anyway) |
| `isConcluded` counts **every** terminal reason (incl. `spawnFailed`/`sessionVanished`) | The durable bug-#2 fix — today only `done`/`archived`/`dead+agentExited` conclude, so other deaths hang the parent | Conclude only on clean exit (the current hang) |
| Adopt surviving sessions at the persisted epoch (already `recoverSessions` behavior) | A daemon crash must not kill working agents | Relaunch on every restart (kills healthy agents) |
| Rebuild fresh on `main`; discard `fix/spawn-hang-standalone` | Stage 2 deletes the branch's core (`provisioning`); its 15 bugs are its implementation; the value is already in this spec. Merge cost is low (13-commit rebase / ~5-file conflict) but irrelevant to the demolish-churn argument | Integrate-then-build on the branch (build-then-delete churn); ship-the-branch-first (merges throwaway machinery to main) |
| Pre-kill fresh probe is off-actor + kill-only | Correctness without reintroducing the actor freeze | Per-tick per-card probe (freezes actor) / stale snapshot (bug #7) |
| Keep the single service actor | Avoids a concurrency rewrite | Per-card executors |
| Liveness is phase-gated to `live` | A being-born card can't be false-killed; no `recovering`-style hold-across-provision dance | Guard-set choreography (the branch's approach — 3 of its hard-won fixes were holes in it) |
| Epoch++ strictly *before* launch; sessions stamped with `ORCH_EPOCH`; hook payloads echo it | Signals are attributable deterministically; closes the branch's reopen early-callback race with no pending-confirmation buffer | Grace timers / buffer resets (racy) |
| `wakeIfPending` runs on the funnel's entry into `live` | One structural delivery point for messages sent to a being-born card | Per-path release sites (the branch stranded the first prompt by missing one) |
| Keep sibling-counting despite the worktree-coupling 1:1 target | Main is confirmed N:1 (`c099a82` reverted the refusal; co-located cards are a feature); the count degenerates to 0/1 if 1:1 lands later | Owner-map/1:1 enforcement here (regresses a live feature; belongs to the other design) |
| `treeStat` stays outside `phase` | Orthogonal state machine (a `live` card can be `stale`); folding it in multiplies the phase matrix for zero safety | One mega-enum of lifecycle × sync state |
| One `relaunching` phase; restart clears `agentSessionId` in the same patch | The persisted card state itself encodes resume-vs-blank; a crash mid-relaunch recovers the *user's chosen* flavor | `relaunching(kind)` phase split (more matrix rows) or a second intent field (violates single-variable) |
| Timeout knobs are introduced by this design, additive-optional in `Config` | Main has **no** launch/checkout timeouts (the named knobs were branch-only); an old `config.json` must still decode | Assuming the knobs exist (the spec's original #9 framing — wrong against main) |
| Wall-clock knobs, not an idle-reset watchdog | The invariant is "a wedged process is eventually killed off-actor"; a generous 600s add-knob satisfies it for a single-user tool (worst known checkout ≈9s) | `--progress` + activity-aware `Proc` deadline resets (machinery for a hypothetical repo; cut at finalization) |
| Borrow trees route through the registry, registrations **persisted** | "Nothing else touches git worktree" must include borrows; and the boot sweep must be able to tell a live borrow (daemon-only crash) from an orphan | In-memory registrations + sweep-before-adoption (today's order force-removes a live borrower's tree) |
| Phase-keyed steppers; verbs only transition | Crash recovery must never ask "which verb was in flight?" — phase + persisted fields are the whole input; launch flavor derives from `agentSessionId`/transcript, seeds from `pendingSeed` | Verb-keyed Convergers with per-card instances (state the design promises not to need; a crashed reopen would re-drive as a blank spawn) |
| `transition()` returns `applied`/`noop`/`rejected` | An illegal verb must surface a typed error; an idempotent retry must read as success; a silent drop can't masquerade as either | Void return (three different cases, one invisible outcome) |
| `relaunching → relaunching` supersede edge | Preserves today's tested newest-wins (`.superseded`, `+Recovery.swift:315-327`); epoch++ makes it deterministic and nearly free | Deny-and-retry (wedges corrective restarts behind the in-flight attempt's timeout) |
| `dead → live` revival edge (signal-path only) | Preserves today's `.done`-card re-prompt revival; self-heals timeout misclassification | Kill the session on `.completed` (breaks post-hoc inspection; a behavior change nobody asked for) |
| `archived(teardownComplete:)` persisted in the phase | A seven-duty teardown must be re-drivable after a crash without re-spamming duties that ran (+ the inbox dedup key) | A one-shot duty list (crash = zombie session + lost child nudges) or unbounded per-boot re-drives |
| Watch registry persisted | An MCP watcher is fire-and-forget — there is no call to re-issue after a daemon restart; without persistence, bug #2's hang survives for every orchestrator card | "Durable by construction" (the earlier draft's claim — factually wrong; it's an in-memory dict) |
| Reconciler owns driving; timeouts from `phaseChangedAt` | A detached launch task can die silently and strand a card; an in-flight clock resets on crash — the reconciler + a persisted timestamp survive both | Launch-time detached tasks owning their own timeout clocks |
| Sibling counts computed on demand | A stored map must be maintained by every card-mutation path — the multi-writer disease again; the scan is trivial at this scale | Stored `[branch: refcount]` + startup rebuild (drift risk for zero gain) |

## 12. Resolved decisions (Allen, 2026-07-08)

These were open at review; Allen's calls are now binding on the design above and the plan.

| # | Question | Decision |
|---|---|---|
| 1 | Concluded-card representation | **`dead(reason: .completed)`.** `concludeCard` fires on entering *any* terminal phase, so a parent's `wait` resolves on both crash and clean completion. No separate `concluded` phase. |
| 2 | `rev` scope | **Board-global monotonic `rev`.** A missed `rev` resyncs the whole board (already the reconnect path). |
| 3 | `rename` classification | **Leave as a status-hook projection**, not a first-class verb. (The full MutationVerb set is the finalized §6 table — 18 verbs; this decision's original "`move`/`send`/`trust`" list predates the branch-tree verbs.) |
| 4 | Codex readiness | **SessionStart-hook-readiness is a Claude capability**; Codex readiness is the rollout `session_meta` tail + the N-liveness-tick fallback. (The brief's "Codex 0.135+ hook" is not in the code.) |

## 13. Risks & fail-safe defaults

- **Fail-safe on uncertainty:** never kill without a fresh epoch-stamped probe; never force-remove a dirty/shared worktree; on any ambiguity, keep the card and the tree.
- **Flag-day rollout:** the daemon + all clients must ship together (no cross-version interop). The upgrade must land the on-disk `tasks.json` migration atomically so an existing board isn't misread — a test should load a pre-upgrade fixture and assert every card gets a correct `phase`.
- **Reconciler storms:** the reconciler must be debounced/bounded so a startup with many in-flight cards doesn't thrash git/tmux; reuse the existing 2s cadence + the observed-session cache.
- **Migration ordering:** `rev` (Stage 1) lands before idempotency/deadlines (Stage 6) so the client has gap detection before retries begin.
