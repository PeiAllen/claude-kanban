---
name: orchestra-tree
description: Use when your card's branch was spawned on top of another branch (it has a tree parent) — for keeping in sync with the parent, restacking after the parent moves or ships, and shipping your branch up the tree instead of straight to main.
---

# Working in a branch tree

Your branch may have a **parent branch** (you were spawned on top of it, or `set-parent` linked one). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Three operations keep the tree healthy. Resolve your position first with `orchestra tree` (or `orchestra tree <you>`): it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

When your agent harness exposes Orchestra MCP tools, use them for the Orchestra operations below; the
`orchestra …` forms are terminal-workflow syntax. Keep the Git commands in a shell. A managed sandbox can
deny the CLI's Unix-socket connection even though the equivalent MCP call works, so do not retry a CLI
`Operation not permitted` or daemon-connection error—reissue that operation through MCP instead. A
semantic rejection from either client is still a real rejection because both use the same service.

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

- **Parent has a live card** → you cannot advance a branch checked out in another worktree, and the owning agent must merge it. `orchestra merge-request <you>` (the daemon composes the request, nudges the parent card, and shows you a "merge requested" badge while you wait) and **stop** — the parent's agent squash-merges in its own worktree and calls `orchestra shipped <you>`, which wakes you to verify + archive. Do not `cd` into the parent's worktree.
- **Bare local parent (no card owns it)** → let Orchestra own the throwaway worktree: `orchestra borrow <you>` prints a fresh `orch-borrow-*` checkout of the parent branch. `cd` there, `git merge --squash <you>` and commit. **On conflict:** resolve and commit, or `git merge --abort` and report — never leave the borrow half-merged. Then `orchestra shipped <you>` followed by `orchestra release <you>` (the daemon also sweeps the borrow on your archive / at its next startup, so a crash can't strand it).
  - **If `borrow` fails with "parent … is already borrowed"** a sibling is landing into the same parent right now (exactly-one-borrower). **Do NOT retry in a loop or `cd` into its worktree.** STOP and wait — when it ships, the parent advances and you get a stale nudge; then `git merge <parent>` the parent down, `orchestra synced <you>`, and retry your own ship.
- **Parent is `main`** → **you do not merge to `main` yourself.** Commit your work, move your card to Review (`orchestra move <you> --col review`), and report that the branch is ready — a human reviews and merges every main-bound branch, and may come back to you with further instructions. **If `orchestra tree <you>` shows you have children**, run `orchestra shipped <you>` *after the human's merge has landed* — confirm that yourself rather than assuming: refresh `main` and check that `git log --oneline main` really contains your work (a squash merge rewrites your commits, so an ancestry test alone can report "not landed" when it did) — so the daemon retargets them onto `main` and nudges each to restack; otherwise a stacked child strands on your now-merged branch and shows `inSync` forever. No children ⇒ skip `shipped`.
- **Remote parent (`origin/<branch>` or `pr#<N>`)** → do NOT merge locally. **Publish** your branch as a stacked PR:
  1. `git push -u origin <your-branch>`
  2. `gh pr create --base <parentHeadRef>` — target the PARENT's head branch (the branch behind the parent PR / `origin/<branch>`), NOT `main`, so your PR shows only your commits.
  Do NOT call `orchestra shipped`. Orchestra watches the parent PR; when it merges, it redirects your card onto the parent's base and nudges you to restack.

After `orchestra shipped <you>` runs, the daemon retargets any children of yours onto the grandparent and notifies the shipped card that its branch landed (so a stopped child wakes to verify + archive) — you then archive as usual.

## Restack after a REMOTE parent merges

When your remote parent (`origin/…` / `pr#N`) merges, Orchestra redirects your link onto the parent's base and sends a nudge. Then:

1. **Commit your WIP first** (never autostash).
2. `git rebase --onto <new-base> <recorded-base>` — `<recorded-base>` is the anchor in the nudge / `orchestra tree`; only YOUR commits move (squash-proof — no phantom conflicts).
3. `git push --force-with-lease` — **never a bare `--force`** (force-with-lease refuses to clobber an unseen remote update).
4. `orchestra synced <you>`.
5. Orchestra best-effort repairs your PR's base; if it didn't, `gh pr edit <your-pr> --base <new-base>`.
