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
silently deleted. The **branch is kept** after removal so the work can be recovered.

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
and moved core onto it — while the rest of the forest (the Codex adapter, the telemetry seam, live
delivery) stays design-only. An adapter declares its `id`,
`name`, `icon`, `bin`, `models()`, and its `capabilities`, and builds argv for two operations:

- **`start(ctx)`** — argv for a fresh launch,
- **`resume(ctx)`** — argv to reattach an existing session (or `nil` if unsupported),

plus `newSessionId()`, `sessionInfo(...)`, and `prepareToLaunch(ctx)` (side-effecting prep). The
`AdapterContext` it receives carries `cwd`, `repo`, `model`, `startIn`, `sessionId`, `prompt`, `name`,
the managed `hooksPath`, the card's `access`, `trustCwd` (set when Orchestra owns the cwd — see
[trust](#the-claude-code-adapter) below), and `seed` — authored system-level context (a handoff / fork /
`additionalContext` summary) whose *carrier* is frozen here (defaulted `nil`) but whose per-agent
*injection* is deferred to a later PR (see [Roadmap](10-roadmap.md#open-design-questions)). `AgentRegistry`
holds the adapters (default: `[ClaudeCodeAdapter()]`) and looks one up by id.

**Capabilities — core degrades on the descriptor, never on identity.** Every adapter must supply a frozen
**`AgentCapabilities`** value (a required protocol member with *no* default, so a new adapter can't
silently inherit Claude's shape). It is seven enum-typed flags — `sessionId ∈ {seeded, discovered}`,
`telemetry ∈ {hooksPush, fileTail, ptyScrape}`, `contextUsage ∈ {percent, tokens, none}`,
`wakeTransport ∈ {nativeReinvoke, controlChannel, sendKeys, relaunch}`, `inboxDrain ∈ {stopHook,
sessionSeed, none}`, `readOnlyEnforcement ∈ {sandboxed, toolGatedOnly, orchestraSandboxed}`, and
`authMode ∈ {subscription, apiKey}` — with **every variant spelling frozen now** (A1), including cases no
adapter exercises yet, so later PRs implement behavior behind a shape that can't drift. Claude advertises
`seeded / hooksPush / percent / nativeReinvoke / stopHook / sandboxed / subscription`. Core reads this
descriptor instead of branching on `agentId`: session-seeding switches on `capabilities.sessionId` (a
`.seeded` agent like Claude mints its id pre-launch via `newSessionId()`; a `.discovered` agent is left
unseeded to read its id back from its own output post-launch), and `isResumable` asks the adapter's
`sessionInfo` for a state path keyed on that capability rather than assuming a `~/.claude` transcript
exists. Claude's behavior is byte-for-byte unchanged by this gating.

### The Claude Code adapter

`ClaudeCodeAdapter` (`id = "claude-code"`, `bin = "claude"`) catalogs the available models — Opus 4.8,
Sonnet 4.6, Haiku 4.5, Opus 4.7 — and assembles the `claude` command line:

- **start**: `claude [--model <id>] [--permission-mode auto for plan] [read-only flags] [--session-id
  <uuid>] --settings <hooksPath> [read-only --settings] [--name <title>] [<prompt>]`. The session id is
  *seeded* at spawn so Orchestra knows it before the agent reports.
- **resume**: `claude --resume <sid> --settings <hooksPath> [--name] [--model] [read-only flags]` — no
  `--session-id`, no prompt re-handed.

**Trust mirroring & scratch trust** (`prepareToLaunch`): Claude prompts for directory trust on first
use of a path, which would block an autonomous agent. How the adapter clears that prompt depends on who
owns the cwd (the `trustCwd` flag, set when `origin == .scratch` at spawn/resume/restart):

- **Worktree & borrowed/freeform cards** (`trustCwd == false`): the adapter `mirror`s the user's
  *existing* trust decision from the source repo onto the worktree — but **never grants trust the user
  hasn't given** (it only mirrors when the repo is already trusted). A borrowed dir with no source repo
  is left alone, so Claude's own trust prompt still applies to a directory the user chose.
- **Scratch cards** (`trustCwd == true`): a scratch dir is one Orchestra just created and *owns*, so
  there's no source repo whose trust could be mirrored — `ClaudeTrust.grant(cwd)` pre-accepts the trust
  dialog outright, merging `hasTrustDialogAccepted` into `~/.claude.json` (creating the file if absent,
  preserving every other key, and bailing without writing if the file is present-but-corrupt so a
  transient read can't clobber it). No-op when already trusted.

**Transcript discovery**: Claude stores transcripts at `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`
(slug = the absolute cwd with `/` → `-`). Orchestra computes this path directly for tracked sessions,
with a newest-matching-`.jsonl` fallback used only when no id was tracked.

## The read-only barrier

A read-only card (`access = .readOnly`) is enforced by **three independent layers**, because no single
one is airtight (`Agents/ReadOnlyLaunch.swift`):

1. **Edit tools denied** — `--disallowedTools Edit Write MultiEdit NotebookEdit` removes the write tools
   from the agent's context entirely.
2. **OS sandbox write-block** — an extra `--settings` file sets `sandbox.filesystem.denyWrite` on the
   `cwd` (+ git dir), `allowUnsandboxedCommands:false` (so `dangerouslyDisableSandbox` is a no-op), and
   `failIfUnavailable:true` (fail closed if the sandbox is unavailable). This kills every *sandboxable*
   Bash write — `sed -i`, `>`, `python -c 'open(...,"w")'` — at the kernel level.
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
worktree — except `inspect` runs *without* Orchestra hooks so it stays untracked, whereas a read-only
freeform card keeps its hooks and is a tracked citizen of the board.

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
- **`resume(id, graceSeconds)`.** Revives an existing session and waits up to the grace window (default
  15 s) for the `SessionStart(resume)` callback. Success → `waiting`, `deadReason` cleared, `recovered`
  activity. Failure → `dead` with reason `resumeFailed` and a `deadDetail`. Guarded against stale
  `SessionEnd` events via a `recovering` set.
- **`restart(id)`.** Launches a fresh blank session in the *same* worktree with a new `agentSessionId`,
  rolling the old id into `priorSessionIds`. Sets `titleProvisional=true`, `status=.waiting`, clears
  `desc`. Never touches worktree contents. This is the "Start new session" button in the Recovery
  panel, and (with a future `additionalContext` seed) the basis for context-clearing handoff.
- **`reconcileLiveness()`.** The 2-second poll loop's safety net: for every non-archived, non-terminal
  card it checks whether the tmux session vanished and flips it to `dead` (`sessionVanished`) if so —
  catching deaths that didn't fire a `SessionEnd` hook. Cards mid-resume/restart are skipped.

How a dead card is presented to you — the "why" line, the preserved-work actions, and the recover/
restart/archive buttons — is covered in the [App UI chapter](07-app-ui.md#recovery-panel).
