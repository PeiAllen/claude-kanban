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

## Ship — declare your work ready

**One verb, every parent kind: commit your work, run `orchestra merge-request <you>`, and STOP.** Who
merges you, and how, is the daemon's routing — not your decision, and not something to work out from
`orchestra tree` first. Two things happen from that one call:

- **A live card owns your parent branch** → the request lands in that agent's inbox and is re-asked until
  it acts. It squash-merges in its own worktree and calls `orchestra shipped <you>`, which wakes you to
  verify and archive. You cannot advance a branch that is checked out in another worktree, so never `cd`
  into the parent's worktree to do it yourself.
- **No live card owns your parent branch** — it is `main`, a bare local branch, a remote branch or PR, or
  you have no parent link at all → the request is RECORDED on your card and a **human** takes it from
  there, merging however they choose. There is no agent to wait for: stop, and let them come back to you.

Either way the request is sticky (your card reads "merge requested" until it resolves) and re-sending is
a no-op refresh rather than a second request. Do not follow it with a merge of your own, a borrow, or a
pull request — if a human wants one of those they will direct it.

**If your branch is merged and `orchestra tree <you>` shows you have children**, run
`orchestra shipped <you>` once that merge lands: the daemon then retargets them onto your parent and
nudges each to restack. Otherwise a stacked child sits on your merged branch showing `inSync` until
someone re-points it. You don't need to prove the merge with git first — `shipped` refuses when nothing
actually merged. No children ⇒ nothing to do.

`orchestra shipped <you>` always retargets any children of yours onto the grandparent. When a **parent
agent** runs it for you it also wakes you with "your branch landed" — verify, then archive as usual.
When you call it on yourself there is no such wake, because you already know.

## Restack after a REMOTE parent merges

When your remote parent (`origin/…` / `pr#N`) merges, Orchestra redirects your link onto the parent's base and sends a nudge. Then:

1. **Commit your WIP first** (never autostash).
2. `git rebase --onto <new-base> <recorded-base>` — `<recorded-base>` is the anchor in the nudge / `orchestra tree`; only YOUR commits move (squash-proof — no phantom conflicts).
3. **If your branch is already published**, `git push --force-with-lease` — **never a bare `--force`** (force-with-lease refuses to clobber an unseen remote update). If it isn't published, skip this: publishing is a human's call, not a step you take on your own.
4. `orchestra synced <you>`.
5. If your branch has a PR, Orchestra best-effort repairs its base; if it didn't, `gh pr edit <your-pr> --base <new-base>`.
