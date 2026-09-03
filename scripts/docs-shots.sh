#!/usr/bin/env bash
#
# docs-shots.sh — regenerate every image in docs/images/ (the README hero GIF, the keyboard-nav
# GIF, the board/inspector/diff stills, and the iPhone shots) from a REAL, ISOLATED Orchestra stack
# running THIS branch.
#
# Nothing here is mocked: the cards are genuine worktrees, the agents genuinely run, and the
# context-% / activity / diffstat on the board are the real telemetry those agents produced. If a
# capture looks wrong, re-run it — do not fake it.
#
# ISOLATION CONTRACT (same one scripts/iso-stack.sh relies on — read that script's header):
#   • An isolated $HOME is the only steering lever: it derives the daemon's socket + data dir AND
#     the Mac app's ControlClient path, so the isolated app and isolated daemon find each other and
#     never the live pair. orchestrad is spawned DIRECTLY (never launchctl — that label is global).
#   • ORCHESTRA_TMUX_SOCKET isolates the tmux server, so agent panes never land on -L orchestra.
#   • The MCP bridge the demo orchestrator uses is seeded into the isolated $HOME with
#     ORCHESTRA_SOCK pinned to the ISOLATED socket — so when the orchestrator agent calls
#     `spawn`, it physically cannot reach the live board.
#   • Every capture is taken BY WINDOW ID (screencapture -l), filtered by the spawned app's PID and
#     not its owner name — an owner-name match would grab the user's LIVE Orchestra window. The
#     user's screen is never foregrounded and the app is never activated (keys go via
#     CGEvent.postToPid).
#
# REAL AGENTS RUN HERE AND THEY BILL. The prompts in scripts/fixtures/demo-board.json are small and
# bounded on purpose.
#
# AUTH: on macOS `claude` keeps its credentials in the login KEYCHAIN, which macOS resolves through
# $HOME/Library/Keychains — and this harness throws $HOME away. So an isolated home is simply "Not
# logged in": every Claude card sits at a login prompt forever while the board reports it "running"
# (a silent failure that produced entire sets of empty screenshots), and macOS pops a modal "Keychain
# Not Found" dialog per agent launch. agent_auth_seed symlinks the REAL Keychains dir into the run's
# home, so agents authenticate with your ordinary login — nothing minted, nothing to expire. Codex
# authenticates from ~/.codex/auth.json, which is bridged in. See scripts/lib/agent-auth.sh.
#
# Run UNSANDBOXED: builds app bundles (xcodebuild needs ~/Library), binds a UDS socket, writes a
# data dir, launches a GUI app, drives simctl, and needs Screen Recording + Accessibility.
#
# Usage:
#   scripts/docs-shots.sh [--no-build] [--keep] [phase ...]
#     phases: stills | orchestrate | keyboard | ios     (default: all four)
#     --keep   leave the isolated stack up afterwards (inspect it, then: scripts/docs-shots.sh down)
#   scripts/docs-shots.sh down      tear down a --keep'd stack
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Real-agent auth for isolated runs (the durable dev home + seeding). See scripts/lib/agent-auth.sh.
source "$REPO_ROOT/scripts/lib/agent-auth.sh"
source "$REPO_ROOT/scripts/lib/wm-float.sh"

# Canonical (symlink-resolved) root: /tmp → /private/tmp. Claude/Codex canonicalize their cwd before
# the trust + resume lookup and the daemon keys trust on the STORED cwd, so a "/tmp/…" root would
# store /tmp/… while the agent looks up /private/tmp/… → spurious trust prompt + broken resume.
ROOT="$(cd /tmp && pwd -P)/orch-docs"
ISO_HOME="$ROOT/home"
DATA="$ISO_HOME/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
LIVE_SOCK="$HOME/Library/Application Support/Orchestra/orchestrad.sock"
ISO_TMUX_SOCKET="orch-docs"
DD="$REPO_ROOT/.scratch/docs-shots-dd"
FRAMES="$REPO_ROOT/.scratch/docs-frames"
OUT="$REPO_ROOT/docs/images"
STATE="$ROOT/stack.state"
FIXTURE="$REPO_ROOT/scripts/fixtures/demo-board.json"
IOS_BUNDLE="com.orchestra.ios"

DAEMON="$REPO_ROOT/.build/debug/orchestrad"
CLI="$REPO_ROOT/.build/debug/orchestra"
MCP_BIN="$REPO_ROOT/.build/debug/orchestra-mcp"

# GIF encoding knobs. 2 fps reads as motion without ballooning the file; 1100px is ~the widest a
# GitHub README renders a GIF, so anything larger is bytes nobody sees.
FPS_DELAY=0.5
GIF_WIDTH=800
MAX_FRAMES=80      # cap the GIF: a full-length fan-out at 2fps is ~600 frames / ~18MB otherwise

fail() { echo "  ✗ $*" >&2; exit 1; }
note() { echo "  · $*"; }

# `orchestra` against the ISOLATED daemon. ORCHESTRA_SOCK is the steering lever the CLI reads
# (Sources/orchestra/main.swift) — without it the CLI would hit the LIVE socket.
# ORCHESTRA_TASK_ID cleared too: running this script FROM an Orchestra card (as any agent card
# doing docs work would) exports the CALLER's own real card id into this shell. Left alone, `oc
# send` tags every message with that id as sender — the isolated daemon has never heard of it, the
# sender lookup fails, and `send` silently no-ops (the orchestrate phase then sleeps out its whole
# FANOUT_WAIT for a nudge the orchestrator never received). Empty, not unset: the CLI treats an
# empty ORCHESTRA_TASK_ID the same as absent (`!id.isEmpty` guards, Sources/orchestra/CLIRunner.swift).
oc() { HOME="$ISO_HOME" ORCHESTRA_SOCK="$SOCK" ORCHESTRA_TASK_ID="" "$CLI" "$@"; }
kv() { grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }

# ---------------------------------------------------------------- teardown
cmd_down() {
  echo "▶ tearing down the isolated docs stack…"
  if [[ -f "$STATE" ]]; then
    local a d u; a="$(kv APP_PID)"; d="$(kv DAEMON_PID)"; u="$(kv IOS_UDID)"
    [[ -n "$a" ]] && kill "$a" 2>/dev/null && note "killed Mac app ($a)" || true
    [[ -n "$u" ]] && xcrun simctl terminate "$u" "$IOS_BUNDLE" 2>/dev/null && note "terminated iPhone app" || true
    [[ -n "$d" ]] && kill "$d" 2>/dev/null && note "killed daemon ($d)" || true
  fi
  pkill -f "$DD/Build/Products/Debug/Orchestra.app" 2>/dev/null || true
  tmux -L "$ISO_TMUX_SOCKET" kill-server 2>/dev/null || true
  # Codex's `app-server` is a persistent per-card backend, deliberately built to survive its tmux
  # pane closing (so a client can reconnect) — killing tmux above does NOT reach it. The daemon's
  # normal per-card archive flow terminates it explicitly; a blanket teardown like this one bypasses
  # that flow, so it leaked on every prior run (found via `lsof` after a stuck retry: four orphaned
  # `codex app-server` processes going back to this branch's very first capture attempt). Kill by
  # the isolated $DATA path in its argv — unique to this throwaway run, never a live path.
  pkill -f "codex app-server --listen unix://$DATA/" 2>/dev/null || true
  rm -rf "$ROOT"
  echo "  ✓ down. Live daemon/app untouched."
}
[[ "${1:-}" == "down" ]] && { cmd_down; exit 0; }

KEEP=0
BUILD=1
QUICK=0
PHASES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --keep)     KEEP=1; shift ;;
    --quick)    QUICK=1; shift ;;   # short waits — for iterating on the harness, NOT for real shots
    stills|orchestrate|keyboard|ios) PHASES+=("$1"); shift ;;
    *) fail "unknown arg: $1 (usage: docs-shots.sh [--no-build] [--keep] [stills|orchestrate|keyboard|ios]...)" ;;
  esac
done
# bash 3.2 (what macOS ships): ${#arr[@]} on an empty array trips `set -u`, so guard the expansion.
[[ -z "${PHASES[*]+set}" ]] && PHASES=(stills orchestrate keyboard ios)
has_phase() { local p; for p in "${PHASES[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }

cleanup() { [[ "$KEEP" == 1 ]] || cmd_down >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$OUT" "$FRAMES"

# `screencapture -l` cannot image a window while the display is asleep — a run that starts before the
# Mac idles out silently fails EVERY shot ("could not create image from window"). Hold the display
# awake for exactly this script's lifetime (-w $$ exits with us). This inhibits sleep; it does not
# touch the foreground, activate anything, or take over the user's screen.
caffeinate -d -i -u -w $$ &
CAFFEINATE_PID=$!

# ---------------------------------------------------------------- 1. build
# Every build goes through the machine-wide build mutex (scripts/lib/with-lock.sh) — a bare `swift
# build`/`xcodebuild` here re-creates the contention problem for every other card on the machine
# (see docs/08-building-operations.md). `-skipPackagePluginValidation`: a fresh $DD has no recorded
# trust for SwiftTerm's build-tool plugin, and there is no one here to click "Trust & Enable" —
# without it the FIRST build in a fresh $DD fails on "Validate plug-in SwiftTermBuildInfoPlugin"
# (the same flag scripts/iso-stack.sh and scripts/orch-ui-shot.sh already carry for this reason).
if [[ "$BUILD" == 1 ]]; then
  echo "▶ building daemon + CLI + MCP bridge (debug)…"
  scripts/lib/with-lock.sh build -- swift build --package-path "$REPO_ROOT" --product orchestrad
  scripts/lib/with-lock.sh build -- swift build --package-path "$REPO_ROOT" --product orchestra
  scripts/lib/with-lock.sh build -- swift build --package-path "$REPO_ROOT" --product orchestra-mcp
  echo "▶ building Mac app (Debug)…"
  xcodegen generate --spec App/project.yml --project App >/dev/null
  scripts/lib/with-lock.sh build -- xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" -skipPackagePluginValidation build >/dev/null
  if has_phase ios; then
    echo "▶ building iPhone app (Debug)…"
    xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
    scripts/lib/with-lock.sh build -- xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build >/dev/null
  fi
fi
for b in "$DAEMON" "$CLI" "$MCP_BIN"; do [[ -x "$b" ]] || fail "not built: $b (drop --no-build)"; done
APP="$(/usr/bin/find "$DD/Build/Products/Debug" -maxdepth 1 -name 'Orchestra.app' 2>/dev/null | head -1)"
BIN="$APP/Contents/MacOS/Orchestra"
[[ -x "$BIN" ]] || fail "Mac app not built at $DD (drop --no-build)"

# ---------------------------------------------------------------- 2. seed the isolated world
[[ "$SOCK" == "$LIVE_SOCK" ]] && fail "isolated socket == live socket — aborting"
echo "▶ seeding isolated \$HOME at $ISO_HOME"
rm -rf "$ROOT"; mkdir -p "$DATA"

# Demo repos: fictional, small, with real git history (so worktrees + diffs are genuine).
python3 - "$FIXTURE" "$ROOT" <<'PY'
import json, os, subprocess, sys
fixture, root = sys.argv[1], sys.argv[2]
spec = json.load(open(fixture))
for name, r in spec["repos"].items():
    d = os.path.join(root, name)
    for rel, content in r["files"].items():
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)
    run = lambda *a: subprocess.run(a, cwd=d, check=True,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run("git", "init", "-q", "-b", "main")
    run("git", "config", "user.email", "demo@orchestra.local")
    run("git", "config", "user.name", "Orchestra Demo")
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "initial commit")
    print(f"  · repo {name}/ ({len(r['files'])} files)")
PY

# Daemon config: allowlist the demo root only.
python3 - "$DATA/config.json" "$ROOT" <<'PY'
import json, sys
path, root = sys.argv[1:3]
json.dump({"reposRoot": root, "worktreesRoot": root + "/worktrees",
           "defaultAgentId": "claude-code", "allowlist": [root],
           "maxConcurrentRevivals": 4, "revivalGraceSeconds": 15,
           "statusLineMode": "orchestraDefault"}, open(path, "w"), indent=2)
PY
printf '[]\n' > "$DATA/tasks.json"

# Claude, inside the isolated $HOME:
#   • onboarding pre-completed — a fresh $HOME would otherwise stall the first agent on the
#     theme picker (the daemon writes per-directory trust itself, but not the global onboarding).
#   • the `orchestra` MCP server, with ORCHESTRA_SOCK pinned to the ISOLATED socket. This is what
#     makes the hero GIF honest AND safe: the demo orchestrator gets real spawn/wait tools that
#     resolve to this throwaway daemon and cannot see the live board.
#   • a NARROW permission grant. Spawned cards otherwise run in the default permission mode (only
#     the `plan` column gets --permission-mode auto), so the orchestrator's first spawn call would
#     block on a permission prompt and the GIF would capture a dialog instead of a fan-out. The
#     grant is deliberately the minimum that makes the demo run, and NOT a blanket one:
#       - NO Bash. The fixture prompts only edit files, so the demo agents never need a shell; if
#         one tries, it hits the normal prompt and stalls that card — visible, and harmless.
#       - acceptEdits auto-accepts FILE EDITS only, and those land inside the throwaway worktrees
#         under $ROOT (/private/tmp/orch-docs) — never the user's repos.
#       - only the three orchestra MCP tools the orchestrator actually calls, not the whole server.
#         They are pinned to the isolated socket, so they cannot reach the live board.
# Real agents need a real login, and `claude` resolves its credentials from $HOME — which this harness
# deliberately throws away. So the auth comes from the DURABLE dev agent home (one-time
# `scripts/agent-auth.sh login`), seeded into this run's home. Without it every Claude card would sit
# at a login prompt while the board cheerfully reported it "running" — which is exactly the trap that
# produced a whole set of empty screenshots before this gate existed.
agent_auth_require || fail "isolated agents cannot authenticate — check: scripts/agent-auth.sh status"
agent_auth_seed "$ISO_HOME" || true
note "seeded agent auth (real login keychain, via symlink — no keychain dialogs)"

# Now layer THIS run's config on top — MERGING into the .claude.json the seed brought over (a blind
# overwrite would drop the account fields the login wrote, and we'd be logged out again).
python3 - "$ISO_HOME" "$MCP_BIN" "$SOCK" "$ROOT" "$FIXTURE" <<'PY'
import json, os, sys
home, mcp, sock, root, fixture = sys.argv[1:6]
p = os.path.join(home, ".claude.json")
cfg = {}
if os.path.exists(p):
    try: cfg = json.load(open(p))
    except Exception: cfg = {}
cfg["hasCompletedOnboarding"] = True
cfg["theme"] = "dark"
cfg["mcpServers"] = {"orchestra": {"type": "stdio", "command": mcp, "args": [],
                                   "env": {"ORCHESTRA_SOCK": sock}}}

# PRE-GRANT per-directory trust for every worktree this run will cut. The daemon does grant trust at
# launch — but all four cards launch at once and each grant is a read-modify-write of THIS file, so
# they race and some grants are lost, booting that card into Claude's "Do you trust this folder?"
# dialog instead of into work. (That is a real concurrency bug in the trust grant, worth fixing
# separately; here we simply don't depend on the race.) The paths are deterministic:
#   $worktreesRoot/<repo>/<branch>
spec = json.load(open(fixture))
projects = cfg.setdefault("projects", {})
def trust(path):
    e = projects.setdefault(path, {})
    e["hasTrustDialogAccepted"] = True
    e["hasCompletedProjectOnboarding"] = True
for c in spec["cards"] + [spec["orchestrator"]]:
    # A card with `attachBranch` instead of its own `branch` is a borrowed reviewer — its cwd IS
    # another card's worktree, already trusted by that card's own entry below.
    if "branch" in c:
        trust(os.path.join(root, "worktrees", c["repo"], c["branch"]))
for name in spec["repos"]:
    trust(os.path.join(root, name))
trust(root)
json.dump(cfg, open(p, "w"), indent=2)
os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
    json.dump({"permissions": {
        "defaultMode": "acceptEdits",
        "allow": [
            # The WHOLE orchestra MCP server, not a hand-picked subset: an orchestrator legitimately
            # reaches for status/batch-spawn/tree as well as spawn/wait, and a missing one doesn't
            # fail — it silently parks the card on a permission prompt (which is exactly how the
            # first fan-out captures came out empty). Safe to grant wholesale: every tool on this
            # server resolves through ORCHESTRA_SOCK to the ISOLATED daemon, so the blast radius is
            # the throwaway board.
            "mcp__orchestra",
            "Read", "Edit", "Write", "Grep", "Glob",
            # git + read-only inspection utilities. NOT a blanket Bash grant — no interpreters, no
            # network, no package managers, no rm. But it must not be a hand-picked list of git
            # SUBcommands either: enumerating `git diff/status/log` and omitting `git rev-parse` is
            # what silently parked the orchestrator on an approval prompt and produced an empty
            # fan-out. An agent reaches for whatever git verb it needs; scope it by TOOL, not by
            # guessing the verb. The repos are throwaway trees under $ROOT with no remotes.
            "Bash(git:*)",
            # The `orchestra` CLI is on the agents' PATH (and pinned to the isolated daemon), so they
            # reach for it to move their own card. Ungranted, that too parks them on a prompt.
            "Bash(orchestra:*)",
            "Bash(ls:*)", "Bash(cat:*)", "Bash(pwd:*)", "Bash(head:*)", "Bash(tail:*)",
            "Bash(wc:*)", "Bash(find:*)", "Bash(rg:*)", "Bash(grep:*)",
            # Agents write compound one-liners (`ls -a; for f in …`, `command -v orchestra || …`),
            # which match NO per-verb rule and park the card on an approval prompt — the same class
            # of silent stall that `git rev-parse` caused. These cover the shapes they actually use.
            "Bash(command:*)", "Bash(which:*)", "Bash(test:*)", "Bash(echo:*)", "Bash(node:*)",
        ]}}, f, indent=2)
PY
note "seeded MCP bridge → ORCHESTRA_SOCK=$SOCK (isolated; cannot reach live)"

# The app's light/dark toggle is its OWN preference (@AppStorage "orch_dark" in BoardStore), not the
# system appearance — a fresh isolated $HOME defaults it to light. Seed the app's prefs domain in the
# throwaway home so the captures come out dark. (Never touch the user's real domain.)
mkdir -p "$ISO_HOME/Library/Preferences"
python3 - "$ISO_HOME/Library/Preferences/com.orchestra.app.plist" <<'PY'
import plistlib, sys
plistlib.dump({"orch_dark": True, "orch_accent": "blue", "orch_density": "comfortable",
               "orch_onboarded": True},
              open(sys.argv[1], "wb"))
PY
note "seeded the app prefs domain → dark theme"


# ---------------------------------------------------------------- 3. daemon + app
# Agents inherit the daemon's PATH. Put THIS branch's `orchestra` on it (and pin ORCHESTRA_SOCK to
# the isolated daemon) so a demo agent that reaches for the CLI finds it — and finds the throwaway
# board, never the live one. Without this an agent's `orchestra move …` dies with "command not found".
AGENT_BIN="$ROOT/bin"; mkdir -p "$AGENT_BIN"; ln -sf "$CLI" "$AGENT_BIN/orchestra"

echo "▶ starting isolated daemon…"
HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$AGENT_BIN:$PATH" \
  "$DAEMON" > "$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!; disown "$DAEMON_PID" 2>/dev/null || true
for _ in $(seq 1 40); do grep -q "listening at $SOCK" "$ROOT/daemon.log" 2>/dev/null && break; sleep 0.3; done
grep -q "listening at $SOCK" "$ROOT/daemon.log" || { cat "$ROOT/daemon.log" >&2; fail "daemon never bound $SOCK"; }
[[ -S "$SOCK" ]] || fail "no socket at $SOCK"
note "daemon pid $DAEMON_PID on the isolated socket"

# Dark theme: pass it as a LAUNCH ARGUMENT, not just a seeded plist. The app's toggle is its own
# @AppStorage("orch_dark") pref, and a pre-written plist can be ignored (cfprefsd caches the domain
# for the live user), but NSArgumentDomain always wins — it sits at the top of the UserDefaults
# search order. Belt and braces: the seeded plist above covers a cold read, this covers a cached one.
echo "▶ launching Mac app against the isolated daemon…"
HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" "$BIN" -orch_dark YES -orch_onboarded YES >/dev/null 2>&1 &
APP_PID=$!; disown "$APP_PID" 2>/dev/null || true
{ echo "DAEMON_PID=$DAEMON_PID"; echo "APP_PID=$APP_PID"; echo "IOS_UDID="; } > "$STATE"
float_window_for_pid "$APP_PID"   # off the user's tiling WM — else every doc shot is a squished sliver

# Window id by PID (never by owner name — the user's live app would match).
WID=""
for _ in $(seq 1 40); do
  sleep 0.5
  WID="$(swift scripts/keydrive.swift windowid "$APP_PID" 2>/dev/null || true)"
  [[ -n "$WID" ]] && break
done
[[ -n "$WID" ]] || fail "no window for the isolated app (pid $APP_PID)"
note "app pid $APP_PID, window $WID"

# The window id is NOT stable for the life of the run — SwiftUI can retire and recreate the window's
# backing (a sheet, a resize, an occlusion change), after which `screencapture -l <stale id>` fails
# with "could not create image from window" and, under `set -e`, takes the whole capture down. So
# re-resolve the id from the app's PID on every shot, and retry rather than abort.
resolve_wid() {
  local w=""
  for _ in 1 2 3 4 5; do
    w="$(swift scripts/keydrive.swift windowid "$APP_PID" 2>/dev/null || true)"
    [[ -n "$w" ]] && { WID="$w"; return 0; }
    sleep 0.6
  done
  return 1
}
shot() {
  local name="$1"
  for attempt in 1 2 3; do
    resolve_wid || { sleep 1; continue; }
    if screencapture -x -o -l"$WID" "$OUT/$name.png" 2>/dev/null && [[ -s "$OUT/$name.png" ]]; then
      echo "  ✓ docs/images/$name.png"; return 0
    fi
    sleep 1
  done
  echo "  ✗ $name: could not capture the window (attempt $attempt) — continuing"
  return 0
}
keys()  { swift scripts/keydrive.swift keys "$APP_PID" "$@"; sleep 0.4; }

# Continuous frame capture at ~FPS_DELAY, by window id, into a named frame dir.
rec_start() {
  REC_DIR="$FRAMES/$1"; rm -rf "$REC_DIR"; mkdir -p "$REC_DIR"
  resolve_wid || true
  local wid="$WID" pid="$APP_PID"
  # screencapture's stderr used to go to /dev/null, so a recording that captured ZERO frames for its
  # whole duration (seen repeatedly on the `keyboard` phase — not yet root-caused) left no trace of
  # WHY. Log it instead — cheap, and the only way a future occurrence is diagnosable rather than
  # another guess-and-rerun.
  ( i=0; while :; do
      printf -v n "%04d" "$i"
      if ! screencapture -x -o -l"$wid" "$REC_DIR/f-$n.png" 2>>"$REC_DIR.err.log"; then
        # stale window id mid-recording → re-resolve rather than emit a run of empty frames
        wid="$(swift scripts/keydrive.swift windowid "$pid" 2>/dev/null || echo "$wid")"
        rm -f "$REC_DIR/f-$n.png"
      elif [[ ! -s "$REC_DIR/f-$n.png" ]]; then
        # exit 0 but a zero-byte file (a fully occluded/degenerate window) is still not a frame.
        echo "f-$n: zero-byte capture (wid=$wid)" >>"$REC_DIR.err.log"
        rm -f "$REC_DIR/f-$n.png"
      fi
      i=$((i+1)); sleep "$FPS_DELAY"
    done ) &
  REC_PID=$!
}
rec_stop() {  # rec_stop <name> → assembles docs/images/<name>.gif
  kill "$REC_PID" 2>/dev/null || true; wait "$REC_PID" 2>/dev/null || true
  local n; n="$(ls "$REC_DIR"/f-*.png 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n" -le 1 ]]; then
    echo "  ✗ $1: only $n frames — no GIF"
    [[ -s "$REC_DIR.err.log" ]] && { echo "    · capture errors:"; tail -5 "$REC_DIR.err.log" | sed 's/^/      | /'; }
    return 1
  fi
  # A real fan-out takes minutes, and every captured frame is a full-window PNG — dumping all of them
  # into a GIF produced an 18MB file nobody's README should carry. So keep every Nth frame: the GIF
  # becomes a TIME-LAPSE of the real run (never a re-enactment of it), and the docs say so.
  local keep step i=0 speed
  keep=()
  step=$(( (n + MAX_FRAMES - 1) / MAX_FRAMES )); [[ "$step" -lt 1 ]] && step=1
  for f in "$REC_DIR"/f-*.png; do
    [[ $(( i % step )) -eq 0 ]] && keep+=("$f")
    i=$((i+1))
  done
  speed=$(python3 -c "print(f'{$step:.0f}')")
  echo "  · $1: $n frames → ${#keep[@]} (every ${step}th ⇒ ~${speed}× time-lapse)"
  swift scripts/gifify.swift "$OUT/$1.gif" "$FPS_DELAY" "$GIF_WIDTH" "${keep[@]}"
}

# ---------------------------------------------------------------- 4. seed the board (real agents)
echo "▶ spawning the demo board (REAL agents — these bill)…"
# (bash 3.2 has no `mapfile` — stream the fixture through a plain while-read instead.)
# `col` in the fixture is the card's FINAL column, but `spawn --col` is start-only (plan|impl by
# design), so a review card is spawned into impl and then `move`d — the same two steps a human takes.
python3 - "$FIXTURE" "$ROOT" > "$ROOT/spawn.tsv" <<'PY'
import json, sys
fixture, root = sys.argv[1], sys.argv[2]
spec = json.load(open(fixture))
for c in spec["cards"]:
    col = c["col"]
    start = "impl" if col == "review" else col
    # "-" sentinel, never an empty field: tab is IFS *whitespace*, so bash's `read` collapses
    # consecutive tabs and an empty column would silently shift every later field left.
    print("\t".join([root + "/" + c["repo"], c.get("branch", "-"), c.get("model", "-"), start, col,
                      c.get("attachBranch", "-"), c["prompt"]]))
PY
while IFS=$'\t' read -r repo branch model start col attach prompt; do
  [[ -n "$repo" ]] || continue
  [[ "$model" == "-" ]] && model=""
  [[ "$branch" == "-" ]] && branch=""
  [[ "$attach" == "-" ]] && attach=""
  # The agent backend is inferred from the model id (a gpt-* model ⇒ the Codex adapter).
  args=(--prompt "$prompt" --col "$start")
  if [[ -n "$attach" ]]; then
    # A branchless, read-only, BORROWED reviewer: attach by directory match to the worktree card
    # already sitting on $repo/$attach (needs that card to have spawned first — fixture order
    # puts it earlier in `cards`). `orchestra spawn` only threads `--read-only` through the
    # `--cwd` path today, not `--repo`/`--branch`, so cwd is the CLI-supported way to attach one.
    args+=(--cwd "$ROOT/worktrees/$(basename "$repo")/$attach" --read-only --repo "$repo" --title "Review: $attach")
  else
    args+=(--repo "$repo" --branch "$branch")
    [[ -n "$model" ]] && args+=(--model "$model")
  fi
  ref="$(oc spawn "${args[@]}" | grep -oE '[0-9a-f]{6}' | head -1)"
  note "spawned $(basename "$repo")/${branch:-"→ $attach (attached, read-only)"} → $start${model:+ (model $model)}  [$ref]"
  echo -e "$ref\t$col" >> "$ROOT/refs.tsv"
  if [[ "$col" != "$start" && -n "$ref" ]]; then
    oc move "$ref" --col "$col" >/dev/null && note "moved $ref → $col"
  fi
done < "$ROOT/spawn.tsv"

# Let the agents actually work. The board only tells the truth once they've burned context and
# touched files — a diffstat footer needs real edits on disk — so this wait is load-bearing, not
# padding. (That is the whole point of not faking the telemetry.)
WORK_WAIT=180; SETTLE_WAIT=60; FANOUT_WAIT=300
[[ "$QUICK" == 1 ]] && { WORK_WAIT=40; SETTLE_WAIT=25; FANOUT_WAIT=90; note "--quick: short waits (harness iteration only)"; }
echo "▶ letting the agents work (${WORK_WAIT}s) so context-% and diffstats are real…"
sleep "$WORK_WAIT"
oc list || true

# Agents move their OWN cards — the SessionStart orientation explicitly nudges them to, which is
# correct in real use but means the board has drifted from the fixture by the time we shoot it
# (Review empties, Implementation fills). Put every card back in its fixture column so the stills are
# reproducible. This is a re-assertion of intent, not a fake: each card really is where we say it is.
echo "▶ restoring the fixture's columns (agents move themselves during the work window)…"
while IFS=$'\t' read -r ref col; do
  [[ -n "$ref" ]] || continue
  oc move "$ref" --col "$col" >/dev/null 2>&1 && note "$ref → $col"
done < "$ROOT/refs.tsv"
sleep 3

if has_phase stills; then
  echo "▶ stills…"
  shot board
  # Land on a specific card rather than "whatever is first" — use the board's own `/` search so the
  # inspector/diff stills always show the same working card (the pagination one) run to run.
  # Land on a specific card by NAVIGATION, not search. `/` opens a filter overlay that sits ON TOP of
  # the board and swallows the following keys as text — the shot came out as the search bar, not the
  # inspector. `g i` jumps to Implementation, `j` steps to the second card (the Claude pagination
  # one); moving the selection is itself what opens that card's inspector.
  keys g i; sleep 4                # Implementation holds only the pagination card → deterministic
  shot inspector
  keys d; sleep 4;  shot diff      # `d` CYCLES the inspector Agent → Diff → Docs → Agent
  keys d; sleep 4;  shot docs      # second `d`: Diff → Docs (the document reader)
  keys d; sleep 1                  # third `d`: Docs → back to the agent terminal
  keys c; sleep 3;  shot spawn     # `c` opens the spawn sheet
  keys esc; sleep 1
fi

# ---------------------------------------------------------------- 5. the hero: NL → MCP fan-out
if has_phase orchestrate; then
  echo "▶ orchestrator card (natural language → MCP spawn ×3)…"
  ORCH_JSON="$(python3 -c '
import json,sys; s=json.load(open(sys.argv[1]))["orchestrator"]
print("\t".join([sys.argv[2]+"/"+s["repo"], s["branch"], s["agent"], s["col"], s["prompt"], s["nudge"]]))' "$FIXTURE" "$ROOT")"
  IFS=$'\t' read -r orepo obranch oagent ocol oprompt onudge <<<"$ORCH_JSON"
  ORCH_REF="$(oc spawn --prompt "$oprompt" --repo "$orepo" --branch "$obranch" --agent "$oagent" --col "$ocol" \
              | grep -oE '[0-9a-f]{6}' | head -1)"
  [[ -n "$ORCH_REF" ]] || fail "could not spawn the orchestrator card"
  note "orchestrator card $ORCH_REF — settling before it gets its instruction"
  sleep "$SETTLE_WAIT"

  rec_start orchestrate
  note "recording — sending the natural-language instruction"
  oc send "$ORCH_REF" "$onudge" >/dev/null
  # The orchestrator does NOT spawn instantly: it reads the code, loads the orchestra-delegation
  # skill, and resolves its MCP tools first — a couple of minutes before the first spawn lands. Too
  # short a window here captures an orchestrator that is still thinking, and an empty board.
  sleep "$FANOUT_WAIT"
  note "board after the fan-out:"; oc list || true
  # If it did not fan out, the reason is almost always ON THE AGENT'S SCREEN (an approval prompt, a
  # tool error) and invisible in the board state — so surface it rather than making the next run guess.
  if [[ "$(oc list 2>/dev/null | grep -c ratelimit-)" -eq 0 ]]; then
    echo "  ✗ NO CHILDREN SPAWNED — orchestrator's terminal says:"
    osess="$(tmux -L "$ISO_TMUX_SOCKET" list-panes -a -F '#{session_name} #{pane_current_path}' 2>/dev/null \
             | grep 'feat/ratelimit$' | awk '{print $1}' | head -1)"
    [[ -n "$osess" ]] && tmux -L "$ISO_TMUX_SOCKET" capture-pane -p -t "$osess" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | tail -25 | sed 's/^/      | /'
  fi
  rec_stop orchestrate || true
  shot board-fanout
fi

# ---------------------------------------------------------------- 6. keyboard nav
if has_phase keyboard; then
  echo "▶ keyboard navigation…"
  keys esc; sleep 1
  rec_start keyboard
  keys j;      keys j;      keys l          # selection walks; cross into Implementation
  keys C-l;    sleep 1;     keys C-h        # focus jumps to the inspector and back
  keys f;      sleep 1.2;   keys esc        # link hints over every card
  keys /;      sleep 1;     keys esc        # search
  keys "S-;";  sleep 1.5;   keys esc        # : command palette
  keys "S-/";  sleep 2;     keys esc        # ? keymap overlay
  # Drill: search-select the orchestrator root (board position isn't fixed once the fan-out has
  # run, so search is the deterministic way to land on it) and walk into / out of its subtree — the
  # scope axis the board-hierarchy redesign added, `→`/`←`.
  keys /; sleep 0.3
  # ONE `keys` call for the whole word, not nine: each call launches a fresh `swift
  # scripts/keydrive.swift` process (real compile/launch overhead, uncached — Swift script mode),
  # and nine of those in a row burned most of this phase's wall-clock for a hidden reason the
  # recording still had to sit through, starving `rec_start`'s frame loop.
  keys r a t e l i m i t
  sleep 0.4; keys cr; sleep 1
  keys right; sleep 1.5;    keys left; sleep 1
  rec_stop keyboard || true
fi

# ---------------------------------------------------------------- 7. iPhone
if has_phase ios; then
  echo "▶ iPhone shots (same isolated daemon)…"
  UDID="$(xcrun simctl list devices booted | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' || true)"
  if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
    [[ -n "$UDID" ]] && xcrun simctl boot "$UDID" 2>/dev/null || true
  fi
  if [[ -n "$UDID" ]] && [[ ! -d App-iOS/OrchestraiOS.xcodeproj ]]; then
    # `xcodegen generate` for App-iOS only runs above under `if [[ "$BUILD" == 1 ]]` — with
    # --no-build (and no prior `ios`-phase run) the .xcodeproj was never generated. Without this
    # guard, `xcodebuild -showBuildSettings` on a nonexistent project fails instantly, its stderr is
    # swallowed by `2>/dev/null` below, and — because that failure sits in an unguarded `IOS_APP=$(…
    # | awk …)` command substitution — `set -e -o pipefail` silently kills the WHOLE script right
    # here: no error, no "done" banner, nothing after the "▶ iPhone shots…" line above. That is
    # exactly what made every earlier `--no-build ios` run in this branch's history look like an
    # unexplained hang instead of the ordinary, fixable gap it actually is.
    echo "  ✗ App-iOS/OrchestraiOS.xcodeproj not generated (needs a run without --no-build first) — skipping iPhone shots"
  elif [[ -n "$UDID" ]]; then
    xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
    IOS_APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')" || true
    if [[ -d "$IOS_APP" ]]; then
      xcrun simctl install "$UDID" "$IOS_APP"
      SIMCTL_CHILD_ORCH_DEV_SOCKET="$SOCK" xcrun simctl launch "$UDID" "$IOS_BUNDLE" >/dev/null
      sleep 6
      xcrun simctl io "$UDID" screenshot "$OUT/ios-board.png" >/dev/null 2>&1 && echo "  ✓ docs/images/ios-board.png"
      { echo "DAEMON_PID=$DAEMON_PID"; echo "APP_PID=$APP_PID"; echo "IOS_UDID=$UDID"; } > "$STATE"
    else
      echo "  ✗ iOS app product not found — skipping iPhone shots"
    fi
  else
    echo "  ✗ no iPhone Simulator available — skipping iPhone shots"
  fi
fi

echo
echo "▶ done → docs/images/"
ls -lh "$OUT" 2>/dev/null | tail -n +2 | awk '{print "    " $9 "  " $5}'
[[ "$KEEP" == 1 ]] && echo "  (stack left UP — tear down with: scripts/docs-shots.sh down)"
exit 0
