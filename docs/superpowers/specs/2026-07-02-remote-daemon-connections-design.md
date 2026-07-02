# Remote-daemon connections (macOS app ↔ remote Linux `orchestrad`)

**Date:** 2026-07-02
**Status:** Design approved, pending implementation plan
**Related:** `notes/designs/phone-client/01-design.md`, `docs/10-roadmap.md` (#9 phone client), `docs/superpowers/specs/2026-07-01-mobile-orchestra-design.md`

## Motivation

Run the Orchestra board UI locally on a Mac while `orchestrad` — and therefore all agents,
tmux sessions, git worktrees, and repos — runs on a remote Linux machine reached over SSH. The
work box does the work; the Mac just renders the board and attaches terminals.

This is the same problem the planned phone client solves ("a client talking to a daemon over a
forwarded socket"), so the design is built once in the shared core and reused. Three topologies
collapse onto one spine:

1. **Phone → Mac daemon** — the original phone-client design.
2. **Mac app → Linux daemon** — this document's driving case.
3. **Phone → Linux daemon** — the union (phone checking on the work box), free once 1 + 2 exist.

The daemon's wire protocol (UDS + newline-delimited JSON-RPC) is **unchanged**. Every change is
either the Linux *build* of the daemon or the *client* side.

## Non-goals

- No new network surface on the daemon (no TCP/WebSocket listener). The daemon stays UDS-only;
  reachability is provided by SSH forwarding, exactly as the phone-client design intends.
- No password/interactive SSH auth handled inside the app. SSH key auth to the host is a
  documented prerequisite (Tailscale hostname or plain host).
- No iOS app in this spec. We only build the *reusable spine* (`Connection` + `Transport` +
  reconnect) in the shared core so iOS inherits it later; the macOS app is the only client built here.
- The WebSocket/tailnet transport from the phone-client doc is a future plug-in point, not built now.

## Architecture — four workstreams

### A. Linux daemon port (build/runtime only)

The daemon logic is already portable (tmux, git, worktrees, agent env injection). The blockers are
the socket layer and the SwiftPM platform gate.

- **`Sources/OrchestraCore/Control/UDSSocket.swift`** — currently `import Darwin` with no fallback,
  and uses the BSD-only `SO_NOSIGPIPE` socket option. Port:
  - `#if canImport(Glibc) import Glibc #else import Darwin #endif`.
  - Replace `SO_NOSIGPIPE` (Darwin) with `MSG_NOSIGNAL` passed on each `send()` on Linux — Linux has
    no per-socket SIGPIPE suppression, so the guard moves from socket-option to send-flag. Keep the
    Darwin `SO_NOSIGPIPE` path under `#if os(macOS)`.
- **`Package.swift`** — relax `platforms: [.macOS(.v14)]` so the `OrchestraCore`, `orchestrad`,
  `orchestra`, and `orchestra-mcp` targets build on Linux. The `App/` target is not a SwiftPM target
  and stays macOS-only (AppKit).
- **`Sources/OrchestraCore/Config.swift`** — **XDG data dir on Linux.** Today `dataDir` is
  `~/Library/Application Support/Orchestra`, `$HOME`-derived, which is bizarre on Linux. Gate it:
  - macOS: unchanged (`~/Library/Application Support/Orchestra`).
  - Linux: `$XDG_DATA_HOME/orchestra` (→ `~/.local/share/orchestra`). So the socket becomes
    `~/.local/share/orchestra/orchestrad.sock`.
  - `reposRoot`/`worktreesRoot`/`scratchRoot` stay `$HOME`-relative (already portable).
- **Lifecycle** — `DaemonLifecycle`'s launchd bootstrap (`bootstrap gui/$uid`, plist) is macOS-only
  auto-start; gate it under `#if os(macOS)`. On Linux the daemon is started by **systemd** (or
  manually) — see Deployment. The daemon's own run loop is already platform-neutral.
- **Out of scope on Linux:** `open -a Zed` (macOS convenience in `Launcher.swift`) becomes a guarded
  no-op.

### B. Transport seam + reconnect (shared core, reused by every client)

- Extract a `Transport` protocol under `ControlClient`/`ControlServer`; today the client holds a raw
  fd. Concrete impl `UDSTransport` = the current behavior. This is the swap point a future
  WebSocket transport would plug into — we build only the seam + `UDSTransport` now.
- **Reconnect + re-subscribe with backoff.** Today a dropped socket calls `close()` and the client is
  dead (`ControlClient.readLoop → close()`). New behavior: on transport close → tear down →
  exponential backoff → reconnect → re-issue the subscription → surface an observable connection
  state (`connecting | live | retrying | down`) the UI binds to. Required by both this feature (SSH
  tunnel blips) and the phone client.

### C. Connection model + settings UI (macOS app now; model reused by iOS later)

- **`Connection`** value (shared core so iOS reuses it):
  `{ name, kind: local | remote, sshTarget (user@host), identityFile?, remoteSocketPath, remoteTmuxSocket }`.
  - `local` is a built-in connection: default UDS path + local tmux, no SSH. Always present.
  - `remote` carries the SSH target and the remote socket/tmux details.
  - Persisted in the app's settings store; the app tracks the list + which connection is active.
- **Settings UI** — a Connections pane: list connections, add/edit/delete a remote, pick the active
  one, Connect/Disconnect, and a live status chip driven by B's connection-state observable.
- **Wiring change** — `App/BoardModel.swift` currently hard-wires `Config.socketPath`. It instead
  reads the active `Connection` at launch and on switch, and drives the transport accordingly.

### D. App-managed SSH tunnel + remote terminals (macOS app)

- **On Connect to a remote connection**, the app spawns one **master SSH** process with connection
  multiplexing:
  `ssh -M -S <ctrl-path> -fN -L <local.sock>:<remoteSocketPath> [-i identityFile] <sshTarget>`.
  It first removes any stale `<ctrl-path>` and `<local.sock>`, waits (bounded) for `<local.sock>` to
  appear, then points the `Transport` at that local socket. `<ctrl-path>` and `<local.sock>` live in
  the app's sandbox/temp under short paths (UDS path length cap ~104 chars).
- **Supervision** — the app owns the master ssh process. If it dies, that trips B's reconnect
  (kill → backoff → respawn master → reconnect client). Auth happens **once** on the master;
  everything else multiplexes over it (no re-auth storms).
- **Terminals** — embedded SwiftTerm's child process changes per connection:
  - `local`: `tmux -L orchestra attach -t <window>` (unchanged).
  - `remote`: `ssh -S <ctrl-path> -tt <sshTarget> tmux -L <remoteTmuxSocket> attach -t <window>`,
    riding the *same* multiplexed master — no extra forwarding, no extra auth.
- **Optional (noted, not baseline): ensure-daemon-up.** Since the app holds the SSH master, on
  Connect it *could* run `ssh -S <ctrl-path> <sshTarget> systemctl --user start orchestra` before
  forwarding, so a stopped daemon self-heals. Marked optional.

## Deployment (Linux box)

The app never starts the remote daemon; it assumes it is up and forwards its socket. Setup on the box
is one-time, then systemd keeps it running.

**The box needs, regardless of how the binary is built:** `git`, `tmux`, and the agent CLIs
(`claude`, and `codex` if used). The daemon shells out to these; the agents run here.

**Building the binary — recommended: cross-compile a static musl binary from the Mac.** A normal
Swift-on-Linux binary dynamically links the Swift runtime, so a copied binary would need those libs.
The Swift **Static Linux SDK** produces a zero-dependency static binary, and can cross-compile from
macOS — so the work box needs **no Swift toolchain** at all.

Two scripts (see `scripts/`):

- **`scripts/build-linux-daemon.sh [--arch x86_64|aarch64] [--out DIR]`** — cross-compiles
  `orchestrad`, `orchestra`, `orchestra-mcp` as static musl binaries from the Mac, plus the
  `Orchestra_OrchestraCore.bundle` resource dir (the daemon loads `embedded.conf` etc. from it at
  runtime, next to the binary). Requires the musl static SDK installed once
  (`swift sdk install …`); the script checks and guides you if it's absent. Output lands in
  `dist/linux-<arch>/`.
- **`scripts/deploy-linux-daemon.sh <user@host> [--remote-dir ~/orchestra] [--arch x86_64]`** —
  rsyncs `dist/linux-<arch>/` to the box, writes a systemd **user** unit, enables linger, and starts
  the service. Prints the daemon's socket path to paste into the app's connection settings.

**systemd user unit** (written by the deploy script):

```ini
# ~/.config/systemd/user/orchestra.service
[Unit]
Description=Orchestra daemon (orchestrad)
[Service]
ExecStart=%h/orchestra/orchestrad
Restart=always
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
[Install]
WantedBy=default.target
```

```
loginctl enable-linger $USER          # survive logout / headless work box
systemctl --user daemon-reload
systemctl --user enable --now orchestra
```

`Restart=always` replaces launchd's keep-alive; `enable-linger` makes it a true always-on daemon on a
box you are not graphically logged into.

**Fallback build path:** install the Swift toolchain on the box and `swift build -c release` there,
or build with `--static-swift-stdlib` on any Linux machine with Swift and copy the result. Documented
in the build script's `--help`.

> **Prerequisite:** the build scripts produce a *working* binary only after workstream **A** (the
> Linux socket port) is merged. Until then `swift build` for Linux fails on the Darwin-only socket
> code. The scripts are committed as ready-to-run deployment tooling; A is the first implementation
> task that makes them live.

## Testing & risks

- **A** — `swift build --swift-sdk <musl>` green from macOS; run the isolated-daemon harness
  (`scripts/orch-test.sh` equivalent) on Linux to exercise spawn/tmux/worktree end-to-end.
- **B** — unit-test reconnect/backoff with a fake `Transport` that drops mid-stream; assert
  re-subscribe fires and state transitions (`live → retrying → live`).
- **C** — round-trip a `Connection` through the settings store; assert `BoardModel` targets the
  active connection's socket.
- **D** — the master-SSH lifecycle is the riskiest piece: test tunnel-death → reconnect, and terminal
  attach over the shared control path. Clean stale `<ctrl-path>`/`<local.sock>` before spawning to
  avoid "control socket already exists" after a crash.
- **Primary risk:** SSH multiplexing edge cases (stale control socket, master dying mid-terminal).
  Mitigated by app-owned supervision + pre-spawn cleanup.

## Open questions

None blocking. The optional ensure-daemon-up behavior (D) can be decided during implementation.
