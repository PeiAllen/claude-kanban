# claude-kanban — project instructions

## Scratch / experiments — keep them contained
Do all throwaway work — probes, experiments, scratch scripts, dumped output, temporary
files — inside **`./.scratch/`** (gitignored). Don't scatter temp files across the repo or
write outside the project directory.

The Bash sandbox (enabled in `.claude/settings.local.json`) already confines commands to the
working directory + the session temp dir at the OS level, so experiments physically can't
escape scope; `.scratch/` just keeps the artifacts tidy and out of git. Prefer `.scratch/`
(or `$TMPDIR`, which the sandbox makes writable) over `/tmp` for anything throwaway.
