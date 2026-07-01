# 6. CLI & MCP

The [command reference](05-command-reference.md) lists *what* commands exist; this chapter covers the
two non-GUI clients that expose them — the `orchestra` CLI and the `orchestra-mcp` bridge — plus the
daemon lifecycle commands and the hooks / `_report` channel.

## The `orchestra` CLI

`orchestra <verb> [args]` connects to the daemon socket (`$ORCHESTRA_SOCK` overrides the default),
calls the matching command, and prints the result. A few verbs are handled before any daemon contact:
`help`/`-h`, `version`, `_report` (the hidden hooks helper), and `daemon` (lifecycle).

### Flags

The parser accepts `--key value`, bare `--flag` booleans, positionals, and `--` to end flag parsing.
Common usage:

```sh
# spawn a worktree card
orchestra spawn --prompt "Add rate limiting" --repo ~/Documents/Projects/api --branch feat/ratelimit --col impl

# spawn a freeform (borrowed) card in an existing dir, read-only
orchestra spawn --prompt "Audit the auth flow" --cwd ~/Documents/Projects/api --read-only

# spawn a throwaway scratch card
orchestra spawn --prompt "Prototype a CSV parser" --scratch

# fork: a new card seeded with the parent's slice (PR D3)
orchestra spawn --prompt "Explore the caching angle" --repo ~/Documents/Projects/api --branch feat/cache --seed "context from the parent card…"

orchestra list                       # all cards
orchestra list --col review          # one column
orchestra status <ref>               # JSON status for one card
orchestra send <ref> "use a token bucket"
orchestra inbox <ref>                # list a card's queued inbox messages (also inbox-edit/-remove/-reorder)
orchestra wait <ref> <ref> …          # block until one watched card concludes, print it, exit
orchestra handoff <ref> "handoff summary…"   # clean-context resume of THIS card, seeded (F1)
orchestra trust <path>               # grant a human's write-trust for a dir (interactive only)
orchestra move <ref> --col review
orchestra exec <ref> "swift build" --timeout 300
orchestra sessions <ref> --json      # debug handles
orchestra restart <ref>              # blank fresh session, same worktree
orchestra resume <ref>               # re-attempt claude --resume
orchestra archive <ref>
orchestra ping
```

`orchestra shell <ref>` and `orchestra inspect <ref>` are special: they fetch the card's session
handles, close the client, and then `tmux attach` **in-process** so your terminal lands directly in the
card's shell (or a read-only agent, for `inspect`). `batch-spawn` reads a JSON array on stdin (or one
prompt per line with `--repo`/`--branch`).

`orchestra wait <ref…>` is how an orchestrator agent drives the reactive fan-out. It blocks until one of
the watched cards concludes, prints that conclusion, and **exits** — which, for a card launched by
Orchestra, is the wake: Claude's `nativeReinvoke` `wakeTransport` re-invokes the caller in-session when its
background `orchestra wait` process ends, so the orchestrator wakes, reads the durable inbox, and re-issues
`orchestra wait` on the cards that remain. It reads `$ORCHESTRA_TASK_ID` (set at launch) as the `watcher`,
so conclusions coalesce into the caller's own inbox. (See
[merge-watch / `wait`](05-command-reference.md#notes-on-key-commands) and
[chapter 9](09-design-decisions.md#shipped-feature-history).)

`orchestra trust <path>` is the **interactive-only** grant surface (PR T2). Because trust is a human
decision, the verb gates on `isatty(STDIN)`: at a real terminal it prints a `[y/N]` confirmation and,
only on `y`/`yes`, calls the daemon `trust` command; run non-interactively (a pipe, a script, another
agent's shell) it **refuses** — printing actionable help that names the path and points back at running
`orchestra trust` in a terminal, then exits non-zero. There is deliberately **no `--trust` flag**: a
directory can only be trusted by a human answering, never by a switch an agent could pass. (See
[the `trust` command](05-command-reference.md#notes-on-key-commands).)

### Daemon lifecycle

`orchestra daemon …` manages the LaunchAgent:

- install/start the `com.orchestra.daemon` LaunchAgent (renders the plist to
  `~/Library/LaunchAgents/com.orchestra.daemon.plist`, `KeepAlive=true`, `RunAtLoad=true`),
- stop/status it.

The app does the same thing from its onboarding screen ("Install & Start") and the offline banner.

## The MCP bridge

`orchestra-mcp` is a **stdio MCP server** built on the official `modelcontextprotocol/swift-sdk`. It
exists so that another agent — typically a Claude Code session — can orchestrate the Orchestra board as
a set of tools.

- **Tool generation.** On `ListTools`, it maps every `CommandRegistry` command to an MCP `Tool` whose
  name is the command name, description is the command summary, and input schema is the command's own
  JSON-Schema params. There is no hand-maintained tool list — add a command to the registry and the MCP
  surface grows with it.
- **Relay.** On `CallTool`, it opens a `ControlClient(source:.mcp)` to the daemon socket
  (`$ORCHESTRA_SOCK` or default), forwards the call, and returns the daemon's result as text content.
  RPC errors come back as MCP `isError` results.
- **The `trust` tool is the one human-gated special-case** (PR T2). Before relaying it, the bridge calls
  `server.requestElicitation(...)` back over its **persistent MCP session** to the agent's *own* client
  — so a **human** at that client approves or declines the write-trust request. It forwards the `trust`
  call to the daemon **only on `.accept`**; a decline/cancel returns an `isError` without ever recording.
  `requestElicitation` throws if the client never advertised the MCP `elicitation` capability — and both
  v1 targets (Claude Code, Codex) do, so there is deliberately **no fallback** (the agent can only
  *trigger* the grant; a human answers). This is the MCP surface of the [`trust`
  command](05-command-reference.md#notes-on-key-commands); every other tool is a plain relay.

Register it with your MCP host (e.g. Claude Code) as a stdio server running the `orchestra-mcp` binary;
it logs readiness (and the socket path) to stderr.

> Today, the server-only built-ins (`models`, `agents`, `archivedList`, `openInZed`, `getConfig`, …) are *not*
> in the registry, so they aren't exposed as MCP tools yet. Folding the CLI and these built-ins onto the
> registry as the single source is [Roadmap axis 3](10-roadmap.md)'s foundational refactor.

## The hooks / `_report` channel

When the daemon launches a Claude Code agent it hands it a **managed `--settings` file** rendered by
`HooksRenderer` from the `claude-hooks.json` resource, with `__ORCHESTRA_BIN__` substituted for the
real `orchestra` path. That file wires Claude's statusLine and hooks to `orchestra _report --event
<kind>`:

```jsonc
{
  "statusLine": { "type": "command", "command": "<orchestra> _report --event statusline" },
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "command": "<orchestra> _report --event session"     }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "command": "<orchestra> _report --event prompt"      }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [{ "command": "<orchestra> _report --event tool" }] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [{ "command": "<orchestra> _report --event tool" }] }],
    "Notification":      [{ "hooks": [{ "command": "<orchestra> _report --event notify"      }] }],
    "Stop":              [{ "hooks": [{ "command": "<orchestra> _report --event notify"      }] }],
    "SessionEnd":        [{ "hooks": [{ "command": "<orchestra> _report --event sessionend"  }] }]
  }
}
```

`orchestra _report` (in `ReportHelper.swift`) is the hidden helper these callbacks invoke. Its
behavior, in order:

1. **Render and print the status line first** — to unbuffered stdout — so a slow daemon never stalls
   Claude's status bar.
2. **Guard on `$ORCHESTRA_TASK_ID`** (set by `SessionManager` at launch) — only Orchestra-spawned
   agents report; a plain `claude` you run yourself does nothing.
3. **Parse the event** into a `StatusReport` (see [Data model](03-data-model.md#the-report-types)) and
   send it to the daemon's `report` method under a tight time budget (~50 ms for statusline, ~2 s for
   hooks), closing the connection on budget/ack so a "budget trip" never blocks the agent.
4. **On the Stop hook, drain the inbox (F3).** The `Stop` and `Notification` events share the same
   `_report --event notify` command, distinguished at runtime by the stdin `hook_event_name`. When it is
   `"Stop"`, `_report` additionally calls the daemon's [`drain` RPC](05-command-reference.md#server-only-built-in-methods)
   for the card and, if the card's [durable inbox](03-data-model.md#the-inbox-store-f3) has anything
   pending, prints a `{"decision":"block","reason":<payload>}` object to stdout — the documented Claude
   Stop-hook continuation channel, which hands the queued messages back to the model so it keeps working
   instead of stopping. The payload is the drained messages joined and capped at 10 000 characters
   (`StopDrain`). This step is purely **additive** — the notify→`waiting` report of step 3 is unchanged,
   and non-`Stop` events never reach it. A per-card **consecutive-inject loop guard** in the daemon
   (`OrchestraService.drainForStop`, cap 25, reset by a genuine `UserPromptSubmit`) breaks a runaway
   Stop→inject→Stop cycle by leaving messages queued once the cap is hit. (`notes/plans/2026-07-01-c1-inbox-stopdrain.md`.)

The raw→`StatusReport` conversion is **not** `ReportHelper`'s own. This `_report` process *is* the Claude
**`hooksPush` transport**, so it wraps the event as a `RawTelemetry.hooksPush(kind:payload:)` and hands it
to the adapter's `ClaudeCodeAdapter.parse(_:)` — the parse is **agent-dependent**, so it belongs to the
adapter, not the CLI. This is the transport/parse boundary PR A2 established (relocating the former
`ReportHelper.map`/`toolDesc` verbatim into the adapter, keeping Claude telemetry byte-identical). The
daemon-side **rollout-tail** transport for another agent — Codex — has since landed (PR B2): its
`RolloutTailer` + `OrchestraService.pollTelemetry()` call the *same* `adapter.parse` seam from a file tail
instead of a push endpoint (see [the Codex adapter](04-cards-worktrees-sessions.md#the-codex-adapter)). See
[the adapter's telemetry parse](04-cards-worktrees-sessions.md#the-claude-code-adapter) and the
[agent-provider interface](../notes/designs/agent-provider-interface/02-contract.md) contract.

On the daemon side, `OrchestraService+Report.swift` merges the report's **event half** (applied
unconditionally and ordered — e.g. `SessionEnd`→`dead`, session-id rollover into `priorSessionIds`,
prompt text → auto-title + `running`) and its seq-gated **snapshot half** (`ctxPct`, `desc`, model,
status), emitting a `taskUpserted` event and an activity entry only when something actually changed.

This same channel now carries the **first realized Orchestra → agent direction**: the F3 Stop-drain
(step 4 above) injects the durable inbox back into the agent at its turn-end. The **F1 resume seed** (PR C3)
adds a second injection path — an authored handoff/fork context folded with that same inbox, delivered as a
resumed session's opening positional turn (argv, not this settings channel) — now callable end-to-end via
the [`handoff` command](05-command-reference.md#notes-on-key-commands) (PR D1). The **new-card** counterpart
has since landed too (PR D3): a defaulted `SpawnInput.seed` on `spawn`/`batch-spawn` folds authored context
ahead of a fresh card's prompt, completing the handoff/fork/fan-out delivery the
[roadmap](10-roadmap.md) called for.
