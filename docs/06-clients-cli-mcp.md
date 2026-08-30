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
orchestra spawn --prompt "Explore the caching angle" --repo ~/Documents/Projects/api --branch feat/cache --title "Cache probe" --seed "context from the parent card…"

orchestra set-title 9f76e0 "Cache probe — write path"   # rename a card (its session name follows at next launch)

orchestra list                       # all cards
orchestra list --col review          # one column
orchestra status <ref>               # JSON status for one card
orchestra send <ref> "use a token bucket"
orchestra inbox <ref>                # list unresolved inbox messages; includeHistory returns handed-off history
orchestra wait <ref> <ref> …          # block until one watched card concludes, print it, exit
orchestra handoff <ref> "handoff summary…"   # clean-context resume of THIS card with authored context
orchestra handoff <ref> "summary…" --model claude-fable-5   # …and RE-SEAT it onto a stronger model
orchestra trust <path>               # grant a human's write-trust for a dir (interactive only)
orchestra move <ref> --col review
orchestra exec <ref> "swift build" --timeout 300
orchestra sessions <ref> --json      # debug handles
orchestra restart <ref> [--model <id>]   # blank fresh session, same worktree (--model re-seats it)
orchestra resume <ref> [--model <id>]    # re-attempt resuming the card's session (--model re-seats it)
orchestra archive <ref>
orchestra ping
```

`orchestra shell <ref>` and `orchestra inspect <ref>` are special: they fetch the card's session
handles, close the client, and then `tmux attach` **in-process** so your terminal lands directly in the
card's shell (or a read-only agent, for `inspect`). `batch-spawn` reads a JSON array on stdin (or one
prompt per line with `--repo`/`--branch`).

`orchestra wait <ref…>` is how an orchestrator subscribes to reactive fan-out. It blocks until one watched
card concludes, prints that conclusion, and exits; the caller re-issues it for remaining cards. The command
observes only lifecycle conclusions, so it is independent of ordinary inbox submission and provider status.

Note `wait` resolves only on a **real conclusion** — a merge/archive (`.done`) or a death (`.exited`).
A read-only delegate (a reviewer or fork) that finishes its turn idles `.live(AgentState.waiting)` and does **not**
conclude on success, so its result must return via `send`, and the orchestrator `archive`s the consumed
card itself. `wait` is for cards that conclude on their own (a worktree PR card that merges), never for a
delegate's result.

`send` uses that same environment only for provenance. CLI and MCP processes with
`$ORCHESTRA_TASK_ID` attach their inherited card context, so the daemon snapshots that card's title and id into the
queued message; an external CLI or MCP process without it sends as **Human**. The source is edge-owned:
the CLI creates its `senderCard` context only from the environment, and the MCP bridge discards any raw
caller value before attaching the same context. It is attribution metadata on the local control plane, not a
signed authorization identity or a delivery guarantee.

`--model <id>` on `restart` / `handoff` / `resume` **re-seats the card onto another model in place** — the
[`--model` re-seat](05-command-reference.md#the---model-re-seat). It is declared on those three schemas in
the [command catalog](05-command-reference.md#registry-commands), so it is a real MCP tool argument too (the
tool schemas are generated from the catalog — see [tool generation](#the-mcp-bridge)), not a CLI-only flag;
the CLI side is the hand-wired half, and it rejects `--model` written with **no value** rather than let the
flag parse as a boolean and silently relaunch on the old model. The id must belong to the card's **own**
agent's catalog; anything else is refused with `invalidParams` before the card is touched.

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

![An orchestrator agent spawning three children, then waiting on them](images/orchestrate.gif)

<sub>A real run, sped up ~4×.</sub>

This is what that buys, and it is the whole argument for the bridge: the card above was told, in plain
English, to *"split the rate-limiting work into three PRs and fan them out."* It calls `spawn` three
times and then `wait`s — and the board fills itself in. Whether it reaches those commands as MCP tools
or through the `orchestra` CLI is an implementation detail of the agent's toolset: both doors open onto
the one `CommandRegistry`, which is exactly why an agent driving Orchestra is indistinguishable from you
driving it. `wait` observes conclusions, while ordinary messages use the card's independent native inbox
sender.

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

Cards launched by Orchestra configure this automatically. Claude receives an inline `--mcp-config`
entry and Codex receives a per-launch profile entry, both named `orchestra`; the local entry takes
precedence over a same-name global entry for that launch, while unrelated user MCP servers remain
available. Claude's generated config is deliberately non-strict so the card keeps its normal global
servers too.

For an MCP host outside an Orchestra-launched card, register it manually as a stdio server running the
`orchestra-mcp` binary; it logs readiness (and the socket path) to stderr.

### Optional global installation

The Settings → Agent → **Install Orchestra MCP and CLI globally** toggle is off by default. “Globally”
means every card for this user, while installation remains user-scoped: on the next card launch it adds
missing `orchestra` entries to `~/.claude.json` and `~/.codex/config.toml`, creates
`~/.local/bin/orchestra` and `~/.local/bin/orchestra-mcp` symlinks to the resolved Orchestra binaries,
and appends an idempotent PATH block to the user's shell profile. The daemon-launched agent environment
already includes `~/.local/bin`, so cards started by the app see the commands even before a new shell
loads the profile.

Existing same-name MCP entries, files, or symlinks are left untouched, and disabling the toggle does not
remove anything it previously installed. Global MCP config uses the resolved bundled `orchestra-mcp`
path directly, so a conflicting user-local shim cannot change which bridge a configured host launches.
The app and Linux deployment bundle ship `orchestrad`, `orchestra`, and `orchestra-mcp` together, so
normal card setup does not require a separate CLI or MCP download.

The CLI and MCP bridge are clients of `orchestrad`; `orchestra-mcp` does not start or host the daemon.
Local onboarding and the LaunchAgent keep the macOS daemon running, while remote Linux deployment uses
the service manager for the daemon lifecycle.

> Today, the server-only built-ins (`models`, `agents`, `archivedList`, `openInZed`, `getConfig`, …) are *not*
> in the registry, so they aren't exposed as MCP tools yet. Folding the CLI and these built-ins onto the
> registry as the single source is [Roadmap axis 3](10-roadmap.md)'s foundational refactor.

## The hooks / `_report` channel

Hooks are a **first-class, core-owned channel** for metadata, orientation, and Claude's strictly correlated
runtime observations. Codex does not use hooks for runtime state — its app-server observer is the sole
Codex runtime-status and provider-human authority.
Core owns the protocol (`HookEvent` + `HookResponse`) and the generic status reducer; each adapter owns
provider interpretation (`parse` metadata, Claude hook-observation projection where applicable,
`agentSignals`, response encoding, and hook rendering). The edge forwards only the small raw subset the
adapter selected, so Core can fence it against the current card epoch/session before normalization.

**Rendering (per launch, by the adapter).** Each adapter supplies its hook configuration from a bundled
template — `claude-hooks.json` becomes Claude's managed `--settings` file, while `codex-hooks.json` is
substituted in memory and written as `hooks.<event>` values into a per-launch Codex profile file
(`$CODEX_HOME/orch-<hash>.config.toml`, selected with `-p`; see
[the Codex adapter](04-cards-worktrees-sessions.md#the-codex-adapter) for why a file rather than inline
`-c` — the argv would exceed tmux's command-length cap). The daemon renders nothing, and Codex never
receives an Orchestra-owned `CODEX_HOME` or a global `hooks.json` write.
`__ORCHESTRA_BIN__` is replaced with the live `orchestra` path and `__AGENT_ID__` with the card's agent id;
the command carries a baked `--agent <id>` so the client can resolve its adapter with no env var:

```jsonc
{
  "statusLine": { "type": "command", "command": "<orchestra> _report --event statusline --agent claude-code" },
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "command": "<orchestra> _report --event session --agent claude-code"      }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "command": "<orchestra> _report --event prompt --agent claude-code"       }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [{ "command": "<orchestra> _report --event pretool --agent claude-code"  }] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [{ "command": "<orchestra> _report --event posttool --agent claude-code" }] }],
    "Notification":      [{ "hooks": [{ "command": "<orchestra> _report --event notification --agent claude-code" }] }],
    "Stop":              [{ "hooks": [{ "command": "<orchestra> _report --event stop --agent claude-code"         }] }],
    "SessionEnd":        [{ "hooks": [{ "command": "<orchestra> _report --event sessionend --agent claude-code"   }] }]
  }
}
```

The `--event` strings **are** the `HookEvent` raw values (Core), so the template, client, and daemon
share one vocabulary. `Notification`/`Stop` and `PreToolUse`/`PostToolUse` each get a distinct event —
so nothing downstream ever sniffs the raw `hook_event_name`. Codex wires SessionStart and Stop for its
native hook lifecycle, while its app-server connection remains the sole source of turn status and provider
human need. A card that also needs per-card settings (read-only enforcement — see [the
read-only barrier](04-cards-worktrees-sessions.md#the-read-only-barrier)) does **not** get a second
`--settings`; `SettingsComposer` deep-merges those overlays *onto* this base into one file (Claude applies
multiple `--settings` last-file-wins, so a second file would silently drop the statusLine + hooks).

**`orchestra _report`** (in `ReportHelper.swift`) is the thin edge client these callbacks invoke:

1. **Render + print the status line first** — unbuffered — so a slow daemon never stalls the status bar.
2. **Resolve this card's adapter** from `--agent` (`AgentRegistry`), guarding on `$ORCHESTRA_TASK_ID`
   (set by `SessionManager` at launch) and a known `HookEvent` — a plain `claude` you run does nothing.
3. **Split at the edge:** `adapter.parse` extracts metadata/lifecycle into `StatusReport`,
   `adapter.sessionSource` extracts SessionStart source, and Claude's `hookObservationPayload` selects the
   bounded raw fields needed for current-session status normalization. Codex hook payloads do not produce
   runtime state. Large tool bodies die here.
4. **Send one typed `hook` RPC** — `{ref, event, report?, source?, observationPayload?}` — under a tight
   budget (~50 ms statusline fire-and-forget, ~2 s otherwise). The daemon applies metadata and asks the
   card's adapter for normalized `AgentSignal`s after epoch/session fencing. A `session` response may
   carry the live orientation ([`SessionBrief`](04-cards-worktrees-sessions.md)); Stop has no delivery
   response.
5. **Encode orientation to stdout:** if the daemon returns a `HookResponse`, `adapter.encode` wraps the
   SessionStart orientation in the provider's native `additionalContext` envelope and prints it.

This single `hook` RPC replaced the former `report`/`drain`/`sessionBrief` methods. Because the daemon
resolves the card's adapter from the persisted `agentId`, there is no agent identity on the wire beyond
the shared `HookEvent`, and no `if agentId` anywhere in the dispatch.

**Crash-safe, best-effort stdio.** `_report` is contractually best-effort — it always exits 0 and never
fails the agent. Its statusLine + hook output goes to a stdout pipe that Claude captures, and that pipe
breaks the instant a **self-close** (`archive`) kills the card's tmux session — often right while the
helper is mid-write. `FileHandle`'s read/write would raise an *uncatchable* ObjC
`NSFileHandleOperationException` on the resulting `EPIPE` (Swift `try?` can't catch it → `terminate()` →
`SIGABRT` → an "orchestra quit unexpectedly" popup), and a raw `write(2)` would instead die with signal 13.
So `ReportHelper` does its own POSIX `read`/`write` that swallow `EPIPE`/any error, paired with a
process-wide `signal(SIGPIPE, SIG_IGN)` in `main.swift` (set before any I/O, so it also protects e.g.
`orchestra list | head`). This is the client-side twin of the daemon's per-socket `SO_NOSIGPIPE` fix
([architecture](02-architecture.md#the-control-plane), [Troubleshooting](08-building-operations.md#troubleshooting)) —
a *separate* bug: that one is the daemon's reply write to a dead peer, this one is the helper's own stdout.
Regression test: `Tests/IntegrationTests/ReportHelperPipeTests.swift`.

**Codex gets a parity SessionStart hook.** Codex receives the rendered SessionStart handler as one of the
`hooks.<event>` entries in its per-launch profile file, so its stdout `additionalContext` is folded into the
session and the same orientation (step 5) reaches a Codex card too. This adapter's hook contribution lives in
the profile file that `prepareToLaunch` writes; it has no Codex-specific *global* persistent setup step.
Codex's `parse` also binds the provider session id from this hook before returning the same orientation
brief Claude receives.

Both conversions remain adapter-owned. `parse(_:)` handles metadata from hooks or the Codex rollout
tail; `agentSignals(from:context:)` maps current Claude hook payloads and OTLP spans, or Codex app-server
messages, into the provider-neutral live state. Codex rollout and hook data never supplies that state. The
CLI never interprets provider fields itself.

On the daemon side, `OrchestraService+Report.swift` merges the report's event half (for example
`SessionEnd`→dead, session-id rollover, and prompt auto-title) and seq-gated metadata snapshot (`ctxPct`,
`desc`, model, session name). `OrchestraService+AgentObservation.swift` independently applies normalized
signals through `AgentStateReducer` and atomically writes the resulting `Phase.live(AgentState)`.

### Native inbox submission

Normal inbox submission does not travel through `_report`, `Stop`, or a handoff seed. `send` first writes a
local queued row. While a live provider connection exists, the card runtime gives the provider sender an
ephemeral native handle: Claude uses hook-supplied endpoint/token metadata, and Codex opens a separate
app-server peer for `turn/start`. A successful native request changes the row to `handedOff`, meaning only
that the harness accepted it. Sender attempts are bounded and may retry briefly across a reconnect, but
they do not create status, wait for a display state, wake/relaunch a session, or claim model-level receipt.
