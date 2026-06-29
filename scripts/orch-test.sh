#!/usr/bin/env bash
#
# orch-test.sh — spin up a DISPOSABLE, ISOLATED Orchestra instance to verify changes WITHOUT
# touching the live daemon/app the user is running (and without foregrounding anything).
#
# Isolation comes from two env overrides, so the test instance physically cannot collide with live:
#   • HOME  → a throwaway dir under /tmp  ⇒ its own dataDir / socket / config / tasks.json
#   • ORCHESTRA_TMUX_SOCKET → its own `tmux -L` server  ⇒ no session collisions with live cards
# The daemon also runs under a PATH that EXCLUDES ~/.local/bin, so `claude` isn't found — the fresh
# tmux server inherits that PATH, so spawn/inspect deliver their recipe but DON'T launch (or bill) a
# real claude. Drop USE_REAL_CLAUDE=1 to allow a genuine end-to-end claude launch.
#
# Flow:   scripts/orch-test.sh init && scripts/orch-test.sh up
#         scripts/orch-test.sh rpc inspect '{"ref":"aaaaaa"}'
#         scripts/orch-test.sh tmux capture-pane -p -t orchestra-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:shell-1
#         scripts/orch-test.sh down
#
# Run unsandboxed: the daemon binds a UDS socket, writes its data dir, and enumerates processes —
# all blocked by the Bash sandbox.
set -euo pipefail

ROOT=/tmp/orch-test                              # short path: UDS socket must stay < 104 chars
HOME_DIR="$ROOT/home"
DATA="$HOME_DIR/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
TMUX_SOCK=orch-test
CARD_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"   # fixed id ⇒ shortId "aaaaaa", session orchestra-aaaa…
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/.build/debug/orchestrad"
if [ "${USE_REAL_CLAUDE:-0}" = "1" ]; then RUN_PATH="$PATH"; else RUN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; fi

cmd="${1:-}"; shift || true
case "$cmd" in
  init)                                          # seed a throwaway git repo + worktree + one card
    rm -rf "$ROOT"; mkdir -p "$DATA" "$ROOT/repo"
    ( cd "$ROOT/repo" && git init -q && git config user.email t@t.t && git config user.name t \
        && git commit -q --allow-empty -m init && git worktree add -q ../wt -b verify )
    python3 - "$DATA/tasks.json" "$ROOT/repo" "$ROOT/wt" "$CARD_ID" <<'PY'
import json, sys
tasks, repo, wt, cid = sys.argv[1:5]
card = {"id": cid, "title": "test card", "titleProvisional": False, "desc": "", "repo": repo,
        "branch": "verify", "worktree": wt, "agentId": "claude-code",
        "model": {"id": "claude-opus-4-8", "displayName": "Opus 4.8", "family": "claude"},
        "startIn": "impl", "column": "impl", "order": 0, "status": "waiting", "ctxPct": 0,
        "priorSessionIds": [], "initialPrompt": "t", "archived": False,
        "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
json.dump([card], open(tasks, "w"), indent=2)
PY
    echo "seeded: card $CARD_ID (shortId aaaaaa), worktree $ROOT/wt"
    ;;
  up)                                            # build + start the isolated daemon in the background
    swift build --package-path "$REPO_ROOT" >&2
    mkdir -p "$DATA"
    HOME="$HOME_DIR" ORCHESTRA_TMUX_SOCKET="$TMUX_SOCK" PATH="$RUN_PATH" \
      "$DAEMON" > "$ROOT/daemon.log" 2>&1 &
    sleep 2
    if ! grep -q "listening" "$ROOT/daemon.log" 2>/dev/null; then
      echo "daemon failed to start:" >&2; cat "$ROOT/daemon.log" >&2; exit 1
    fi
    echo "isolated daemon up.  socket: $SOCK   tmux: -L $TMUX_SOCK   (real claude: ${USE_REAL_CLAUDE:-0})"
    ;;
  rpc)  ORCH_SOCK="$SOCK" python3 "$REPO_ROOT/scripts/orch-rpc.py" "$@" ;;
  tmux) tmux -L "$TMUX_SOCK" "$@" ;;
  log)  cat "$ROOT/daemon.log" ;;
  down)                                          # stop the daemon, kill its tmux server, wipe scratch
    tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
    pkill -f "ORCHESTRA_TMUX_SOCKET=$TMUX_SOCK" 2>/dev/null || true
    pkill -f "$DAEMON" 2>/dev/null || true       # path is .build/debug — never matches the installed one
    rm -rf "$ROOT"
    echo "isolated instance torn down."
    ;;
  *)
    echo "usage: orch-test.sh {init|up|rpc <method> [json]|tmux <args…>|log|down}" >&2
    echo "  USE_REAL_CLAUDE=1 to allow a genuine claude launch (default: neutralized)" >&2
    exit 1 ;;
esac
