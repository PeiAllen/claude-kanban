# Working in a branch tree

Your branch may have a **parent branch** (spawned on top of it, or linked via `set-parent`). Orchestra tracks that link and a recorded **base** — the parent tip at your last sync. Resolve your position with `orchestra tree` (or `orchestra tree <you>`) before acting: it reports your parent, its recorded base, whether a live card owns the parent, and your `treeStat`.

When your agent harness exposes Orchestra MCP tools, use them for the Orchestra operations below; the
`orchestra …` forms are terminal-workflow syntax. Keep the Git commands in a shell. A managed sandbox can
deny the CLI's Unix-socket connection even though the equivalent MCP call works, so do not retry a CLI
`Operation not permitted` or daemon-connection error—reissue that operation through MCP instead. A
semantic rejection from either client is still a real rejection because both use the same service.

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

## Ship — declare your work ready

**One verb, every parent kind: commit, run `orchestra merge-request <you>`, and STOP.** Routing is the daemon's, not yours — don't resolve the parent first to pick a path. Two outcomes from that one call:

- **A live card owns your parent branch** → the request lands in that agent's inbox and is re-asked until it acts; it squash-merges in its own worktree and calls `orchestra shipped <you>`, which wakes you to verify + archive. You cannot advance a branch checked out in another worktree — never `cd` there to do it yourself.
- **No live card owns your parent branch** — it is `main`, a bare local branch, a remote branch/PR, or you have no parent link → the request is RECORDED on your card and a **human** takes it from there, merging however they choose. No agent to wait for: stop.

The request is sticky ("merge requested" until it resolves) and re-sending is a no-op refresh. Don't follow it with your own merge, a borrow, or a pull request — a human will direct those if they want them.

**If your branch is merged and `orchestra tree <you>` shows you have children**, run `orchestra shipped <you>` once that merge lands, so the daemon retargets them onto your parent and nudges each to restack; otherwise a stacked child sits on your merged branch at `inSync` until someone re-points it. No need to verify the merge with git first — `shipped` refuses when nothing merged. No children ⇒ nothing to do.

`orchestra shipped <you>` always retargets any children of yours onto the grandparent. Run by a PARENT agent it also wakes you with "your branch landed" — verify, then archive as usual. Run by you on yourself there's no such wake.

## Restack after a REMOTE parent merges

When your remote parent (`origin/<branch>` / `pr#<N>`) merges, Orchestra redirects your link onto the parent's base and nudges you. Then: commit WIP (never autostash); `git rebase --onto <new-base> <recorded-base>` (only your commits move — squash-proof); **if your branch is already published**, `git push --force-with-lease` (never a bare `--force`) — if it isn't, skip that, publishing is a human's call; `orchestra synced <you>`. If your branch has a PR, Orchestra best-effort repairs its base; if it didn't, `gh pr edit <your-pr> --base <new-base>`.
