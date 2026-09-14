#!/bin/bash
# Diff (default) or rewrite (--write) the two vendored model tables against a live probe of each
# CLI's own model catalog. See notes/designs/2026-09-09-model-table-freshness-design.md (§3, §4).
#
# Two probes, both offline and free, plus one network fetch used only to enable deletion:
#   Claude picker set:    the `initialize` control_response's models[] (stream-json, --bare; no API call)
#   Claude supported set: the published model-catalog document (NETWORK; only gates deletions)
#   Codex, both sets:     `codex debug models --bundled` (offline; visibility: list/hide/absent)
#
# Safety ladder — each rung strictly weaker than the one above; the generator (model-table-gen.py)
# degrades down it on its own, per agent:
#   1. nothing probes                  -> report "could not verify", change nothing
#   2. picker probe ok, catalog not ok -> update `listed` flags only, NEVER delete
#   3. both ok AND the catalog document passes a sanity gate -> deletions enabled too
#
# `--write` rewrites the tables. Without it, this only PRINTS a diff — and always exits 0: a stale
# table is a thing to notice and fix with `--write`, not a merge-gate failure. This machine's own
# `claude`/`codex` binaries and network access are not guaranteed on every machine that runs the
# merge gate, so a probe failure here must never look like a broken build.
set -euo pipefail
cd "$(dirname "$0")/.."

WRITE_FLAG=()
[[ "${1:-}" == "--write" ]] && WRITE_FLAG=(--write)

if ! command -v python3 >/dev/null 2>&1; then
  echo "check-model-tables: no python3 on PATH — could not verify" >&2
  exit 0
fi

# A private per-run dir under the repo's gitignored .scratch/, NEVER a bare `mktemp -d`: plain
# `mktemp -d` resolves against macOS's Darwin user temp dir (not `$TMPDIR`), which an agent sandbox
# denies writing to — this script must run cleanly from inside one. See ios-pick-device-test.sh for
# the same precedent. If even `.scratch/` can't be created, degrade like every other probe failure.
if ! mkdir -p .scratch || ! TMP="$(mktemp -d .scratch/check-model-tables.XXXXXX)"; then
  echo "check-model-tables: could not create a scratch dir — could not verify" >&2
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# Claude picker set (offline, ~1s, zero tokens — reads the CLI's embedded seed).
: > "$TMP/claude-picker.out"
if command -v claude >/dev/null 2>&1; then
  printf '%s\n' '{"type":"control_request","request_id":"r1","request":{"subtype":"initialize"}}' \
    | CLAUDE_CODE_MODEL_CATALOG=0 claude -p --verbose --bare \
        --input-format stream-json --output-format stream-json \
        > "$TMP/claude-picker.out" 2>/dev/null || true
fi

# Claude supported set — network, and only ever gates deletions (rung 3). Its own staleness between
# fetches (the design doc measured 9 → 10 models in 3 days) is exactly what the sanity gate guards.
: > "$TMP/claude-catalog.json"
curl -fsSL --max-time 10 https://downloads.claude.ai/model-catalog/v1/catalog.json \
  -o "$TMP/claude-catalog.json" 2>/dev/null || true

# Codex: one offline command gives BOTH sets (visibility: list = picker, hide = demoted, absent = gone).
: > "$TMP/codex-probe.json"
if command -v codex >/dev/null 2>&1; then
  codex debug models --bundled > "$TMP/codex-probe.json" 2>/dev/null || true
fi

# The generator catches its own per-agent exceptions and always exits 0 (see model-table-gen.py's
# main()). This guard is defense in depth for the one failure that isn't the generator's to catch —
# python3 itself missing or broken — so a bad interpreter never fails the merge gate either.
python3 scripts/lib/model-table-gen.py ${WRITE_FLAG[@]+"${WRITE_FLAG[@]}"} \
  Sources/OrchestraCore/Resources/claude-code-models.json \
  Sources/OrchestraCore/Resources/codex-models.json \
  "$TMP/claude-picker.out" "$TMP/claude-catalog.json" "$TMP/codex-probe.json" || {
  echo "check-model-tables: generator failed unexpectedly — could not verify" >&2
  exit 0
}
