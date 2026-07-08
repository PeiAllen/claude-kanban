---
description: Ship this card — commit its work, merge to main, relaunch the app off main, and archive the card. Pass "no-relaunch" to skip the relaunch.
---

Ship this card's work and then archive it. Do the whole thing yourself, fixing whatever comes up along the way (build/typecheck errors, a dirty main checkout, merge hiccups) — don't stop to ask.

1. **Commit** — stage and commit all changes in this worktree with a clear message summarizing the work.
2. **Resolve the parent** — run `orchestra tree <this-card>` (ref = the `ORCHESTRA_TASK_ID` environment variable). If this branch has a tree parent that is **not** `main`, ship UP the tree instead of to main:
   - **Parent has a live card** → you cannot advance a branch checked out in another worktree. `orchestra send <parent-ref> "merge-request: squash-merge <this-branch> into <parent>"`, then **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <this-card>`, which notifies it and retargets any children of yours. Do not `cd` into the parent's worktree; do not merge to main.
   - **Bare local parent (no card owns it)** → borrow it ephemerally: `git worktree add` a throwaway checkout of the parent branch, `git merge --squash <this-branch>`, commit, remove the worktree, then `orchestra shipped <this-card>` (which retargets any children of yours). Then archive as in step 5.
   - **Parent is `main` (or this branch has no tree parent)** → continue with the standard main flow below (steps 3–5).
   - **Remote parent (`origin/…` or a PR)** → do NOT merge locally. Follow the `orchestra-tree` skill's publish flow: `git push -u origin <this-branch>`, then `gh pr create --base <parentHeadRef>` (target the parent's head branch, not `main`), then **stop** — do NOT call `orchestra shipped`. Orchestra watches the parent PR and redirects your card onto its base when it merges.
3. **Merge to main** — merge this branch into `main`. `main` is checked out in a separate worktree (the primary checkout — the `main` entry in `git worktree list`); `cd` into it and merge the branch there with a merge commit (matches the repo's `merge:` history). **After the merge lands**, if `orchestra tree <this-card>` shows this card has **children**, run `orchestra shipped <this-card>` so the daemon retargets them onto `main` and nudges each to restack (otherwise a stacked child strands on this now-merged branch and shows `inSync` forever). A card with no children can skip `shipped`.
4. **Relaunch off main** — unless the argument says to skip it, run `scripts/build-and-launch-app.sh` from that main checkout to rebuild and relaunch the app off main. (Agent terminals survive the restart.)
5. **Archive this card** — last, only once everything above has succeeded: archive this card with the orchestra `archive` tool. The card's ref is the `ORCHESTRA_TASK_ID` environment variable.

Argument: `$ARGUMENTS` — if it contains `no-relaunch`, skip step 4.
