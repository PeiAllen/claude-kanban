# 2. Architecture

Orchestra is a **single coordinator with thin clients**. One background daemon owns all state; the app,
the CLI, and the MCP bridge are interchangeable front-ends that talk to it over a local socket. This
chapter walks the pieces and traces a command end to end.

```
app  ─ ControlClient ─┐
CLI  ─ ControlClient ─┼─ UDS / JSON-RPC ─→ ControlServer → CommandRegistry → OrchestraService
MCP  ─ ControlClient ─┘                    (orchestrad daemon)                ├─ TaskStore        (tasks.json)
                                                                              ├─ WorktreeManager  (git)
                                                                              ├─ SessionManager   (tmux)
                                                                              └─ AgentRegistry    (adapters)
                                              ▲
            Claude Code agent ── orchestra _report ──┘   (statusLine + hooks push live card state)
```

## The daemon (`orchestrad`)

`orchestrad` is a **launchd LaunchAgent** (`com.orchestra.daemon`, installed at
`~/Library/LaunchAgents/com.orchestra.daemon.plist`) configured `KeepAlive=true`, `RunAtLoad=true`,
`ProcessType=Background`. It runs continuously, independent of whether any app window is open, and is
restarted automatically by launchd if it ever exits. The daemon also builds and runs on **Linux**, where
a systemd **user** unit (`Restart=always` + `enable-linger`) plays launchd's keep-alive role — the
deployment target for the [Mac ↔ remote-Linux-daemon](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box)
topology; the run loop itself is platform-neutral.

On startup the daemon (`Sources/orchestrad/main.swift`):

1. **Loads config** from `~/Library/Application Support/Orchestra/config.json`.
2. **Starts the `ControlServer`** on its unix-domain socket. (The daemon renders **no** hook files — each
   adapter renders its own in `prepareToLaunch`, per launch, so a new session always reflects the current
   binary path + statusLine config. See [the hooks channel](06-clients-cli-mcp.md#the-hooks--_report-channel).)
3. **Runs recovery** asynchronously without blocking startup: sweeps orphaned scratch dirs, then
   revives sessions for cards whose tmux session died (see [Recovery](04-cards-worktrees-sessions.md#recovery-resume-and-restart)).
4. **Starts a 2-second poll loop** that reconciles liveness (a safety net that flips a card to `dead`
   if its tmux session vanished without a `SessionEnd` hook) and, alongside it, drives
   [`pollTelemetry`](04-cards-worktrees-sessions.md#the-codex-adapter) — the rollout-tail tick that
   pulls live state for `fileTail` agents (Codex) that don't push it.
5. Parks on `dispatchMain()`.

### Why a daemon, and why tmux

The daemon owns state so that **agents keep running with the app closed** and survive app restarts. Its
ground truth is deliberately *federated* rather than held in memory:

- **`tasks.json`** holds card metadata,
- **`tmux ls`** is the authority on liveness,
- **git** is the authority on the worktree.

Because liveness comes from tmux and not from in-memory bookkeeping, the daemon can crash and restart
(or the machine can reboot) and still correctly reconstruct which agents are alive and which need
reviving. tmux also gives each agent a real PTY that the app and CLI attach to directly.

## The control plane

Clients reach the daemon over a **unix-domain socket** (`~/Library/Application Support/Orchestra/
orchestrad.sock`, overridable with `$ORCHESTRA_SOCK`) speaking **newline-delimited JSON-RPC 2.0**.

- **Request:** `{jsonrpc:"2.0", id?, method, params?, source?}`. A missing `id` makes it a
  notification (no response). `source` (`app`/`cli`/`mcp`/`agent`) attributes the call in the activity
  feed.
- **Response:** `{jsonrpc:"2.0", id, result?, error?}` with error codes `-32700` (parse), `-32601`
  (method not found), `-32000` (internal).
- **Server→client notification:** `{jsonrpc:"2.0", method:"event", params:<Event>}` — pushed to any
  client that called `subscribe`.

The socket is created user-only (mode `0600`), and every accepted/connected file descriptor has
`SO_NOSIGPIPE` set (on Linux the equivalent guard is a per-`send` `MSG_NOSIGNAL` flag — see the ported
`UDSSocket`). That last detail is load-bearing: when an agent archives *its own* card, killing
the tmux session also kills the MCP client whose socket the request arrived on; the daemon's reply
write then hits a closed peer. Without `SO_NOSIGPIPE` that raised `SIGPIPE` and killed the daemon (and
launchd relaunched it, surfacing a spurious "orchestrad crashed" popup). With it, the write returns
`EPIPE`, the dead connection is dropped cleanly, and the daemon lives. See
[Troubleshooting](08-building-operations.md#troubleshooting). (Self-close has a *separate*, client-side
SIGPIPE twin: the agent's `orchestra _report` helper writing to its now-dead stdout pipe — handled with
crash-safe POSIX stdio + a process-wide `SIGPIPE` ignore; see
[the report channel](06-clients-cli-mcp.md#the-hooks--_report-channel).)

### The client transport seam and reconnect

On the client side, `ControlClient` no longer holds a raw fd directly — it owns a **`Transport`** (a
small `open`/`write`/`readLine`/`close` protocol), with `UDSTransport` the one concrete impl today (the
current AF_UNIX behavior, extracted behind the seam). A future WebSocket/tailnet transport plugs in here
without touching the client. On a dropped link the client no longer dies: it tears down, backs off
(exponential, ~250 ms → 5 s cap with jitter), reconnects with a **fresh** transport, and **re-issues the
subscription**, so a transient blip doesn't sever the event stream. It exposes an observable
**`ConnectionState`** (`connecting | live | retrying | down`) the app binds to for its status chip.

This seam is also what lets a client target a daemon that isn't on this Mac. The app can run its board
against a **remote Linux `orchestrad`** over an app-managed SSH tunnel: the wire protocol is unchanged
(the daemon grows *no* network listener), reachability is pure SSH forwarding, and the forwarded local
socket is just another path the `UDSTransport` opens. See
[Connections](07-app-ui.md#onboarding-settings-recovery-and-popovers) in the app chapter and the
[remote-daemon connections design](superpowers/specs/2026-07-02-remote-daemon-connections-design.md).

### Request flow, server-side

`ControlServer` accepts each connection and serves it on its own GCD queue. For each line it decodes an
`RPCRequest` and dispatches:

1. **Built-in methods** handled inline: `ping`, `version`, `subscribe`, `getConfig`, `setConfig`,
   `models`, `agents`, `archivedList`, `openInZed`, `openNotes`, `report`, and the app-only `diffText`/`diffStat`
   (the [code-review diff](05-command-reference.md#server-only-built-in-methods), axis 7).
2. **Registry commands** looked up in the `CommandRegistry` and run via
   `command.run(service, params, source)` against the `OrchestraService` actor.

Responses and events are written through a **non-blocking per-connection queue**; a broken write marks
the connection dead exactly once. A bounded **200-item ring buffer** holds recent events so that a
newly-subscribing client (e.g. the app reconnecting) can replay the recent activity feed under a single
lock that also serializes live fan-out — preventing duplicate or reordered delivery.

## The three clients

All three are `ControlClient`s differing only in their `source` tag and how they present results:

- **App** (`source: .app`) — connects on launch, subscribes to the event stream, and renders the board
  reactively. Terminals are *not* proxied through the daemon: SwiftTerm attaches to tmux **directly**
  over the tmux socket. The control plane carries commands, state, and events — never PTY bytes. Against
  a remote connection the same terminals `ssh` into the box's tmux over the *shared* SSH control socket,
  so no bytes flow through the JSON-RPC plane there either.
- **CLI** (`source: .cli`) — `orchestra <verb> …` parses argv, calls the matching command, prints the
  result. A few verbs (`shell`, `inspect`) fetch session handles and then `exec` `tmux attach`
  in-process. See [CLI & MCP](06-clients-cli-mcp.md).
- **MCP bridge** (`source: .mcp`) — `orchestra-mcp` is a stdio MCP server that generates **one tool per
  `CommandRegistry` command** (name = command name, description = summary, input schema = the command's
  param schema) and relays each tool call to the daemon. This is how another agent orchestrates the
  board.

Because the CLI and MCP both generate their surface from the same registry, the three clients can never
drift apart on *what* commands exist — only on presentation.

## The report channel

The fourth participant is the **agent itself**. Each adapter renders its own hook file in
`prepareToLaunch` (Claude a managed `--settings` file, Codex `$CODEX_HOME/hooks.json`) that wires the
agent's **statusLine** and **hooks** to a thin edge helper: `orchestra _report --event <kind> --agent <id>`.
The helper resolves the card's adapter, parses at the edge, and sends one typed `hook` RPC to the daemon's
adapter-free `handleHook` over the same control socket — which applies the `StatusReport` (and returns
orientation/inbox-drain content to print):

| Claude event | `_report --event` | What it updates on the card |
|--------------|-------------------|------------------------------|
| statusLine refresh | `statusline` | `ctxPct`, model id + display, session id, session name |
| `SessionStart` | `session` | session id, transcript path, session source (clear/resume/startup/compact); also injects the card's live column/mode/self-id **orientation** as `additionalContext` |
| `UserPromptSubmit` | `prompt` | the prompt text → auto-title; status → `running` |
| `Pre/PostToolUse` | `tool` | `desc` (a live blurb of what the agent is doing) |
| `Notification` / `Stop` | `notify` | `desc`; status → `waiting` |
| `SessionEnd` | `sessionend` | exit reason → may flip status to `dead` |

This is a **two-way** channel: agent → Orchestra carries live fields, and the Orchestra → agent direction
is now **realized** on several paths — the F3 Stop-drain injects the durable inbox back at turn-end via the
Stop hook, the F1 resume seed (PR C3) and the new-card spawn seed (`SpawnInput.seed`, PR D3) ride a session's
opening turn (as an argv positional, not this settings file), and the **SessionStart hook** now folds the
card's live column/mode/self-id **orientation** into the session via its `additionalContext` envelope (see
[the hooks channel](06-clients-cli-mcp.md#the-hooks--_report-channel)).

Two robustness rules matter:

- **Bounded sends.** The statusLine report is a ~50 ms synchronous call cancelled on the next tick, so
  a slow daemon never stalls the agent's status bar; hooks get a ~2 s budget. The helper always prints
  the status line to stdout *before* attempting the network send.
- **Monotonic seq guard.** Every snapshot report carries a sequence number; the daemon drops or
  coalesces stale ones so a slow `ctxPct` can't land after a fresher value.

Polling (`tmux capture-pane`) exists only as a *fallback* when the push channel is silent.

## Tracing a command end to end

Spawning a card from the CLI:

1. `orchestra spawn --prompt "…" --repo … --branch …` builds an `RPCRequest{method:"spawn", …,
   source:"cli"}` and writes it to the socket.
2. `ControlServer` decodes it, finds `spawn` in the registry, and calls
   `OrchestraService.spawn(input, source:.cli)`.
3. `OrchestraService` resolves and allowlists the repo, asks `WorktreeManager` to cut the worktree,
   asks `AgentRegistry` for the Claude adapter, builds the launch argv, and asks `SessionManager` to
   create the tmux session running that argv. It persists the new `Task` via `TaskStore` and emits a
   `taskUpserted` event plus a `spawned` activity item.
4. `ControlServer` returns the new task to the CLI and fans the events out to every subscriber — so the
   app's board updates live, even though the spawn came from the CLI.
5. The agent starts, its `SessionStart`/statusLine hooks fire, and `_report` begins pushing live state
   back onto the card.

The next chapters detail each collaborator: the [data model](03-data-model.md) the service mutates, and
the [worktree/session/adapter internals](04-cards-worktrees-sessions.md) it drives.
