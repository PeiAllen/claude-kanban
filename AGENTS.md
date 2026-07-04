# AGENTS.md — claude-kanban

Instructions for Codex (and other AGENTS.md-reading agents) working in this repo. Codex auto-includes
this file from the working directory up to the repo root, so it applies in the main checkout and in
every worktree. Broader project conventions live in `CLAUDE.md`.

## Shipping a card (`/ship`)

When asked to **ship this card** — or when the user types **`/ship`** (optionally `/ship no-relaunch`) —
do all of the following yourself, fixing whatever comes up along the way (build/typecheck errors, a
dirty main checkout, merge hiccups) — don't stop to ask:

1. **Commit** — stage and commit all changes in this worktree with a clear message summarizing the work.
2. **Merge to main** — merge this branch into `main`. `main` is checked out in a separate worktree (the
   primary checkout — the `main` entry in `git worktree list`); `cd` into it and merge the branch there
   with a merge commit (matches the repo's `merge:` history).
3. **Relaunch off main** — unless `no-relaunch` was requested, run `scripts/build-and-launch-app.sh` from
   that main checkout to rebuild and relaunch the app off main. (Agent terminals survive the restart.)
4. **Archive this card** — last, only once everything above has succeeded: archive this card with the
   orchestra `archive` tool. The card's ref is the `ORCHESTRA_TASK_ID` environment variable.
