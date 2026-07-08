# AGENTS.md — claude-kanban

Instructions for Codex (and other AGENTS.md-reading agents) working in this repo. Codex auto-includes
this file from the working directory up to the repo root, so it applies in the main checkout and in
every worktree. Broader project conventions live in `CLAUDE.md`.

## Shipping a card (`/ship`)

When asked to **ship this card** — or when the user types **`/ship`** (optionally `/ship no-relaunch`) —
do all of the following yourself, fixing whatever comes up along the way (build/typecheck errors, a
dirty main checkout, merge hiccups) — don't stop to ask:

1. **Commit** — stage and commit all changes in this worktree with a clear message summarizing the work.
2. **Resolve the parent** — run `orchestra tree <this-card>` (ref = the `ORCHESTRA_TASK_ID` environment
   variable). If this branch has a tree parent that is **not** `main`, ship UP the tree instead of to
   main (this is a stacked child — merging it to main would drag its parent's commits along, exactly
   what the branch-tree feature exists to prevent):
   - **Parent has a live card** → you cannot advance a branch checked out in another worktree.
     `orchestra merge-request <this-card>` (the daemon composes the request, nudges the parent card,
     and marks you "merge requested"), then **stop** — the parent's agent squash-merges in its own
     worktree and calls `orchestra shipped <this-card>`, which wakes you to verify + archive and
     retargets any children of yours. Do not `cd` into the parent's worktree; do not merge to main.
   - **Bare local parent (no card owns it)** → borrow it ephemerally: `git worktree add` a throwaway
     checkout of the parent branch, `git merge --squash <this-branch>`, commit, remove the worktree,
     then `orchestra shipped <this-card>` (which retargets any children of yours). Then archive (step 5).
   - **Parent is `main` (or this branch has no tree parent)** → continue with the standard main flow below.
   - **Remote parent (`origin/…` or a PR)** → out of scope for the ship recipe; stop and report rather
     than guessing (the `orchestra-tree` guidance covers publishing a stacked PR).
3. **Merge to main** — merge this branch into `main`. `main` is checked out in a separate worktree (the
   primary checkout — the `main` entry in `git worktree list`); `cd` into it and merge the branch there
   with a merge commit (matches the repo's `merge:` history). **After the merge lands**, if `orchestra
   tree <this-card>` shows this card has **children**, run `orchestra shipped <this-card>` so the daemon
   retargets them onto `main` and nudges each to restack (otherwise a stacked child strands on this
   now-merged branch and shows `inSync` forever). A card with no children can skip `shipped`.
4. **Relaunch off main** — unless `no-relaunch` was requested, run `scripts/build-and-launch-app.sh` from
   that main checkout to rebuild and relaunch the app off main. (Agent terminals survive the restart.)
5. **Archive this card** — last, only once everything above has succeeded: archive this card with the
   orchestra `archive` tool. The card's ref is the `ORCHESTRA_TASK_ID` environment variable.
