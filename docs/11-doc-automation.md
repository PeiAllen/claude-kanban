# 11. Documentation automation

This README and the reference manual are **auto-maintained**: whenever a new plan or code change lands
on `main`, a git hook runs Claude Code headlessly to refresh the docs and commits the result. This
chapter explains exactly what happens, the guards that keep it safe, and how to configure, pause, or
remove it.

## Why

The project owner adds features continuously. Rather than hand-updating the docs each time (and letting
them rot), the docs regenerate themselves from the change that just landed — reading the modified
source plus any new `notes/plans/` and `notes/designs/` documents — so the manual tracks `main` closely.

## Install it

```sh
scripts/install-doc-hooks.sh
```

This installs two hooks into the repo's git hooks directory (the common git dir, so it's shared across
all worktrees):

- **`post-commit`** — fires after a normal commit on `main` (e.g. committing a new plan into the repo).
- **`post-merge`** — fires after a merge into `main` (e.g. merging a feature branch/PR).

Both hooks launch [`scripts/update-docs.sh`](../scripts/update-docs.sh) **detached**, so your commit or
merge returns instantly. If a foreign hook of the same name already exists, the installer backs it up
(`<hook>.pre-orchestra.bak`) and chains to it, so your existing hooks still run.

## What runs

[`scripts/update-docs.sh`](../scripts/update-docs.sh) does the following, and is also safe to run by
hand at any time:

1. **Checks the branch** — exits immediately unless `HEAD` is on `main`. (This is why a commit on a
   feature worktree doesn't trigger a doc rebuild: the shared hook fires, but the script no-ops.)
2. **Checks the change** — looks at the files the triggering commit touched.
3. **Runs Claude Code headlessly** — `claude -p "<prompt>"` with a doc-only toolset, instructing it to
   read the changed sources + new plans/designs and make **surgical** edits to `README.md` and `docs/`
   so every feature, design decision, and future plan stays accurate (and to migrate a shipped roadmap
   axis from chapter 10 into chapter 9's history).
4. **Commits only the docs** — stages `README.md` + `docs/` and makes a single
   `docs: auto-sync README + manual [docs-sync]` commit. If Claude made no changes, nothing is
   committed.

## The guards

The automation is designed to never loop and never get in your way:

- **Recursion guard #1 — marker.** The doc-sync commit message contains `[docs-sync]`. When that commit
  re-triggers `post-commit`, the script sees the marker and exits. The loop terminates after exactly one
  doc commit.
- **Recursion guard #2 — doc-only changes.** If a commit touched *only* `README.md`/`docs/`, there is
  nothing new to document, so the script exits. (This also covers manual doc edits.)
- **Branch guard.** Only `main` triggers a real run.
- **Single-flight lock.** A lock dir under `.git/` ensures overlapping commits don't launch concurrent
  Claude runs.
- **Never blocks or fails your commit.** The hook is detached and every error path in the script exits
  `0`, leaving your tree untouched. Output goes to `.git/orchestra-docs-sync.log`.

## Configure

Environment overrides (set them where the hook will see them, e.g. your shell profile):

| Variable | Default | Effect |
|----------|---------|--------|
| `ORCHESTRA_DOCS_BRANCH` | `main` | Branch to act on. Set to something that never matches (e.g. `__disabled__`) to **pause** the automation without uninstalling. |
| `ORCHESTRA_CLAUDE_BIN` | `claude` | Path to the Claude Code CLI. |
| `ORCHESTRA_DOCS_CLAUDE_FLAGS` | `--permission-mode acceptEdits --allowedTools Read Edit Write Grep Glob` | Flags passed to `claude -p`. Adjust if your CLI version expects a different form (the default restricts the run to read/edit tools so it can't wander into Bash/git). |

## Remove

```sh
scripts/install-doc-hooks.sh --uninstall
```

This removes the hooks (restoring any backed-up foreign hook). You can still run
`scripts/update-docs.sh` manually whenever you like.

## Caveats

- The hook needs the `claude` CLI on the `PATH` that git hooks inherit. If it isn't found, the script
  logs a note and skips — your commit is unaffected.
- Because the run commits to `main` on its own, review the `docs:` commits periodically — Claude is
  good but not infallible, and a regenerated chapter is still a generated artifact. If the prose and the
  code ever disagree, the code wins; fix the source-of-truth and the next sync will follow.
