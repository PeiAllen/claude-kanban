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
server_pid=

cleanup() {
  if [[ -n ${server_pid:-} ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$socket_path"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$(dirname "$socket_path")"
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
