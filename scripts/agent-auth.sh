#!/usr/bin/env bash
# agent-auth.sh — thin CLI over scripts/lib/agent-auth.sh.
#
#   scripts/agent-auth.sh status   can an agent in an ISOLATED $HOME authenticate right now?
#
# There is no separate login to perform. On macOS, Claude Code keeps its credentials in the login
# KEYCHAIN, which macOS resolves via $HOME/Library/Keychains — so an isolated $HOME (which every test
# harness uses, and deletes on teardown) can't see them, and `claude` reports "Not logged in" while
# macOS pops a modal "Keychain Not Found" dialog per agent. The harnesses symlink the real Keychains
# directory into each run's throwaway home, so isolated agents authenticate with your ORDINARY login.
# If this reports a failure, just make sure you're logged in normally:  claude  → /login
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/agent-auth.sh
case "${1:-status}" in
  status|login) agent_auth_status ;;
  *) echo "usage: scripts/agent-auth.sh status" >&2; exit 2 ;;
esac
