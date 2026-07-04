---
description: Ship this card — commit its work, merge to main, relaunch the app off main, and archive the card. Pass "no-relaunch" to skip the relaunch.
---

Ship this card's work and then archive it. Do the whole thing yourself, fixing whatever comes up along the way (build/typecheck errors, a dirty main checkout, merge hiccups) — don't stop to ask.

1. **Commit** — stage and commit all changes in this worktree with a clear message summarizing the work.
2. **Merge to main** — merge this branch into `main`. `main` is checked out in a separate worktree (the primary checkout — the `main` entry in `git worktree list`); `cd` into it and merge the branch there with a merge commit (matches the repo's `merge:` history).
3. **Relaunch off main** — unless the argument says to skip it, run `scripts/build-and-launch-app.sh` from that main checkout to rebuild and relaunch the app off main. (Agent terminals survive the restart.)
4. **Archive this card** — last, only once everything above has succeeded: archive this card with the orchestra `archive` tool. The card's ref is the `ORCHESTRA_TASK_ID` environment variable.

Argument: `$ARGUMENTS` — if it contains `no-relaunch`, skip step 3.
