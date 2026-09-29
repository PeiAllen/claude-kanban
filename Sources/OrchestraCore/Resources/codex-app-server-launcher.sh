#!/bin/bash

# Keep one launch-local Codex app-server alive for the stock TUI and Orchestra's passive observer.
# Every value arrives as its own argv element; this script never evaluates provider arguments as shell.

set -u
umask 077

if (( $# < 5 )); then
  exit 64
fi

socket_path=$1
log_path=$2
server_count=$3
shift 3

if ! [[ $server_count =~ ^[0-9]+$ ]] || (( server_count == 0 || $# <= server_count )); then
  exit 64
fi

server_argv=("${@:1:server_count}")
shift "$server_count"
client_argv=("$@")

# The socket pathname is stable across an Orchestra handoff, so the old launcher must finish its
# complete teardown before a replacement can remove or recreate that pathname. Keep the lock file
# itself after exit: lockf's advisory lock is on the inode, and removing it would let a new launcher
# create a different inode while the old launcher still owns the original lock.
mkdir -p "$(dirname "$socket_path")"
lock_path="${socket_path}.lock"
exec 9>"$lock_path"
if /usr/bin/lockf -t 30 9; then
  :
else
  lock_status=$?
  exit "$lock_status"
fi

server_pid=

cleanup() {
  if [[ -n ${server_pid:-} ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$socket_path"
  exec 9>&-
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -f "$socket_path"
: > "$log_path"

"${server_argv[@]}" >>"$log_path" 2>&1 &
server_pid=$!

for (( attempt = 0; attempt < 200; attempt += 1 )); do
  if [[ -S $socket_path ]]; then
    "${client_argv[@]}"
    exit $?
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid"
    exit $?
  fi
  sleep 0.05
done

exit 70
