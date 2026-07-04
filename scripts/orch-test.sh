#!/usr/bin/env bash
#
# orch-test.sh — spin up a DISPOSABLE, ISOLATED Orchestra instance to verify changes WITHOUT
# touching the live daemon/app the user is running (and without foregrounding anything).
#
# Isolation comes from two env overrides, so the test instance physically cannot collide with live:
#   • HOME  → a throwaway dir under /tmp  ⇒ its own dataDir / socket / config / tasks.json / CODEX_HOME
#   • ORCHESTRA_TMUX_SOCKET → its own `tmux -L` server  ⇒ no session collisions with live cards
# The daemon also runs under a PATH that EXCLUDES ~/.local/bin, so `claude`/`codex` aren't found — the
# fresh tmux server inherits that PATH, so spawn/inspect deliver their recipe but DON'T launch (or bill)
# a real agent. Set USE_REAL_CLAUDE=1 or USE_REAL_CODEX=1 to widen PATH for a genuine end-to-end launch.
#
# Flow:   scripts/orch-test.sh init && scripts/orch-test.sh up
#         scripts/orch-test.sh rpc inspect '{"ref":"aaaaaa"}'
#         scripts/orch-test.sh tmux capture-pane -p -t orchestra-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:shell-1
#         scripts/orch-test.sh down
#   AGENT=codex scripts/orch-test.sh init            # seed a codex card instead of claude-code
#   USE_REAL_CLAUDE=1 scripts/orch-test.sh claude-smoke # end-to-end: send → live claude delivery (resume-seed wake)
#   USE_REAL_CODEX=1 scripts/orch-test.sh codex-smoke  # end-to-end: send → live codex delivery
#
# Run unsandboxed: the daemon binds a UDS socket, writes its data dir, and enumerates processes —
# all blocked by the Bash sandbox.
set -euo pipefail

# Canonical, symlink-resolved ROOT is LOAD-BEARING for the resume/wake/inbox paths.
# On macOS /tmp is a symlink to /private/tmp. The daemon stores a card's cwd VERBATIM and derives
# Claude's transcript dir (~/.claude/projects/<slug>) by replacing every non-alnum in the cwd with '-'
# (ClaudeCodeAdapter.cwdSlug). But Claude Code resolves its cwd to the PHYSICAL path before writing the
# transcript, so a /tmp/... cwd slugs to '-tmp-...' while the real transcript lands under
# '-private-tmp-...' → transcript not found → isResumable=false → `wake` no-ops at gate C → an idle card
# NEVER wakes. The same mismatch breaks Claude's per-directory trust lookup (projects[<abs-cwd>]).
# Resolving ROOT to its physical path up front makes every cwd match what the agents actually write.
# `/tmp` always exists, so `cd /tmp && pwd -P` yields the canonical prefix even before orch-test exists.
ROOT="$(cd /tmp && pwd -P)/orch-test"            # e.g. /private/tmp/orch-test — canonical (see above); UDS socket stays < 104 chars
HOME_DIR="$ROOT/home"
DATA="$HOME_DIR/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
TMUX_SOCK=orch-test
CARD_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"   # fixed id ⇒ shortId "aaaaaa", session orchestra-aaaa…
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/.build/debug/orchestrad"
# Either toggle widens PATH so the real agent binary (under ~/.local/bin) is reachable end-to-end.
if [ "${USE_REAL_CLAUDE:-0}" = "1" ] || [ "${USE_REAL_CODEX:-0}" = "1" ]; then RUN_PATH="$PATH"
else RUN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; fi
AGENT="${AGENT:-claude-code}"                    # which adapter the seeded card uses (init)

rpc() { ORCH_SOCK="$SOCK" python3 "$REPO_ROOT/scripts/orch-rpc.py" "$@"; }

# Pre-seed the throwaway HOME so real `claude`/`codex` start CLEAN and TRUSTED — no first-run onboarding
# (theme picker) and no per-directory trust prompt. Without this, a fresh HOME shows those prompts and
# the agent never starts a session / fires hooks / goes idle-resumable, so any send/wake test stalls.
# The live app avoids this because the real HOME already completed onboarding and pre-accepted trust.
# Mirrors exactly what the daemon's ClaudeTrust/CodexTrust write natively (see ClaudeCodeAdapter.swift /
# CodexAdapter.swift), so it composes with — never clobbers — the daemon's own trust mirroring.
seed_home() {
  mkdir -p "$HOME_DIR/.codex"
  # We pre-trust the seeded card's worktree + its source repo. Scratch cards spawned during a test get
  # their cwds trusted by the daemon at launch (now that cwds are canonical, those writes line up too).
  HOME_DIR="$HOME_DIR" python3 - "$ROOT/wt" "$ROOT/repo" <<'PY'
import json, os, sys
home = os.environ["HOME_DIR"]
cwds = sys.argv[1:]

# --- Claude: ~/.claude.json — hasCompletedOnboarding + theme skip the first-run picker; a per-project
#     `hasTrustDialogAccepted` skips the "Yes, I trust this folder" prompt (keyed by ABSOLUTE cwd).
cj = os.path.join(home, ".claude.json")
try:
    root = json.load(open(cj))
    if not isinstance(root, dict): root = {}
except Exception:
    root = {}
root["hasCompletedOnboarding"] = True
root.setdefault("theme", "dark")
projects = root.get("projects") if isinstance(root.get("projects"), dict) else {}
for cwd in cwds:
    proj = projects.get(cwd) if isinstance(projects.get(cwd), dict) else {}
    proj["hasTrustDialogAccepted"] = True
    projects[cwd] = proj
root["projects"] = projects
json.dump(root, open(cj, "w"), indent=2)

# --- Codex: $CODEX_HOME/config.toml (CODEX_HOME = $HOME/.codex) — a [projects."<cwd>"] table with
#     trust_level = "trusted" pre-accepts directory trust so `codex` doesn't prompt on first launch.
ct = os.path.join(home, ".codex", "config.toml")
try:
    text = open(ct).read()
except Exception:
    text = ""
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
for cwd in cwds:
    header = '[projects."%s"]' % esc(cwd)
    if header in text: continue
    if text and not text.endswith("\n"): text += "\n"
    text += '\n%s\ntrust_level = "trusted"\n' % header
open(ct, "w").write(text)
PY
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init)                                          # seed a throwaway git repo + worktree + one card
    rm -rf "$ROOT"; mkdir -p "$DATA" "$ROOT/repo"
    ( cd "$ROOT/repo" && git init -q && git config user.email t@t.t && git config user.name t \
        && git commit -q --allow-empty -m init && git worktree add -q ../wt -b verify )
    AGENT="$AGENT" python3 - "$DATA/tasks.json" "$ROOT/repo" "$ROOT/wt" "$CARD_ID" <<'PY'
import json, os, sys
tasks, repo, wt, cid = sys.argv[1:5]
agent = os.environ.get("AGENT", "claude-code")
model = ({"id": "gpt-5.3-codex", "displayName": "GPT-5.3 Codex", "family": "gpt"} if agent == "codex"
         else {"id": "claude-opus-4-8", "displayName": "Opus 4.8", "family": "claude"})
card = {"id": cid, "title": "test card", "titleProvisional": False, "desc": "", "repo": repo,
        "branch": "verify", "worktree": wt, "agentId": agent, "model": model,
        "startIn": "impl", "column": "impl", "order": 0, "status": "waiting", "ctxPct": 0,
        "priorSessionIds": [], "initialPrompt": "t", "archived": False,
        "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
json.dump([card], open(tasks, "w"), indent=2)
PY
    echo "seeded: $AGENT card $CARD_ID (shortId aaaaaa), worktree $ROOT/wt"
    ;;
  up)                                            # build + start the isolated daemon in the background
    swift build --package-path "$REPO_ROOT" >&2
    mkdir -p "$DATA"
    seed_home                                    # onboarding + per-dir trust so real agents start clean (no prompts)
    HOME="$HOME_DIR" ORCHESTRA_TMUX_SOCKET="$TMUX_SOCK" PATH="$RUN_PATH" \
      "$DAEMON" > "$ROOT/daemon.log" 2>&1 &
    sleep 2
    if ! grep -q "listening" "$ROOT/daemon.log" 2>/dev/null; then
      echo "daemon failed to start:" >&2; cat "$ROOT/daemon.log" >&2; exit 1
    fi
    echo "isolated daemon up.  socket: $SOCK   tmux: -L $TMUX_SOCK" \
         "  (real claude: ${USE_REAL_CLAUDE:-0}, real codex: ${USE_REAL_CODEX:-0})"
    ;;
  codex-smoke)
    # END-TO-END: send → live Codex delivery. Spawns a REAL read-only codex card, waits for it to go
    # idle (.waiting, from the rollout tail), `send`s a unique marker, and asserts it is DELIVERED — the
    # resume-seed wake folds the inbox into the resumed session's opening turn, so the marker surfaces in
    # the live codex pane. Requires a real `codex` on PATH: run with USE_REAL_CODEX=1. Assumes `up`.
    command -v codex >/dev/null 2>&1 || { echo "codex-smoke: no real 'codex' on PATH — run with USE_REAL_CODEX=1" >&2; exit 1; }
    # Real codex authenticates from $CODEX_HOME/auth.json; the isolated HOME redirects CODEX_HOME away
    # from the user's login, so bridge it into the throwaway home (wiped by `down`).
    mkdir -p "$HOME_DIR/.codex"
    cp "$HOME/.codex/auth.json" "$HOME_DIR/.codex/auth.json" 2>/dev/null \
      || echo "codex-smoke: note — no ~/.codex/auth.json to copy; codex may prompt for login and stall" >&2
    marker="ORCH-SMOKE-$$-${RANDOM}"
    echo "codex-smoke: spawning a read-only codex card…"
    ref=$(rpc spawn '{"prompt":"Reply with the single word READY and then stop.","agent":"codex","access":"readOnly","scratch":true}' \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    echo "codex-smoke: card $ref — waiting for it to go idle (.waiting)…"
    for _ in $(seq 1 60); do
      st=$(rpc status "{\"ref\":\"$ref\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task",{}).get("status",""))' 2>/dev/null || true)
      [ "$st" = "waiting" ] && break
      sleep 2
    done
    echo "codex-smoke: idle. sending marker '$marker'…"
    rpc send "{\"ref\":\"$ref\",\"message\":\"$marker\"}" >/dev/null
    sess="orchestra-$(printf '%s' "$ref" | tr 'A-Z' 'a-z')"
    echo "codex-smoke: waiting for the marker to surface in the live codex pane ($sess:agent)…"
    for _ in $(seq 1 60); do
      if tmux -L "$TMUX_SOCK" capture-pane -p -t "$sess:agent" 2>/dev/null | grep -q "$marker"; then
        echo "codex-smoke: PASS ✅ — 'send' reached the live codex session via resume-seed."; exit 0
      fi
      sleep 2
    done
    echo "codex-smoke: FAIL ❌ — marker not seen within timeout." >&2
    echo "  inspect: scripts/orch-test.sh tmux capture-pane -p -t $sess:agent   ·   scripts/orch-test.sh log" >&2
    exit 1
    ;;
  claude-smoke)
    # END-TO-END: send → live Claude delivery via resume-seed wake. Spawns a REAL claude card, waits for
    # it to go idle (.waiting) AND resumable (transcript found — this is exactly what the canonical-HOME
    # fix above unblocks), `send`s a unique marker, and asserts it surfaces in the live claude pane —
    # proving the idle card woke and drained its inbox. Requires a real `claude` on PATH: USE_REAL_CLAUDE=1.
    # Auth: macOS Claude Code reads its OAuth token from the login Keychain (NOT HOME-scoped), so the
    # throwaway HOME stays authenticated; we also best-effort bridge ~/.claude/.credentials.json for
    # file-based installs (harmless if absent/Keychain-based). Assumes `up` already ran.
    command -v claude >/dev/null 2>&1 || { echo "claude-smoke: no real 'claude' on PATH — run with USE_REAL_CLAUDE=1" >&2; exit 1; }
    mkdir -p "$HOME_DIR/.claude"
    cp "$HOME/.claude/.credentials.json" "$HOME_DIR/.claude/.credentials.json" 2>/dev/null || true
    marker="ORCH-CLAUDE-$$-${RANDOM}"
    echo "claude-smoke: spawning a claude card…"
    ref=$(rpc spawn '{"prompt":"Reply with the single word READY and then stop.","agent":"claude-code","scratch":true}' \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    echo "claude-smoke: card $ref — waiting for it to go idle (.waiting)…"
    for _ in $(seq 1 60); do
      st=$(rpc status "{\"ref\":\"$ref\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task",{}).get("status",""))' 2>/dev/null || true)
      [ "$st" = "waiting" ] && break
      sleep 2
    done
    echo "claude-smoke: idle. sending marker '$marker'…"
    rpc send "{\"ref\":\"$ref\",\"message\":\"$marker\"}" >/dev/null
    sess="orchestra-$(printf '%s' "$ref" | tr 'A-Z' 'a-z')"
    echo "claude-smoke: waiting for the marker to surface in the live claude pane ($sess:agent)…"
    for _ in $(seq 1 60); do
      if tmux -L "$TMUX_SOCK" capture-pane -p -t "$sess:agent" 2>/dev/null | grep -q "$marker"; then
        echo "claude-smoke: PASS ✅ — 'send' reached the live claude session via resume-seed."; exit 0
      fi
      sleep 2
    done
    echo "claude-smoke: FAIL ❌ — marker not seen within timeout." >&2
    echo "  inspect: scripts/orch-test.sh tmux capture-pane -p -t $sess:agent   ·   scripts/orch-test.sh log" >&2
    exit 1
    ;;
  rpc)  rpc "$@" ;;
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
    echo "usage: orch-test.sh {init|up|claude-smoke|codex-smoke|rpc <method> [json]|tmux <args…>|log|down}" >&2
    echo "  AGENT=codex             seed a codex card in init (default: claude-code)" >&2
    echo "  USE_REAL_CLAUDE=1       widen PATH for a genuine claude launch (default: neutralized)" >&2
    echo "  USE_REAL_CODEX=1        widen PATH for a genuine codex launch  (needed for codex-smoke)" >&2
    exit 1 ;;
esac
