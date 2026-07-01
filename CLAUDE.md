# claude-kanban — project instructions

## Scratch / experiments — keep them contained
Do all throwaway work — probes, experiments, scratch scripts, dumped output, temporary
files — inside **`./.scratch/`** (gitignored). Don't scatter temp files across the repo or
write outside the project directory.

The Bash sandbox (enabled in `.claude/settings.local.json`) already confines commands to the
working directory + the session temp dir at the OS level, so experiments physically can't
escape scope; `.scratch/` just keeps the artifacts tidy and out of git. Prefer `.scratch/`
(or `$TMPDIR`, which the sandbox makes writable) over `/tmp` for anything throwaway.

## Cleanup — keep it prompt-free (matters for unattended / overnight agents)
An unattended agent must not trigger a permission prompt while cleaning up. Two independent
layers can prompt on deletions, so:

- **Clean up inside `./.scratch/` (or the cwd)** — these are sandbox-writable, so `rm -rf .scratch/…`
  is auto-allowed with **no prompt**. This is the default place to put (and delete) test artifacts.
- **Don't `rm -rf /tmp/…` directly.** `/tmp` is *outside* the sandbox's writable set, so the delete
  fails in-sandbox and falls back to a **classifier prompt**. Test harnesses (e.g.
  `scripts/orch-ux-e2e.sh`) already clean up their own `/tmp` dirs internally — don't re-clean them
  from a separate command. If you genuinely must touch `/tmp`, expect a prompt.
- **Avoid `git clean -dx` and `find … -delete`.** The global `guard-destructive` hook flags these
  (plus `.git` deletes and recursive `rm` targeting `.`/`*`/`/`/`~`/root or a path *outside* the
  project root) via a **regex over the command text** — it will `ask` even inside a quoted string.
  `/tmp` and in-project paths are exempt, so ordinary `.scratch/` cleanup never trips it.
- **Don't hand-delete git worktrees** — Orchestra removes a card's worktree on close; leave it.
