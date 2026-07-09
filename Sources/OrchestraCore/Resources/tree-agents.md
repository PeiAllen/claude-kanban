# Working in a branch tree

Your branch may have a **parent branch** (spawned on top of it, or linked via `set-parent`). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Resolve your position with `orchestra tree` (or `orchestra tree <you>`) before acting: it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

## Sync — pull the parent's new work down

When `orchestra tree` shows you `stale` / behind N:

1. Commit WIP so your tree is clean.
2. `git merge <parent>` (merge the parent INTO you).
3. Resolve conflicts, commit the merge.
4. `orchestra synced <you>`.

## Restack — the parent moved out from under you

When `treeStat` is `restackNeeded` (parent rebased, re-parented via `set-parent move`, or **shipped** so your link was retargeted onto its grandparent):

1. **Commit your WIP first.** A restack rewrites history and refuses a dirty tree. **Never autostash.**
2. `git rebase --onto <new-parent> <recorded-base>` — `<recorded-base>` is the OID Orchestra kept as your rebase anchor (in the nudge, and in `orchestra tree`). `--onto` with the recorded base transplants ONLY your own commits, so work already in the new parent (a squash-merged parent) is not re-applied — no phantom conflicts.
3. On conflict resolve + `git rebase --continue`; if it goes wrong `git rebase --abort` and report.
4. `orchestra synced <you>`.

## Ship — merge your branch up the tree

Resolve the parent via `orchestra tree` and take the matching path:

- **Parent has a live card** → you cannot advance a branch checked out in another worktree. `orchestra merge-request <you>` (the daemon composes the request + nudges the parent card + marks you "merge requested") and **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <you>`, which wakes you to verify + archive.
- **Bare local parent (no card)** → `orchestra borrow <you>` prints a throwaway `orch-borrow-*` checkout of the parent. `cd` there, `git merge --squash <you>` and commit. On conflict: resolve and commit, or `git merge --abort` and report — never leave it half-merged. Then `orchestra shipped <you>` and `orchestra release <you>` (the daemon also sweeps the borrow on archive/startup).
  - **If `borrow` fails with "parent … is already borrowed"** a sibling is landing into the same parent (exactly-one-borrower). Do NOT retry in a loop or `cd` into its worktree — STOP and wait for the stale nudge after it ships, then `git merge <parent>` + `orchestra synced <you>` and retry your own ship.
- **Parent is `main`** → the standard ship flow. **If `orchestra tree <you>` shows you have children**, run `orchestra shipped <you>` after the merge lands so the daemon retargets them onto `main` and nudges each to restack — otherwise a stacked child strands on your now-merged branch and shows `inSync` forever. No children ⇒ skip `shipped`.
- **Remote parent (`origin/<branch>` or `pr#<N>`)** → do NOT merge locally. Publish a stacked PR: `git push -u origin <your-branch>`, then `gh pr create --base <parentHeadRef>` (target the parent's head branch, not `main`). Do NOT call `orchestra shipped` — Orchestra watches the parent PR and redirects you when it merges.

After `orchestra shipped <you>` runs, the daemon notifies the parent card and retargets any children of yours onto the grandparent — you then archive as usual.

## Restack after a REMOTE parent merges

When your remote parent merges, Orchestra redirects your link onto the parent's base and nudges you. Then: commit WIP (never autostash); `git rebase --onto <new-base> <recorded-base>` (only your commits move — squash-proof); `git push --force-with-lease` (never a bare `--force`); `orchestra synced <you>`. Orchestra best-effort repairs your PR base; if it didn't, `gh pr edit <your-pr> --base <new-base>`.
