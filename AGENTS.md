# AGENTS.md — claude-kanban

Instructions for Codex (and other AGENTS.md-reading agents) working in this repo. Codex auto-includes
this file from the working directory up to the repo root, so it applies in the main checkout and in
every worktree. Broader project conventions live in `CLAUDE.md`.

## Orchestra control calls from agents

When a managed or sandboxed agent has Orchestra MCP tools, use MCP for board control calls such as
`send`, `move`, `spawn`, `batch-spawn`, `handoff`, `wait`, `merge-request`, `shipped`, and `archive`.
The local `orchestra` CLI reaches the daemon over a Unix socket, which the agent sandbox can deny even
though the equivalent MCP call is allowed.

The CLI remains appropriate for unrestricted/local terminal workflows and shell-native operations. In the
shipping recipe below, keep its Git and worktree commands in the shell, but use MCP for the named board
operations when it is available. If a necessary CLI call fails with `Operation not permitted` or cannot
reach the daemon, do not retry it: issue the same operation through MCP. Treat semantic rejections from
either client as real errors—both clients reach the same Orchestra service.

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
   - **Bare local parent (no card owns it)** → `orchestra borrow <this-card>` prints a throwaway
     `orch-borrow-*` checkout of the parent branch. `cd` there, `git merge --squash <this-branch>` and
     commit. On conflict: resolve and commit, or `git merge --abort` and report — never leave it
     half-merged. Then `orchestra shipped <this-card>` (retargets any children of yours) and `orchestra
     release <this-card>` (the daemon also sweeps the borrow on archive/startup). Then archive (step 5).
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
