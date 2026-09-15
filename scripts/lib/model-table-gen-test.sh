#!/bin/bash
# Tests for scripts/lib/model-table-gen.py — the check-model-tables.sh core logic.
#
# Every case is captured/derived probe JSON on disk: nothing here forks `claude`/`codex` or needs
# network, which is the point — this pins the DERIVATION logic (safety ladder, 1M launchId, dated-id
# canonicalization, three-state classification), not the CLIs themselves.
#
# Usage: scripts/lib/model-table-gen-test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
GEN="scripts/lib/model-table-gen.py"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3' in: $2)"; fi; }

# Private per-run dir under the repo's gitignored .scratch/, never $TMPDIR — see ios-pick-device-test.sh.
SCRATCH="$(mkdir -p .scratch && mktemp -d .scratch/model-table-gen-test.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

listed() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])))" "$1"; }
field() {  # $1=json-file $2=id $3=field -> that row's field, or "MISSING"
  python3 -c "
import json, sys
rows = json.load(open(sys.argv[1]))
row = next((r for r in rows if r['id'] == sys.argv[2]), None)
print('MISSING' if row is None else row.get(sys.argv[3], 'ABSENT'))
" "$1" "$2" "$3"
}

# --- fixtures -----------------------------------------------------------------------------------
# A trimmed but real-shaped `initialize` control_response, one JSONL line, matching a 2026-09-13
# capture of `claude -p --bare --input-format stream-json --output-format stream-json`.
picker() {  # writes a picker probe carrying the rows named in $@ (from the table below)
  local rows="" first=1
  for name in "$@"; do
    case "$name" in
      default)  row='{"value":"default","resolvedModel":"claude-opus-5[1m]","displayName":"Default"}' ;;
      opus1m)   row='{"value":"opus[1m]","resolvedModel":"claude-opus-5[1m]","displayName":"Opus (1M context)"}' ;;
      fable1m)  row='{"value":"fable[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable"}' ;;
      sonnet)   row='{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet"}' ;;
      sonnet1m) row='{"value":"sonnet[1m]","resolvedModel":"claude-sonnet-5[1m]","displayName":"Sonnet (1M)"}' ;;
      haiku)    row='{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku"}' ;;
    esac
    [[ $first == 1 ]] && first=0 || rows+=","
    rows+="$row"
  done
  printf '{"type":"control_response","response":{"response":{"models":[%s]}}}\n' "$rows"
}
catalog_doc() {  # writes a published-catalog doc; $@ = "id:section" pairs for surfaces.cc's models[]
  local rows="" first=1
  for pair in "$@"; do
    local id="${pair%%:*}" section="${pair##*:}"
    [[ $first == 1 ]] && first=0 || rows+=","
    rows+="{\"id\":\"$id\",\"name\":\"n\",\"section\":\"$section\"}"
  done
  printf '{"surfaces":{"cc":{"model_selector_config":[{"models":[%s]}]}}}\n' "$rows"
}
codex_probe() {  # $@ = "slug:visibility:priority" triples
  local rows="" first=1
  for triple in "$@"; do
    IFS=: read -r slug vis prio <<< "$triple"
    [[ $first == 1 ]] && first=0 || rows+=","
    rows+="{\"slug\":\"$slug\",\"display_name\":\"$slug\",\"visibility\":\"$vis\",\"priority\":$prio,\"context_window\":111000}"
  done
  printf '{"models":[%s]}\n' "$rows"
}
existing_claude() {  # $@ = ids currently on disk, each a full row with a distinctive displayName
  local rows="" first=1
  for id in "$@"; do
    [[ $first == 1 ]] && first=0 || rows+=","
    rows+="{\"id\":\"$id\",\"displayName\":\"Existing $id\",\"family\":\"claude\",\"flags\":{\"toolCall\":true,\"reasoning\":true,\"vision\":true}}"
  done
  printf '[%s]\n' "$rows"
}
empty_file() { : > "$1"; }

run_gen() {  # $1=write(0/1) $2=claude.json $3=codex.json $4=picker $5=catalog $6=codex-probe
  local w=(); [[ "$1" == 1 ]] && w=(--write)
  python3 "$GEN" ${w[@]+"${w[@]}"} "$2" "$3" "$4" "$5" "$6"
}

echo "1. rung 1 — nothing probes: unchanged, reports 'could not verify'"
existing_claude claude-opus-5 > "$SCRATCH/c1.json"
empty_file "$SCRATCH/codex1.json"
before="$(cat "$SCRATCH/c1.json")"
empty_file "$SCRATCH/picker-empty"; empty_file "$SCRATCH/catalog-empty"; empty_file "$SCRATCH/codexprobe-empty"
out="$(run_gen 1 "$SCRATCH/c1.json" "$SCRATCH/codex1.json" "$SCRATCH/picker-empty" "$SCRATCH/catalog-empty" "$SCRATCH/codexprobe-empty")"
contains "reports could-not-verify" "$out" "could not verify"
check "file untouched" "$(cat "$SCRATCH/c1.json")" "$before"

echo "2. rung 2 — picker ok, catalog empty: demotes, NEVER deletes"
existing_claude claude-opus-5 claude-haiku-4-5 > "$SCRATCH/c2.json"
picker opus1m > "$SCRATCH/picker2"   # haiku no longer offered
empty_file "$SCRATCH/catalog2"
out="$(run_gen 1 "$SCRATCH/c2.json" "$SCRATCH/codex1.json" "$SCRATCH/picker2" "$SCRATCH/catalog2" "$SCRATCH/codexprobe-empty")"
contains "reports listed-only, no deletes" "$out" "no deletes"
check "haiku demoted, not deleted" "$(field "$SCRATCH/c2.json" claude-haiku-4-5 listed)" "False"
check "haiku keeps its existing displayName" "$(field "$SCRATCH/c2.json" claude-haiku-4-5 displayName)" "Existing claude-haiku-4-5"

echo "3. rung 2 — picker ok, catalog FAILS its sanity gate (missing a picker id): still no deletes"
existing_claude claude-opus-5 claude-sonnet-5 > "$SCRATCH/c3.json"
picker opus1m sonnet > "$SCRATCH/picker3"
catalog_doc claude-opus-5:main > "$SCRATCH/catalog3"   # missing sonnet, which the picker just returned
out="$(run_gen 1 "$SCRATCH/c3.json" "$SCRATCH/codex1.json" "$SCRATCH/picker3" "$SCRATCH/catalog3" "$SCRATCH/codexprobe-empty")"
contains "sanity gate failure reported" "$out" "FAILED its sanity gate"
check "sonnet demoted (not offered), not deleted" "$(field "$SCRATCH/c3.json" claude-sonnet-5 listed)" "True"

echo "4. rung 3 — both ok, sanity passes: a genuinely-gone id is DELETED, but only with --write"
existing_claude claude-opus-5 claude-retired-fake > "$SCRATCH/c4.json"
picker opus1m > "$SCRATCH/picker4"
catalog_doc claude-opus-5:main > "$SCRATCH/catalog4"
out="$(run_gen 0 "$SCRATCH/c4.json" "$SCRATCH/codex1.json" "$SCRATCH/picker4" "$SCRATCH/catalog4" "$SCRATCH/codexprobe-empty")"
contains "deletion reported loudly" "$out" "DELETE   claude-retired-fake"
check "diff mode (no --write) never mutates the file" "$(field "$SCRATCH/c4.json" claude-retired-fake id)" "claude-retired-fake"
run_gen 1 "$SCRATCH/c4.json" "$SCRATCH/codex1.json" "$SCRATCH/picker4" "$SCRATCH/catalog4" "$SCRATCH/codexprobe-empty" >/dev/null
check "--write actually deletes the row" "$(field "$SCRATCH/c4.json" claude-retired-fake listed)" "MISSING"
check "the surviving row is untouched" "$(field "$SCRATCH/c4.json" claude-opus-5 id)" "claude-opus-5"

echo "5. the 1M launchId: read from the [1m] suffix, never derived; a bare+[1m] collision keeps one row"
existing_claude > "$SCRATCH/c5.json"
picker opus1m fable1m sonnet1m sonnet default > "$SCRATCH/picker5"
run_gen 1 "$SCRATCH/c5.json" "$SCRATCH/codex1.json" "$SCRATCH/picker5" "$SCRATCH/catalog-empty" "$SCRATCH/codexprobe-empty" >/dev/null
check "opus gets the [1m] launchId" "$(field "$SCRATCH/c5.json" claude-opus-5 launchId)" "claude-opus-5[1m]"
check "fable (already 1M) gets no launchId" "$(field "$SCRATCH/c5.json" claude-fable-5-1 launchId)" "ABSENT"
check "sonnet+sonnet[1m] collide onto ONE row" \
  "$(python3 -c "import json; print(len([r for r in json.load(open('$SCRATCH/c5.json')) if r['id']=='claude-sonnet-5']))")" "1"
check "…and the collision keeps the [1m] form as launchId" "$(field "$SCRATCH/c5.json" claude-sonnet-5 launchId)" "claude-sonnet-5[1m]"
check "'default' is skipped as a picker row (no fifth entry)" \
  "$(python3 -c "import json; print(len(json.load(open('$SCRATCH/c5.json'))))")" "3"

echo "6. a dated resolvedModel with NO [1m] canonicalizes back to its known floating id"
existing_claude claude-haiku-4-5 > "$SCRATCH/c6.json"
picker haiku > "$SCRATCH/picker6"
run_gen 1 "$SCRATCH/c6.json" "$SCRATCH/codex1.json" "$SCRATCH/picker6" "$SCRATCH/catalog-empty" "$SCRATCH/codexprobe-empty" >/dev/null
check "the dated id resolves to the EXISTING floating row, not a new one" \
  "$(field "$SCRATCH/c6.json" claude-haiku-4-5 listed)" "True"
check "no stray dated row was added" \
  "$(python3 -c "import json; print(len(json.load(open('$SCRATCH/c6.json'))))")" "1"

echo "7. Codex — one probe gives all three states in a single command"
existing_claude > "$SCRATCH/c7.json"   # unused by this case; the harness always takes both paths
python3 -c "
import json
rows = [{'id':'gpt-a','displayName':'A','family':'gpt','flags':{'toolCall':True,'reasoning':True,'vision':True}},
        {'id':'gpt-c','displayName':'C','family':'gpt','flags':{'toolCall':True,'reasoning':True,'vision':True}},
        {'id':'gpt-gone','displayName':'Gone','family':'gpt','flags':{'toolCall':True,'reasoning':True,'vision':True}}]
json.dump(rows, open('$SCRATCH/codex7.json','w'))
"
# gpt-c reports an UNRECOGNIZED visibility (neither list nor hide) — a future Codex state this
# generator has never seen. gpt-gone is absent from the probe entirely -> deletable.
codex_probe "gpt-a:list:1" "gpt-b:hide:2" "gpt-c:beta:3" > "$SCRATCH/codexprobe7"
out="$(run_gen 1 "$SCRATCH/c7.json" "$SCRATCH/codex7.json" "$SCRATCH/picker-empty" "$SCRATCH/catalog-empty" "$SCRATCH/codexprobe7")"
contains "codex reports its single-source rung" "$out" "single source for both sets"
check "listed slug stays listed" "$(field "$SCRATCH/codex7.json" gpt-a listed)" "True"
check "hide slug is demoted, still resolvable" "$(field "$SCRATCH/codex7.json" gpt-b listed)" "False"
check "UNRECOGNIZED visibility is demoted too, never treated as absent" "$(field "$SCRATCH/codex7.json" gpt-c listed)" "False"
check "absent slug is deleted" "$(field "$SCRATCH/codex7.json" gpt-gone listed)" "MISSING"

echo "8. an unexpected probe shape must degrade to 'could not verify', never crash the merge gate"
existing_claude claude-opus-5 > "$SCRATCH/c8.json"
before8="$(cat "$SCRATCH/c8.json")"
picker opus1m > "$SCRATCH/picker8"
# A catalog document whose `models` list holds a non-object entry — the published document is fetched
# over the network and its shape is not a contract either side controls.
printf '{"surfaces":{"cc":{"model_selector_config":[{"models":["not-an-object"]}]}}}' > "$SCRATCH/catalog8"
rc=0
out="$(run_gen 0 "$SCRATCH/c8.json" "$SCRATCH/codex1.json" "$SCRATCH/picker8" "$SCRATCH/catalog8" "$SCRATCH/codexprobe-empty")" || rc=$?
check "the generator itself still exits 0" "$rc" "0"
contains "reports could-not-verify, not a traceback" "$out" "could not verify"
check "the file is untouched" "$(cat "$SCRATCH/c8.json")" "$before8"

echo "9. a genuine vendor RENAME (the published catalog's clean name) refreshes displayName"
python3 -c "
import json
json.dump([{'id':'claude-opus-5','displayName':'Old Stale Name','family':'claude',
            'flags':{'toolCall':True,'reasoning':True,'vision':True}}], open('$SCRATCH/c9.json','w'))
"
picker opus1m > "$SCRATCH/picker9"
python3 -c "
import json
doc = {'surfaces':{'cc':{'model_selector_config':[{'models':[
  {'id':'claude-opus-5','name':'Opus 5.1 Renamed','section':'main'}]}]}}}
json.dump(doc, open('$SCRATCH/catalog9.json','w'))
"
run_gen 1 "$SCRATCH/c9.json" "$SCRATCH/codex1.json" "$SCRATCH/picker9" "$SCRATCH/catalog9.json" "$SCRATCH/codexprobe-empty" >/dev/null
check "displayName picks up the catalog's fresh name, not the stale existing one" \
  "$(field "$SCRATCH/c9.json" claude-opus-5 displayName)" "Opus 5.1 Renamed"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL == 0 ]]
