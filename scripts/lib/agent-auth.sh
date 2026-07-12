#!/usr/bin/env bash
#
# agent-auth.sh — real, authenticated agents for every ISOLATED Orchestra harness (docs-shots.sh,
# iso-stack.sh, orch-test.sh, the e2e scripts…).
#
# THE PROBLEM
#   Every isolated harness steers by $HOME — that IS the isolation contract: the daemon's socket, its
#   data dir, and the app's client path all derive from it, so an isolated $HOME can't collide with
#   the live stack. But on macOS, Claude Code keeps its OAuth credentials in the **login Keychain**,
#   and macOS resolves the login keychain through $HOME/Library/Keychains. Override $HOME and:
#
#     • `claude` finds no credentials            → "Not logged in". The agent sits at a login prompt
#       forever while the board cheerfully reports the card "running" — a silent, total failure that
#       looks like a working run. (This is real: it quietly produced entire sets of empty
#       screenshots, and every past USE_REAL_CLAUDE=1 run was affected.)
#     • macOS finds no keychain at that path     → a MODAL "Keychain Not Found — a keychain cannot be
#       found to store <user>" dialog, once per agent launch, on the user's screen.
#
#   Note `~/.claude/.credentials.json` is a red herring on macOS: it is the Linux/Windows credential
#   store, not the source of truth here (https://code.claude.com/docs/en/authentication.md). Copying
#   it between homes does NOT work — and worse, the OAuth refresh token rotates, so a copy
#   authenticates once and then 401s for *everyone*, including the original home.
#
# THE FIX
#   Give the isolated $HOME a Keychains directory that IS the real one, by symlink. `claude` then
#   finds the ordinary login keychain and authenticates exactly as it does in everyday interactive
#   use — no new credential, no minted token, no keychain dialog, nothing to expire. The isolated
#   agents get precisely the access a normal (non-isolated) agent on this Mac already has; the
#   symlink is a path fix, not a privilege grant. Teardown's `rm -rf` removes the symlink, never the
#   target.
#
# USAGE (from a harness)
#   source "$(dirname "$0")/lib/agent-auth.sh"
#   agent_auth_require            # hard-gate: refuse to run agents that cannot authenticate
#   agent_auth_seed "$ISO_HOME"   # keychain symlink + codex auth into this run's throwaway home
#
# USAGE (from a human)
#   scripts/agent-auth.sh status  # can an isolated agent actually authenticate right now?
set -uo pipefail

# Make an isolated $HOME able to reach the real login keychain.
agent_auth_link_keychain() {
  local iso_home="$1"
  mkdir -p "$iso_home/Library"
  # Only if it isn't already linked/present — never clobber, never copy.
  if [[ ! -e "$iso_home/Library/Keychains" ]]; then
    ln -s "$HOME/Library/Keychains" "$iso_home/Library/Keychains"
  fi
}

# Can a Claude agent in an isolated $HOME actually authenticate? Ask `claude` and require a POSITIVE
# answer.
#
# Match every way auth can fail, not just the obvious one: a dead credential does NOT say "Not logged
# in" — it says "Failed to authenticate. API Error: 401 Invalid authentication credentials". An
# earlier version of this check matched only "Not logged in", so a broken auth passed the gate as
# healthy and two full capture runs went ahead with agents that could not make a single API call. A
# health check that can report a broken thing as working is worse than no health check at all.
agent_auth_ok() {
  command -v claude >/dev/null 2>&1 || return 1
  local probe out
  probe="$(mktemp -d)"
  agent_auth_link_keychain "$probe"
  out="$(HOME="$probe" claude -p "reply with exactly: OK" 2>&1 | head -5)"
  rm -rf "$probe"
  case "$out" in
    *"Not logged in"*|*"/login"*|*"401"*|*"Failed to authenticate"*|*"Invalid authentication"*)
      return 1 ;;
  esac
  [[ "$out" == *"OK"* ]]
}

agent_auth_status() {
  command -v claude >/dev/null 2>&1 || { echo "claude: NOT on PATH"; return 1; }
  if agent_auth_ok; then
    echo "claude: an isolated agent CAN authenticate (real login keychain, via symlink)"
  else
    echo "claude: an isolated agent CANNOT authenticate"
    echo "  → check you are logged in normally:  claude  (then /login)"
  fi
  if [[ -f "$HOME/.codex/auth.json" ]]; then
    echo "codex : ~/.codex/auth.json present (bridged into each run)"
  else
    echo "codex : no ~/.codex/auth.json — codex cards would stall on login"
  fi
}

# Prepare a run's throwaway $HOME so its agents are authenticated.
agent_auth_seed() {
  local iso_home="$1"
  mkdir -p "$iso_home/.claude"
  agent_auth_link_keychain "$iso_home"

  # Codex authenticates from a plain file — just bridge it.
  if [[ -f "$HOME/.codex/auth.json" ]]; then
    mkdir -p "$iso_home/.codex"
    cp "$HOME/.codex/auth.json" "$iso_home/.codex/auth.json"
  fi
  return 0
}

# Hard gate for harnesses that are pointless without working agents.
agent_auth_require() {
  if ! agent_auth_ok; then
    cat >&2 <<'EOF'

  ✗ A Claude agent in an isolated $HOME cannot authenticate right now, so every Claude card would
    sit at a login prompt while the board reported it "running", and the run would capture nothing.

    Check that you are logged in normally first (in your real shell):

      claude        # then /login if needed

    Isolated runs reach that same login keychain by symlink — they mint no token of their own.

EOF
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-status}" in
    status) agent_auth_status ;;
    login)  echo "No separate login needed: isolated runs use your normal Claude login (keychain symlink)."
            echo "If agents can't authenticate, log in normally in your own shell:  claude → /login"
            agent_auth_status ;;
    *) echo "usage: agent-auth.sh {status}" >&2; exit 2 ;;
  esac
fi
