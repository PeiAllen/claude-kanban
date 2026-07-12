# README + docs: images, GIFs, and diagrams

**Status:** approved (2026-07-10), review waived — implement directly.

## Why

The README and all eleven manual chapters contain **zero images**. The two things that actually
sell Orchestra — *you drive the board in natural language (an agent orchestrates agents over MCP)*
and *you never need the mouse* — are currently claimed in prose and proven nowhere. The
architecture is an ASCII block.

## What we add

### Images (`docs/images/`, dark, captured from a real isolated stack)

| Asset | Content | Used in |
|---|---|---|
| `orchestrate.gif` | **Hero.** A prompt in plain English into an orchestrator card → its MCP `spawn` calls land → three children appear on the board, each in its own worktree with live context-% and a growing diffstat → orchestrator `wait`s → wakes as each child concludes. | README (top), `docs/06` |
| `keyboard.gif` | `hjkl` selection, `⌃hjkl` focus, `f` link-hints, `/` search, `:` palette, `?` help. | README, `docs/07` |
| `board.png` | Full board, four columns, live cards. Static fallback for the hero. | README, `docs/07` |
| `inspector.png` | Card selected: embedded agent terminal mid-run + telemetry footer. | README, `docs/07` |
| `diff.png` | Inspector Diff view (difftastic). | `docs/07` |
| `spawn.png` | Spawn sheet: backend, repo, branch, mode. | `docs/01`, `docs/07` |
| `ios-board.png` | iPhone companion against the same daemon. | `docs/07` |

(The originally-planned `ios-card.png` — the card *detail* screen — was dropped: reaching it needs a
synthetic tap, and `simctl` can screenshot a Simulator but not drive one. `idb`, which can, isn't
installed on this box. The board shot alone carries the point, and one honest image beats two if the
second costs a new dependency.)

Everything is captured from **real agents doing real work** — no faked telemetry, no mocked
diffstats. If a capture is bad we re-run it; we do not stage it.

### Mermaid diagrams (inline, no binaries, editable by the doc-sync hook)

1. **Control plane** — app/CLI/MCP → UDS JSON-RPC → ControlServer → CommandRegistry →
   OrchestraService → TaskStore/WorktreeManager/SessionManager/AgentRegistry, plus the `_report`
   telemetry channel back. *Replaces the ASCII block* in README and `docs/02`.
2. **Card lifecycle** — persisted-phase state machine + the Plan→Impl→Review→Done column flow
   (`docs/01`, referenced from `docs/04`).
3. **Orchestration seam** — handoff/fork/fan-out/send/wait composing over F1 resume · F2 wake ·
   F3 inbox (`docs/04`). Deliberately the same story `orchestrate.gif` tells: the diagram explains
   the seam, the GIF shows it happening.
4. **Remote Linux topology** — Mac app → SSH tunnel → remote `orchestrad` (`docs/02`, `docs/08`).

## How it is captured — `scripts/docs-shots.sh`

One reproducible script, built on the existing **`iso-stack.sh` isolation contract**: an isolated
`$HOME` is the single steering lever, so the daemon socket, data dir, app prefs, and tmux server are
all throwaway. The live board is never touched and the user's screen is never foregrounded
(capture is by **window id** via `screencapture -l`, the convention `orch-ui-shot.sh` established;
filter by **PID, not owner name**, or we would grab the user's live window).

Steps:

1. Build `orchestrad`, `orchestra`, `orchestra-mcp`, the Mac app, and the iOS app off this branch.
2. Seed throwaway git repos (`api`, `web`, `infra`) with real history under the isolated root.
3. Seed the board from `scripts/fixtures/demo-board.json` — the curated Plan/Impl/Review/Done
   spread — spawned through the isolated `orchestra` CLI (`ORCHESTRA_SOCK` → isolated socket).
4. **Seed MCP into the isolated `$HOME`.** `orchestra-mcp` resolves its daemon from
   `ORCHESTRA_SOCK` (falling back to `Config.socketPath`), so the isolated `.claude.json` gets an
   `orchestra` stdio server whose command is this branch's `orchestra-mcp` and whose env pins
   `ORCHESTRA_SOCK` to the **isolated** socket. The demo orchestrator therefore has genuine
   `spawn`/`wait` tools that *physically cannot reach the live board*.
5. Run **real agents** (`USE_REAL_CLAUDE=1`, plus one Codex card) on bounded prompts.
6. Capture frames at ~2 fps by window id; drive keyboard nav with the existing `keydrive.swift`
   (`CGEvent.postToPid` — never activates the app).
7. Capture the iPhone shots via `simctl io … screenshot` against the same isolated daemon.
8. Tear the whole stack down.

`scripts/gifify.swift` assembles PNG frames into an animated GIF using macOS **ImageIO**
(`CGImageDestination` + `kUTTypeGIF`). No ffmpeg/ImageMagick/gifski — the repo stays
dependency-free, matching the core/daemon/CLI's no-dependency rule.

Re-running `scripts/docs-shots.sh` regenerates every image after a UI change.

## Keeping it from rotting

`scripts/update-docs.sh` drives the docs headlessly on every `main` commit. Its prompt gains one
rule: **never strip an existing image embed or mermaid block**; if the UI changed materially, say
so (so `scripts/docs-shots.sh` can be re-run) rather than silently deleting the shot.

## What this turned up (the expensive part)

Capturing honest screenshots meant running real agents in an isolated stack, and that exposed four
defects — three of them pre-existing and invisible, one of my own making:

1. **Claude never authenticated in ANY isolated harness.** `iso-stack.sh` asserted in its header that
   the OAuth "rides the login Keychain, so it authenticates fine under the isolated HOME." False: on
   macOS the credentials ARE in the login Keychain, but macOS resolves it through
   `$HOME/Library/Keychains` — which an isolated `$HOME` doesn't have. So `claude` was "Not logged in",
   agents sat at a login prompt, and **the board reported them `running`**. Every past
   `USE_REAL_CLAUDE=1` run was affected. Fixed by symlinking the real Keychains dir into the run's home
   (`scripts/lib/agent-auth.sh`), so isolated agents use the ordinary login — nothing minted, nothing
   to expire. A hard gate (`agent_auth_require`) now refuses to run rather than capture nothing.
   - Dead end worth recording: `~/.claude/.credentials.json` is the *Linux/Windows* store. Copying it
     between homes fails — the refresh token **rotates**, so a copy works once and then 401s for
     everyone, the original home included. I burned a login proving this.
   - The isolated `$HOME` also made macOS pop a modal *"Keychain Not Found"* dialog **per agent
     launch** (~20 of them at the user's screen). The symlink removes that too.
2. **The trust grant races.** The daemon grants per-directory trust by read-modify-writing
   `~/.claude.json`; with several cards launching at once the writes clobber each other, and a card
   whose grant is lost boots into Claude's "Do you trust this folder?" dialog instead of into work.
   Worked around here (pre-granting the deterministic worktree paths) — **the product bug is still
   open**.
3. **A missing permission parks a card forever, silently.** The orchestrator asked to run `git
   rev-parse`, which wasn't in a hand-enumerated allow-list of git subcommands, so it sat on an
   approval prompt. The board showed only "waiting" — indistinguishable from a slow agent, and it made
   several fan-out captures come out empty. Scope grants by *tool*, never by guessing verbs.
4. **PTY exhaustion (environmental, but it will bite the live board).** `kern.tty.ptmx_max` is 511 and
   the machine was holding 1,534 PTY fds — leaked by tmux servers from old e2e runs (6,388 stale socket
   files in `/private/tmp/tmux-501`). Past the cap, `tmux` cannot fork and **every** new card dies
   instantly with `fork failed: Device not configured`. The e2e harnesses appear to leak tmux servers on
   abnormal exit; worth its own fix.

Also, my own health check initially matched only the string "Not logged in", so a dead-token `401`
passed the gate as healthy and two full runs proceeded with agents that could not make a single API
call. A health check that can report a broken thing as working is worse than none; it now demands a
positive `OK`.

## Risks accepted

- **Real agents bill and take wall-clock.** Bounded prompts on toy repos keep it small. This is the
  price of honest screenshots.
- **A live fan-out capture can flake.** Re-run rather than fake.
- **A GIF may simply come out ugly.** If so, ship the stills + diagrams and say so; do not force a
  bad GIF into the README.
