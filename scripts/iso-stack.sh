#!/usr/bin/env bash
#
# iso-stack.sh — bring up a PERSISTENT, ISOLATED Orchestra stack (daemon + Mac app + iPhone app)
# to test THIS branch without touching the live daemon/app the user is running.
#
# Unlike scripts/orch-ux-e2e.sh (one-shot: screenshot then tear down on exit), this LEAVES the
# whole stack running so you can tap around the real Mac + iPhone UIs interactively. Tear it down
# yourself with `scripts/iso-stack.sh down` when finished.
#
# ISOLATION CONTRACT (why this can't touch live):
#   • $HOME is the ONLY steering lever for the daemon + Mac app. Config.home -> $HOME derives the
#     daemon's socket/data/config AND the Mac app's ControlClient path (Config.socketPath). So an
#     isolated-$HOME app + isolated-$HOME daemon connect to EACH OTHER, never live.
#   • orchestrad is SPAWNED DIRECTLY under the isolated $HOME — NOT via launchctl. The LaunchAgent
#     label `com.orchestra.daemon` is fixed / not HOME-namespaced, so the app's install path would
#     collide with the live agent; a directly-spawned daemon already owns the isolated socket, so
#     the app just connects to it.
#   • The iPhone app (Simulator) reaches the SAME isolated daemon via the ORCH_DEV_SOCKET override
#     (SIMCTL_CHILD_ORCH_DEV_SOCKET) — the Simulator shares the Mac filesystem, so it opens the
#     isolated UDS by absolute path. It never resolves the live socket.
#   • ORCHESTRA_TMUX_SOCKET isolates the tmux server too (agent panes don't hit -L orchestra).
#   • PATH excludes the real `claude`/`codex`: spawned cards launch an inert fake-agent that never
#     bills. Set USE_REAL_CLAUDE=1 to opt into genuine (billed) agents on this isolated stack.
#
# Run UNSANDBOXED: builds app bundles (xcodebuild needs ~/Library), binds a UDS socket, writes a
# data dir, launches a GUI app, and drives simctl.
#
# Usage:
#   scripts/iso-stack.sh up   [--no-build] [--no-ios]   bring the stack up (default)
#   scripts/iso-stack.sh down                           tear this stack down (leave live untouched)
#   scripts/iso-stack.sh status                         show what's running
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- fixed, single-instance isolated roots (short path: UDS socket must stay < 104 chars) ---
# CANONICAL (symlink-resolved) root — macOS /tmp→/private/tmp. Claude/Codex canonicalize their cwd
# before the trust + transcript/resume lookup, and the daemon keys trust (and the transcript slug) on
# the STORED cwd. A "/tmp/…" root stores /tmp/… but the agent looks up /private/tmp/… → a spurious
# trust prompt AND broken resume/wake. Rooting at the physical path makes every stored cwd match.
ROOT="$(cd /tmp && pwd -P)/orch-iso"      # → /private/tmp/orch-iso
ISO_HOME="$ROOT/home"
DATA="$ISO_HOME/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
LIVE_SOCK="$HOME/Library/Application Support/Orchestra/orchestrad.sock"
ISO_TMUX_SOCKET="orch-iso"
CARD_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"          # shortId "aaaaaa"
DAEMON="$REPO_ROOT/.build/debug/orchestrad"
DD="$REPO_ROOT/.scratch/iso-stack-dd"                   # Mac app DerivedData (gitignored, not $TMPDIR)
STATE="$ROOT/stack.state"                               # records pids/udid for down/status
IOS_BUNDLE="com.orchestra.ios"

if [ "${USE_REAL_CLAUDE:-0}" = "1" ]; then RUN_PATH="$PATH"; else RUN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; fi
FAKE_BIN="$ROOT/fakebin"
if [ "${USE_REAL_CLAUDE:-0}" != "1" ]; then RUN_PATH="$FAKE_BIN:$RUN_PATH"; fi

fail() { echo "  ✗ $*" >&2; exit 1; }
find_app() { /usr/bin/find "$DD/Build/Products/Debug" -maxdepth 1 -name 'Orchestra.app' 2>/dev/null | head -1; }

# ------------------------------------------------------------------ login / down / status
kv() { grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }

# Interactive one-time OAuth into the ISOLATED $HOME. Must run in a real terminal (browser flow +
# TTY) — NOT backgrounded. Writes creds under $ISO_HOME/.claude, so every agent on this isolated
# stack becomes authenticated. Isolated from your live login; wiped on `down`. USE_REAL_CLAUDE mode
# only — the fake-agent needs no login.
cmd_login() {
  [[ -d "$ISO_HOME" ]] || fail "no isolated \$HOME at $ISO_HOME — bring the stack up first (USE_REAL_CLAUDE=1 scripts/iso-stack.sh up)"
  command -v claude >/dev/null || fail "'claude' not on PATH in this shell"
  echo "▶ launching claude under the isolated \$HOME — run /login, finish the browser OAuth, then exit."
  echo "  (HOME=$ISO_HOME) creds land in the throwaway home; your live login is untouched."
  exec env HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" claude
}

cmd_down() {
  echo "▶ tearing down isolated stack…"
  if [[ -f "$STATE" ]]; then
    local app_pid daemon_pid udid
    app_pid="$(kv APP_PID)"; daemon_pid="$(kv DAEMON_PID)"; udid="$(kv IOS_UDID)"
    [[ -n "$app_pid" ]]    && kill "$app_pid"    2>/dev/null && echo "  • killed Mac app ($app_pid)"     || true
    [[ -n "$udid" ]]       && xcrun simctl terminate "$udid" "$IOS_BUNDLE" 2>/dev/null && echo "  • terminated iPhone app on $udid" || true
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null && echo "  • killed daemon ($daemon_pid)"   || true
  fi
  tmux -L "$ISO_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$ROOT"
  echo "  ✓ isolated stack down; /tmp/orch-iso removed. Live daemon/app untouched."
}

cmd_status() {
  if [[ ! -f "$STATE" ]]; then echo "no isolated stack recorded (run: scripts/iso-stack.sh up)"; return 0; fi
  local app_pid daemon_pid udid
  app_pid="$(kv APP_PID)"; daemon_pid="$(kv DAEMON_PID)"; udid="$(kv IOS_UDID)"
  echo "isolated stack ($ROOT):"
  echo "  socket : $SOCK  ($([[ -S "$SOCK" ]] && echo present || echo MISSING))"
  echo "  daemon : pid $daemon_pid  ($(kill -0 "$daemon_pid" 2>/dev/null && echo alive || echo dead))"
  echo "  Mac app: pid $app_pid  ($(kill -0 "$app_pid" 2>/dev/null && echo alive || echo dead))"
  if [[ -n "$udid" ]]; then
    echo "  iPhone : sim $udid  app $(xcrun simctl spawn "$udid" launchctl print system 2>/dev/null | grep -q "$IOS_BUNDLE" && echo running || echo '(check Simulator)')"
  fi
}

# ------------------------------------------------------------------ up
cmd_up() {
  local build=1 do_ios=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-build) build=0; shift ;;
      --no-ios)   do_ios=0; shift ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  [[ "$SOCK" == "$LIVE_SOCK" ]] && fail "isolated socket == live socket — aborting"
  if [[ -f "$STATE" ]] && kill -0 "$(kv DAEMON_PID)" 2>/dev/null; then
    fail "an isolated stack is already up (scripts/iso-stack.sh status). Run 'down' first."
  fi

  # --- 1. build daemon + Mac app (+ iOS app) off THIS branch ---
  if [[ "$build" == 1 ]]; then
    echo "▶ building daemon (debug)…"
    "$REPO_ROOT"/scripts/lib/with-lock.sh build -- swift build --package-path "$REPO_ROOT" --product orchestrad
    echo "▶ building Mac app (Debug)…"
    xcodegen generate --spec App/project.yml --project App >/dev/null
    "$(dirname "$0")/lib/with-lock.sh" build -- xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "$DD" build >/dev/null
    if [[ "$do_ios" == 1 ]]; then
      echo "▶ building iPhone app (Debug)…"
      xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
      "$(dirname "$0")/lib/with-lock.sh" build -- xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
        -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build >/dev/null
    fi
  fi
  [[ -x "$DAEMON" ]] || fail "daemon not built at $DAEMON (run 'up' without --no-build)"
  local app bin; app="$(find_app)"; bin="$app/Contents/MacOS/Orchestra"
  [[ -n "$app" && -x "$bin" ]] || fail "Mac app not built in $DD (run 'up' without --no-build)"

  # --- 2. seed the isolated data dir: throwaway repo + worktree + one card + allowlist config ---
  echo "▶ seeding isolated \$HOME at $ISO_HOME"
  rm -rf "$ROOT"; mkdir -p "$DATA" "$ROOT/repo"
  if [ "${USE_REAL_CLAUDE:-0}" != "1" ]; then
    # Inert fake-agent on PATH: cards spawn a real tmux session but the "agent" never runs / never bills.
    mkdir -p "$FAKE_BIN"
    ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/claude"
    ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/codex"
  else
    # REAL agents on the isolated stack. The daemon writes per-directory trust itself
    # (ClaudeTrust.grant at launch) but NOT the global first-run onboarding, so a fresh isolated
    # $HOME would stall on Claude's theme-picker. Pre-seed hasCompletedOnboarding+theme so the first
    # launch goes straight to work. Claude OAuth rides the login Keychain (not $HOME-scoped), so it
    # authenticates fine under the isolated HOME. Codex authenticates from $CODEX_HOME/auth.json
    # ($HOME/.codex here) — bridge the live one in, else codex prompts for login and stalls.
    echo "  • USE_REAL_CLAUDE=1 → seeding onboarding + bridging codex auth (real agents WILL bill)"
    python3 - "$ISO_HOME/.claude.json" <<'PY'
import json, sys, os
p = sys.argv[1]
root = {}
if os.path.exists(p):
    try: root = json.load(open(p))
    except Exception: root = {}
root.setdefault("hasCompletedOnboarding", True)
root.setdefault("theme", "dark")
json.dump(root, open(p, "w"), indent=2)
PY
    mkdir -p "$ISO_HOME/.codex"
    cp "$HOME/.codex/auth.json" "$ISO_HOME/.codex/auth.json" 2>/dev/null \
      && echo "  • bridged ~/.codex/auth.json → isolated CODEX_HOME" \
      || echo "  • note: no ~/.codex/auth.json to bridge — codex cards would prompt for login (claude unaffected)"
  fi
  ( cd "$ROOT/repo" && git init -q && git config user.email t@t.t && git config user.name t \
      && git commit -q --allow-empty -m init && git worktree add -q ../wt -b verify )
  python3 - "$DATA/tasks.json" "$ROOT/repo" "$ROOT/wt" "$CARD_ID" <<'PY'
import json, sys
tasks, repo, wt, cid = sys.argv[1:5]
card = {"id": cid, "title": "isolated test card", "titleProvisional": False, "desc": "", "repo": repo,
        "branch": "verify", "worktree": wt, "agentId": "claude-code",
        "model": {"id": "claude-opus-4-8", "displayName": "Opus 4.8", "family": "claude"},
        "startIn": "impl", "column": "impl", "order": 0, "status": "waiting", "ctxPct": 0,
        "priorSessionIds": [], "initialPrompt": "t", "archived": False,
        "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
json.dump([card], open(tasks, "w"), indent=2)
PY
  python3 - "$DATA/config.json" "$ROOT" <<'PY'
import json, sys
cfg_path, root = sys.argv[1:3]
cfg = {"reposRoot": root, "worktreesRoot": root + "/worktrees", "defaultAgentId": "claude-code",
       "allowlist": [root], "maxConcurrentRevivals": 4, "revivalGraceSeconds": 15,
       "statusLineMode": "orchestraDefault"}
json.dump(cfg, open(cfg_path, "w"), indent=2)
PY

  # --- 3. spawn the daemon DIRECTLY under the isolated $HOME (never launchctl) ---
  echo "▶ starting isolated daemon (direct spawn, not launchctl)…"
  HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$RUN_PATH" \
    "$DAEMON" > "$ROOT/daemon.log" 2>&1 &
  local daemon_pid=$!; disown "$daemon_pid" 2>/dev/null || true
  for _ in $(seq 1 30); do grep -q "listening" "$ROOT/daemon.log" 2>/dev/null && break; sleep 0.3; done
  grep -q "listening at $SOCK" "$ROOT/daemon.log" \
    || { cat "$ROOT/daemon.log" >&2; fail "daemon didn't bind the isolated socket"; }
  [[ -S "$SOCK" ]] || fail "isolated socket $SOCK not present"
  echo "  ✓ daemon isolated at $SOCK (pid $daemon_pid)"

  # --- 4. launch the Mac app against the SAME isolated $HOME → connects to the isolated daemon ---
  echo "▶ launching Mac app against the isolated daemon…"
  HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$RUN_PATH" "$bin" >/dev/null 2>&1 &
  local app_pid=$!; disown "$app_pid" 2>/dev/null || true
  echo "  ✓ Mac app launched (pid $app_pid)"

  # --- 5. iPhone app: boot a Simulator, install, launch pointed at the isolated socket ---
  local udid=""
  if [[ "$do_ios" == 1 ]]; then
    echo "▶ launching iPhone app (Simulator) against the isolated daemon…"
    udid="$(xcrun simctl list devices booted | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
    if [[ -z "$udid" ]]; then
      udid="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
      [[ -n "$udid" ]] || fail "no available iPhone Simulator (set one up in Xcode)"
      xcrun simctl boot "$udid" 2>/dev/null || true
    fi
    open -a Simulator
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    local ios_app
    ios_app="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
    [[ -d "$ios_app" ]] || fail "iOS app product not found (run 'up' without --no-build, or drop --no-ios)"
    xcrun simctl install "$udid" "$ios_app"
    SIMCTL_CHILD_ORCH_DEV_SOCKET="$SOCK" xcrun simctl launch "$udid" "$IOS_BUNDLE" >/dev/null
    echo "  ✓ iPhone app launched on Simulator $udid (ORCH_DEV_SOCKET=$SOCK)"
  fi

  # --- record state for down/status ---
  { echo "DAEMON_PID=$daemon_pid"; echo "APP_PID=$app_pid"; echo "IOS_UDID=$udid"; } > "$STATE"

  echo
  echo "▶ isolated stack UP — this branch, separate from your live app."
  echo "    daemon : $SOCK (pid $daemon_pid)"
  echo "    Mac app: pid $app_pid (its own window; live app is a separate window)"
  [[ -n "$udid" ]] && echo "    iPhone : Simulator $udid"
  echo "    Tear down when done:  scripts/iso-stack.sh down"
}

# ------------------------------------------------------------------ dispatch
SUB="${1:-up}"
case "$SUB" in
  up)     shift; cmd_up "$@" ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  login)  cmd_login ;;
  --*)    cmd_up "$@" ;;                 # bare flags → up
  *)      fail "usage: iso-stack.sh {up [--no-build] [--no-ios] | login | down | status}" ;;
esac
