# Open Notes → the card's worktree, jumped to its changed notes

**Status:** designed (2026-07-03)
**Card:** `d07c2e` (fix-open-notes)

## Problem

The inspector's **Open notes** button opens `<t.repo>/notes` — the **main project
root**, not the card's worktree. For a worktree card that means Obsidian shows main's
pristine `notes/`, which does **not** contain the notes/docs/skills the card just
changed (those live unmerged in the worktree). So it reads as "opening the wrong repo,"
and there's no way to jump straight to the notes this card actually touched.

Confirmed with the user: the observed "wrong repo" is exactly *opens main, not worktree*.

## Goal

Retarget Open Notes to the **card's worktree** (`t.cwd`), open the worktree root as the
Obsidian vault, and open the markdown files **this card changed** directly as tabs so the
user lands on them without browsing the tree.

Behavior contract:

- Always open the worktree root as the vault.
- Open each changed `.md` file as a tab (capped — see below).
- If nothing changed (or the card isn't a git worktree, e.g. a scratch card): open the
  vault with **no tabs**. Never error, never fall back to main.

## Why the worktree root is the vault

Obsidian's `obsidian://open?path=<file>` only opens a file that lives inside a
**registered vault**. The card's changed notes span multiple top-level dirs —
`docs/` (incl. `docs/superpowers/` specs), `notes/`, and `.claude/skills/*.md`
("superpower notes") — so for one vault to contain all of them, the vault root must be
the worktree itself. The user accepted this trade-off; we open the changed files directly
as tabs so the whole-tree vault is never actually browsed.

## Design

### 1. `Launcher.openNotes` — retarget (rename param `repo` → `worktree`)

```
func openNotes(_ worktree: String) throws  // was openNotes(_ repo: String)
```

- `assertAllowed(worktree)`.
- Run the same `~/.claude/open-obsidian-vault.sh <worktree>` recipe as today — now on the
  worktree root. Its register/restart-when-new logic is unchanged; for the empty-changes
  case this alone satisfies "open the vault, no tabs."
- Compute changed notes (helper below). For each absolute path (up to the cap), fire
  `open "obsidian://open?path=<url-encoded abs path>"`. Obsidian resolves the containing
  vault (the one just registered) and opens the file as a tab.
- Return the number of tabs opened (for the toast).

Ordering: run the script first (registers + opens the vault, and covers the empty case),
then fire the per-file URIs.

### 2. New `Launcher.changedNotes(worktree:) -> [String]`

Reuses the **existing** private helpers `mergeBase(worktree:)` and
`changedFiles(worktree:base:)` — the same branch-vs-base baseline the Zed "View changes"
diff uses, so the notes opened and the diff shown always agree.

```
func changedNotes(worktree: String) -> [String] {
    guard let base = mergeBase(worktree: worktree) else { return [] }   // non-git / no base
    return changedFiles(worktree: worktree, base: base)
        .filter { $0.status != .deleted }                 // can't open a deleted file
        .map { $0.newPath }
        .filter { $0.lowercased().hasSuffix(".md") }
        .map { (worktree as NSString).appendingPathComponent($0) }
}
```

`changedFiles` already unions tracked changes (`git diff --name-status`) with untracked,
non-ignored files (`git ls-files --others --exclude-standard`), so freshly created,
un-`git add`ed notes are included.

### 3. Tab cap

Open at most **15** tabs; if more `.md` files changed, open the first 15 and let the vault
tree hold the rest. `openNotes` returns both `opened` (tabs opened, ≤15) and `total`
(changed `.md` count) so the toast can signal truncation. Rationale: a card that touched
many markdown files shouldn't flood Obsidian with dozens of tabs.

### 4. Root `.gitignore`: add `.obsidian/` (one-time, tracked/committed)

Because the vault is now the worktree root, the script creates `<worktree>/.obsidian/`.
Committing `.obsidian/` to the tracked root `.gitignore` once means:

- Obsidian's config folder never appears in any card's diff (`changedFiles` respects
  `--exclude-standard`), so it can't pollute "View changes" or be accidentally committed.
- The shared script's own `.gitignore`-append step becomes a **no-op** (`grep -qxF`
  finds `.obsidian/` already present), so **no tracked file is modified at open time** and
  the global script needs no changes.

Only `.obsidian/` is added — not `.trash/`. `.trash/` is Obsidian's in-vault trash, created
only under the non-default "Move to Obsidian trash" setting; the seeded template
(`~/.claude/obsidian-template/app.json`) doesn't set it, so `.trash/` is never created.
Adding it later is trivial if that setting is ever enabled.

### 5. Thin wiring updates

- `OrchestraService.openNotes(_:)` → `launcher.openNotes(t.cwd)` (was `t.repo`); return the
  opened count up the call chain.
- `ControlServer` `"openNotes"` verb → return `{ "ok": true, "opened": N, "total": M }`.
- `BoardModel.openNotes(_:)` → read `opened`/`total`; toast:
  - `total == 0` → "Opening worktree notes…", sub = worktree dir name.
  - `opened == total` → "Opening N changed notes…", sub = worktree dir name.
  - `opened < total` → "Opening N of M changed notes…", sub = worktree dir name.
  - error toast unchanged.
- `App/Views/InspectorView.swift` → button tooltip/comment: "Open this card's changed notes
  in its worktree (Obsidian)."

## Edge cases

- **Non-git / scratch card / unresolved base** → `changedNotes` returns `[]` → vault opens,
  no tabs.
- **Deleted notes** excluded (can't open a nonexistent path).
- **Cold-start race:** when the vault is brand-new the script restarts Obsidian, then we fire
  file URIs; the first URI can occasionally land before the app is ready. Fire the URIs after
  the script returns; if this proves flaky in practice, add a short settle/retry. Not
  pre-optimized.

## Non-goals / deferred

- **Obsidian `userIgnoreFilters`** to dim heavy dirs (`Sources/`, `.build/`) in search/graph
  for the whole-worktree vault. Easy follow-up; deferred from v1.
- Changing what "Open notes" means for the `/open-notes` Claude command or the global script.

## Testing

- Extend the existing `Tests/IntegrationTests/LauncherDiffTests.swift` git-repo harness to
  cover `changedNotes(worktree:)`: md-only filtering, deletions excluded, untracked `.md`
  included, absolute paths, and the empty result for a non-git dir.
- The actual GUI open isn't unit-testable; the script already has a `DRYRUN` knob for its own
  logic. The tab cap is covered by a unit test on the (pure) count/truncation logic.
