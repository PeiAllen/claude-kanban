---
name: orchestra-tree
description: Use when your card's branch was spawned on top of another branch (it has a tree parent) — for keeping in sync with the parent, restacking after the parent moves or ships, and shipping your branch up the tree instead of straight to main.
---

# Working in a branch tree

Your branch may have a **parent branch** (you were spawned on top of it, or `set-parent` linked one). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Three operations keep the tree healthy. Resolve your position first with `orchestra tree` (or `orchestra tree <you>`): it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

## Sync — pull the parent's new work down

When `orchestra tree` shows you `stale` / behind N, the parent advanced. Merge it down, then report:

1. Commit WIP first: make sure your tree is clean.
2. `git merge <parent>` (a normal merge — you are pulling the parent INTO you).
3. Resolve any conflicts, commit the merge.
4. `orchestra synced <you>` — records the parent's current tip as your new base and clears the stale signal.

## Restack — the parent moved out from under you

When `treeStat` is `restackNeeded` (the parent was rebased, re-parented via `set-parent move`, or **shipped** so your link was retargeted onto its grandparent), replay only YOUR commits onto the new parent:

1. **Commit your WIP first** — a restack rewrites history and refuses to run on a dirty tree. **Never autostash.**
2. `git rebase --onto <new-parent> <recorded-base>` — `<recorded-base>` is the OID Orchestra kept as your rebase anchor (in the nudge, and in `orchestra tree`). Using `--onto` with the recorded base transplants ONLY your own commits, so work already in the new parent (e.g. a squash-merged parent) is not re-applied and you avoid phantom conflicts.
3. If it conflicts, resolve and `git rebase --continue`; if it goes wrong, `git rebase --abort` and report — never leave the branch half-restacked.
4. `orchestra synced <you>`.

## Ship — merge your branch up the tree

Do NOT blindly ship to main. Resolve the parent via `orchestra tree` and take the matching path:

- **Parent has a live card** → you cannot advance a branch checked out in another worktree, and the owning agent must merge it. `orchestra send <parent-ref> "merge-request: squash-merge <you> into <parent>"` and **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <you>`. Do not `cd` into the parent's worktree.
- **Bare local parent (no card owns it)** → borrow it ephemerally: check the parent branch out in a throwaway worktree, `git merge --squash <you>`, commit, remove the worktree, then `orchestra shipped <you>`.
- **Parent is `main`** → today's `/ship` flow is unchanged (commit → merge to main → relaunch → archive). Do not call `orchestra shipped`.
- **Remote parent (`origin/…` / a PR)** → out of scope for now (BT6). Do not attempt a local merge.

After `orchestra shipped <you>` runs, the daemon notifies the parent card and retargets any children of yours onto the grandparent — you then archive as usual.
