# Orchestra

A local-only, single-user **native macOS app** that orchestrates many coding agents across repos
from one Kanban board. The real work lives in a background daemon (`orchestrad`, a launchd
LaunchAgent) that owns the tasks, git worktrees, and tmux agent sessions and keeps running whether or
not the app window is open. Three clients drive it over one local unix-socket / JSON-RPC control
plane: the **SwiftUI app**, the **`orchestra` CLI**, and an **MCP bridge**.

See the design vault under [`notes/designs/kanban-board/`](notes/designs/kanban-board/index.md) for the
full layered design (initial → contract → implementation → tests).

## Architecture

```
app  ─ ControlClient ─┐
CLI  ─ ControlClient ─┼─ UDS / JSON-RPC ─→ ControlServer → CommandRegistry → OrchestraService
MCP  ─ ControlClient ─┘                    (orchestrad daemon)                ├─ TaskStore
                                                                              ├─ WorktreeManager (git)
                                                                              ├─ SessionManager (tmux)
                                                                              └─ AgentRegistry (adapters)
```

- **`OrchestraCore`** — the shared library: all business logic (`OrchestraService`, `TaskStore`,
  `WorktreeManager`, `SessionManager`, `AgentRegistry`/`ClaudeCodeAdapter`, `PathResolver`,
  `CommandRegistry`, the control server/client). Fully unit-tested.
- **`orchestrad`** — the background daemon (launchd LaunchAgent).
- **`orchestra`** — the CLI client (also hosts the hidden `_report` status-channel helper).
- **`orchestra-mcp`** — the MCP stdio bridge (one tool per command).
- **`App/`** — the SwiftUI app (built separately; needs SwiftTerm + an app bundle).

## Building & testing

The core, daemon, CLI, and MCP bridge are **dependency-free** and build offline:

```sh
scripts/build.sh        # swift build
scripts/test.sh         # swift test  (adds the swift-testing search paths for CLT)
```

> **Toolchain note.** This repo targets a **Command Line Tools** (no full Xcode) environment. CLT
> ships `swift-testing` as a framework but not on the default search path, so `scripts/test.sh` adds
> the needed `-F`/`-rpath` flags. The SwiftUI app target is kept out of `Package.swift` so the
> backend stays offline-buildable; see `App/README.md` for building the app bundle (needs Xcode +
> SwiftTerm).

## Status

Backend (core + control plane + daemon + CLI + MCP) is the primary build target here. The SwiftUI
app sources match the Orchestra UI prototype; building the `.app` bundle requires Xcode.
