#!/usr/bin/env python3
"""Core logic for scripts/check-model-tables.sh.

Reads raw probe output plus the two on-disk model tables and either prints a diff (default) or
rewrites the tables (--write). See notes/designs/2026-09-09-model-table-freshness-design.md for the
full rationale (§3 probes, §4 three-state classification and safety ladder).

Row derivation (Claude), per the design's own algorithm — read the 1M tier, never derive it:
    launch   = row["resolvedModel"]          # "claude-opus-5[1m]"
    id       = launch minus a trailing "[1m]"
    launchId = launch if it carried "[1m]", else absent

One elaboration on the design's terse table: the picker can report a DATED id with no "[1m]" at all
(today, Haiku resolves to "claude-haiku-4-5-20251001"). Passing that straight through as `id` would
re-open the exact bug docs/09 records fixing — a dated id has no floating alias to canonicalize FROM,
so a later dated report can't match it back. So a raw id that extends an EXISTING on-disk id with an
8-digit YYYYMMDD suffix (the same rule OrchestraService+Recovery.isModelVariant already applies at
resolution time) canonicalizes back to that existing id here too, before it ever reaches disk. A
suffix of any OTHER digit count is a version bump (e.g. "claude-opus-5-5" off "claude-opus-5"), not a
date, and gets its own row — see `canonicalize_id`.
"""
import json
import sys


# --- shared helpers ----------------------------------------------------------------------------

def canonicalize_id(raw_id, known_ids):
    """`raw_id` unchanged, UNLESS it is a dated variant (isModelVariant's rule: an existing id plus
    "-" plus an 8-digit YYYYMMDD suffix) of some id already on disk — then the existing floating id
    wins, so a later differently-dated report still canonicalizes back to the SAME row.

    This reimplements OrchestraService+Recovery.isModelVariant in Python (no shared source of truth
    across the two languages is practical here). ASCII digits ONLY, deliberately narrower than either
    language's default "is this character a digit" — Swift's `Character.isNumber` and Python's
    `str.isdigit()` both accept non-ASCII digit forms (e.g. Arabic-indic, superscripts) and disagree
    with each other on some of them. Every real vendor id is ASCII, so pinning both sides to the same
    narrow rule removes the disagreement rather than trying to keep two independently-maintained
    Unicode-aware rules in lockstep.

    The suffix must be exactly 8 digits (a real YYYYMMDD date, like every dated vendor id actually
    is — "claude-haiku-4-5-20251001", "claude-opus-4-1-20250805"). A shorter all-digit suffix is a
    VERSION bump ("claude-opus-5-5" off "claude-opus-5") and must NOT collapse onto the base row —
    it is a genuinely distinct, independently-listed model.
    """
    if raw_id in known_ids:
        return raw_id
    for base in known_ids:
        suffix = raw_id[len(base) + 1:]
        if (raw_id.startswith(base + "-") and len(suffix) == 8
                and all(c in "0123456789" for c in suffix)):
            return base
    return raw_id


def strip_1m(raw):
    return raw[:-4] if raw.endswith("[1m]") else raw


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_claude_picker_models(path):
    """The `initialize` control_response is one JSONL line; its models live two `response` keys deep."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                models = (obj.get("response") or {}).get("response", {}).get("models")
                if models:
                    return models
    except OSError:
        pass
    return None


def load_claude_catalog_models(path):
    doc = load_json(path)
    if not doc:
        return None
    try:
        models = doc["surfaces"]["cc"]["model_selector_config"][0]["models"]
    except (KeyError, IndexError, TypeError):
        return None
    return models or None


def load_codex_models(path):
    doc = load_json(path)
    if not doc:
        return None
    return doc.get("models") or None


# --- Claude --------------------------------------------------------------------------------------

def derive_claude_picker(picker_models, known_ids):
    """id -> {"displayName": <picker's own label>, "launchId": Optional[str]}, plus id ORDER (the
    picker's own order is its recommendation order). A model offered both bare and with [1m] collides
    onto one row after canonicalizing — the [1m] form wins the launchId (PR2's "always 1M" policy)."""
    picker, order = {}, []
    for row in picker_models:
        if row.get("value") == "default" or not row.get("resolvedModel"):
            continue   # "default" duplicates whichever row the vendor currently defaults to
        raw = row["resolvedModel"]
        if raw.endswith("[1m]"):
            cid, launch_id = canonicalize_id(raw[:-4], known_ids), raw
        else:
            cid, launch_id = canonicalize_id(raw, known_ids), None
        if cid not in picker:
            picker[cid] = {"displayName": row.get("displayName"), "launchId": launch_id}
            order.append(cid)
        elif launch_id:
            picker[cid]["launchId"] = launch_id
    return picker, order


def derive_claude_catalog(catalog_models, known_ids):
    """id -> {"section": "main"|"overflow", "name": ...}. `main` wins if an id somehow appears twice."""
    catalog = {}
    for row in catalog_models:
        raw = row.get("id")
        if not raw:
            continue
        cid = canonicalize_id(raw, known_ids)
        if cid not in catalog or (catalog[cid]["section"] == "overflow" and row.get("section") == "main"):
            catalog[cid] = {"section": row.get("section"), "name": row.get("name")}
    return catalog


def claude_catalog_sane(catalog_models, picker_models):
    """Rung-3 gate: the document parses (caller already checked), its `main` section is non-empty,
    and it names EVERY id the picker probe just returned (compared pre-canonicalization — both
    documents publish the same raw, possibly-dated ids; only the [1m] suffix needs stripping)."""
    ids = {row.get("id") for row in catalog_models if row.get("id")}
    if not any(row.get("section") == "main" for row in catalog_models):
        return False
    picker_ids = {strip_1m(row["resolvedModel"]) for row in picker_models
                  if row.get("value") != "default" and row.get("resolvedModel")}
    return picker_ids.issubset(ids)


def make_claude_row(cid, listed, picker_entry, catalog_entry, existing):
    # The published catalog's `name` is already in our exact style ("Opus 5", "Fable 5.1") and is the
    # freshest, most authoritative source — prefer it so a genuine vendor RENAME is picked up on the
    # next --write. `existing` is the fallback for continuity when no catalog entry is available (rung
    # 2, or a demoted row with none). The picker's OWN displayName is deliberately last: it carries
    # transient tier text ("Opus (1M context)", "Default (recommended)"), never a name worth keeping.
    display = ((catalog_entry or {}).get("name") or (existing or {}).get("displayName")
               or (picker_entry or {}).get("displayName") or cid)
    flags = (existing or {}).get("flags") or {"toolCall": True, "reasoning": True, "vision": True}
    row = {"id": cid, "displayName": display, "family": "claude"}
    # A demoted row keeps a KNOWN launchId (from the last time it was probed) — losing it would
    # silently downgrade a still-running card's `--model` re-seat back to the plain 200k tier.
    launch_id = (picker_entry or {}).get("launchId") or (existing or {}).get("launchId")
    if launch_id:
        row["launchId"] = launch_id
    row["flags"] = flags
    row["listed"] = listed
    return row


def build_claude_rows(existing_rows, picker_models, catalog_models):
    existing_by_id = {r["id"]: r for r in existing_rows}
    known_ids = set(existing_by_id)

    if not picker_models:
        return existing_rows, [], "could not verify (no Claude picker probe)"

    picker, order = derive_claude_picker(picker_models, known_ids)
    can_delete = bool(catalog_models) and claude_catalog_sane(catalog_models, picker_models)
    if can_delete:
        rung = "picker + catalog both ok — deletions enabled"
    elif catalog_models:
        rung = "picker ok, catalog FAILED its sanity gate — listed-only, no deletes"
    else:
        rung = "picker ok, no catalog document — listed-only, no deletes"
    catalog_by_id = derive_claude_catalog(catalog_models, known_ids) if catalog_models else {}

    rows, deletions, seen = [], [], set()
    for cid in order:   # every currently-offered id: listed
        seen.add(cid)
        rows.append(make_claude_row(cid, True, picker[cid], catalog_by_id.get(cid), existing_by_id.get(cid)))
    for cid, existing in existing_by_id.items():   # everything else: demote, or delete if confirmed gone
        if cid in seen:
            continue
        if can_delete and cid not in catalog_by_id:
            deletions.append(cid)
            continue
        rows.append(make_claude_row(cid, False, None, catalog_by_id.get(cid), existing))
    return rows, deletions, rung


# --- Codex — one source gives both the picker and the supported set -----------------------------

def build_codex_rows(existing_rows, codex_models):
    existing_by_id = {r["id"]: r for r in existing_rows}
    if not codex_models:
        return existing_rows, [], "could not verify (no Codex probe)"

    by_id = {}
    for row in codex_models:
        cid = row.get("slug")
        # A row Codex reports AT ALL is "known" — visibility other than "list" (including a value this
        # generator has never seen) means demoted, never deletable; only a slug ABSENT from this
        # response is confidently gone. Never equate "unrecognized" with "absent": that would silently
        # delete a row the moment Codex ships a new visibility state, contradicting the safety ladder's
        # whole point (delete only when truly confident).
        if cid:
            by_id[cid] = row

    rows = []
    for cid, row in sorted(by_id.items(), key=lambda kv: kv[1].get("priority", 1_000_000)):
        existing = existing_by_id.get(cid)
        display = (existing or {}).get("displayName") or row.get("display_name") or cid
        flags = (existing or {}).get("flags") or {
            "toolCall": True, "reasoning": bool(row.get("supported_reasoning_levels")), "vision": True}
        out = {"id": cid, "displayName": display, "family": "gpt"}
        window = row.get("context_window") or (existing or {}).get("contextWindow")
        if window:
            out["contextWindow"] = window
        out["flags"] = flags
        out["listed"] = row.get("visibility") == "list"
        rows.append(out)

    deletions = [cid for cid in existing_by_id if cid not in by_id]
    # Codex's single command supplies BOTH sets at once, so there is no listed-only rung here: a
    # successful probe is always rung 3 (deletions enabled) for Codex.
    return rows, deletions, "codex probe ok (single source for both sets)"


# --- reporting -------------------------------------------------------------------------------

def summarize(name, old_rows, new_rows, deletions, rung):
    old_by_id = {r["id"]: r for r in old_rows}
    new_by_id = {r["id"]: r for r in new_rows}
    added = [i for i in new_by_id if i not in old_by_id]
    flipped = [i for i in new_by_id if i in old_by_id
               and bool(old_by_id[i].get("listed", True)) != bool(new_by_id[i].get("listed", True))]
    launch_changed = [i for i in new_by_id if i in old_by_id
                      and old_by_id[i].get("launchId") != new_by_id[i].get("launchId")]
    lines = [f"{name}: {rung}"]
    if not added and not flipped and not deletions and not launch_changed:
        lines.append("  in sync")
        return lines, False
    for i in added:
        tag = "listed" if new_by_id[i].get("listed", True) else "demoted, still runnable"
        lines.append(f"  + add      {i}  ({tag})")
    for i in flipped:
        now = new_by_id[i].get("listed", True)
        lines.append(f"  ~ {'promote' if now else 'demote '}  {i}")
    for i in launch_changed:
        old_lid, new_lid = old_by_id[i].get("launchId"), new_by_id[i].get("launchId")
        lines.append(f"  ~ launchId {i}  {old_lid!r} -> {new_lid!r}")
    for i in deletions:
        lines.append(f"  - DELETE   {i}  (absent from picker AND the known-supported set)")
    return lines, True


def main():
    # argv contract (see check-model-tables.sh):
    #   [--write] <claude.json> <codex.json> <claude-picker.out> <claude-catalog.json> <codex-probe.json>
    write = "--write" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--write"]
    claude_json_path, codex_json_path, claude_picker_path, claude_catalog_path, codex_probe_path = args

    existing_claude = load_json(claude_json_path) or []
    existing_codex = load_json(codex_json_path) or []

    picker_models = load_claude_picker_models(claude_picker_path)
    catalog_models = load_claude_catalog_models(claude_catalog_path)
    codex_models = load_codex_models(codex_probe_path)

    # Each side degrades to "could not verify" on ANY unexpected exception — a probe response shape the
    # generator did not anticipate (a schema drift in a document neither side controls) must never
    # propagate into a nonzero exit and fail the merge gate. Independent try/except per agent: a bug
    # processing Codex's probe must not also blank out Claude's real, valid report.
    try:
        new_claude, claude_del, claude_rung = build_claude_rows(existing_claude, picker_models, catalog_models)
    except Exception as exc:   # noqa: BLE001 - deliberately broad; see comment above
        new_claude, claude_del, claude_rung = existing_claude, [], f"could not verify (unexpected error: {exc})"
    try:
        new_codex, codex_del, codex_rung = build_codex_rows(existing_codex, codex_models)
    except Exception as exc:   # noqa: BLE001 - deliberately broad; see comment above
        new_codex, codex_del, codex_rung = existing_codex, [], f"could not verify (unexpected error: {exc})"

    claude_lines, claude_changed = summarize("claude-code-models.json", existing_claude, new_claude,
                                              claude_del, claude_rung)
    codex_lines, codex_changed = summarize("codex-models.json", existing_codex, new_codex,
                                            codex_del, codex_rung)
    print("\n".join(claude_lines))
    print("\n".join(codex_lines))

    if write:
        if picker_models:   # rung 1 leaves the file untouched — never write "could not verify" data
            with open(claude_json_path, "w") as f:
                json.dump(new_claude, f, indent=2)
                f.write("\n")
        if codex_models:
            with open(codex_json_path, "w") as f:
                json.dump(new_codex, f, indent=2)
                f.write("\n")
    # Diff mode never fails the build (§ design: a stale table is noticed and fixed with --write, not
    # a merge-gate failure) — this script has no network/vendor-CLI guarantee on every machine.
    return 0


if __name__ == "__main__":
    sys.exit(main())
