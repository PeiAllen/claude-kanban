#!/bin/bash
# fake-agent.sh — stands in for `claude` in integration tests (no real Claude is ever spawned).
#
# Behaviours the tests rely on:
#   * Honors `--session-id <uuid>`: writes a stub transcript at
#       $HOME/.claude/projects/<cwd-slug>/<uuid>.jsonl   (cwd-slug = abs cwd with '/' -> '-')
#     so Adapter.sessionInfo (assigned + fallback paths) has a transcript to find.
#   * Honors `--resume <uuid>`: exits non-zero if that transcript is ABSENT (models claude's
#     "No conversation found" -> drives the .dead path); when present, fires a SessionStart(resume)
#     callback via `orchestra _report --event session` so the recovery success path is exercised.
#   * Bumps a launch counter ($ORCHESTRA_FAKE_COUNTER) so a test can assert peak concurrent launches.
#   * Then echoes stdin in a loop so the tmux window stays alive like a real interactive agent.

session_id=""
resume_id=""
name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) session_id="$2"; shift 2 ;;
    --resume)     resume_id="$2";  shift 2 ;;
    --name|-n)    name="$2";       shift 2 ;;
    --settings|--model) shift 2 ;;
    *) shift ;;
  esac
done

cwd="$(pwd -P)"
slug="${cwd//\//-}"
proj="$HOME/.claude/projects/$slug"

if [[ -n "$ORCHESTRA_FAKE_COUNTER" ]]; then
  # naive atomic-ish increment for the throttle assertion
  echo "x" >> "$ORCHESTRA_FAKE_COUNTER"
fi

if [[ -n "$resume_id" ]]; then
  if [[ ! -f "$proj/$resume_id.jsonl" ]]; then
    echo "No conversation found for session $resume_id" >&2
    exit 1
  fi
  # Fire the SessionStart(resume) callback the daemon waits for.
  if command -v orchestra >/dev/null 2>&1; then
    printf '{"source":"resume","session_id":"%s","transcript_path":"%s","cwd":"%s"}' \
      "$resume_id" "$proj/$resume_id.jsonl" "$cwd" | orchestra _report --event session >/dev/null 2>&1 || true
  fi
  session_id="$resume_id"
fi

if [[ -n "$session_id" ]]; then
  mkdir -p "$proj"
  printf '{"type":"session","session_id":"%s","cwd":"%s","name":"%s"}\n' \
    "$session_id" "$cwd" "$name" > "$proj/$session_id.jsonl"
fi

echo "fake-agent up (session=$session_id name=$name)"
# Stay alive, echoing input, until the window is killed.
while IFS= read -r line; do
  echo "you said: $line"
done
