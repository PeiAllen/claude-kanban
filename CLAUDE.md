# claude-kanban — project instructions

## Design for every agent, not just the one you're testing
Orchestra runs multiple agent backends. **Claude and Codex are the priority targets — a
change must work for both** (and stay open to others behind the same seam). When building or
changing anything that touches agent behavior — session lifecycle, spawn/restart/resume, diff
baselines, monitoring/liveness, prompts, env, trust — design against the *general* agent
contract, not one agent's quirks. Reach for a capability/adapter seam (per-agent config, a
capability probe, a feature flag) instead of `if agent == "claude"` branches scattered through
shared code; if something genuinely needs agent-specific handling, isolate it behind that
boundary. Before calling a change done, sanity-check it against **at least Claude and Codex** —
a fix that only works for the agent you happened to test is a regression for the rest.

## Always build via `scripts/` — never a bare `swift build`

Builds on this machine are **contention-bound, not CPU-bound**. Measured: one cold
`swift build --build-tests` takes **165s**, but **three concurrent ones take 520s *each*** —
degradation is super-linear, so concurrent building is pure loss (3 serialized finish sooner
than 3 in parallel) and it drags the Orchestra app and daemon down with it (daemon RPC p95:
6.5ms → 22ms). The reported "8m36s cold build" *was* three cards building at once.

So every heavy build goes through a **machine-wide build mutex**:

```sh
scripts/build.sh          # instead of `swift build`
scripts/test.sh           # instead of `swift test`
scripts/build-app.sh      # app bundle (also takes the SHIP mutex)
```

A bare `swift build` **bypasses the mutex** and re-creates the problem for every other card.
If you need a raw invocation, wrap it: `scripts/lib/with-lock.sh build -- swift build …`.
When another card holds the lock you'll see `[build-lock] waiting for slot…` on stderr; the
wait is bounded and **fails open**, so it can never fail your build. Details + the numbers:
`docs/08-building-operations.md` (the build-contention / build-mutex section).

## The test suite is tiered — run the unit tier per task, `--all` once at the merge gate

The suite is split into three targets that mirror `Sources/` (`Tests/UnitTests` — pure logic
over `FakeProc`/`TestClock`, per-test private roots, forks nothing; `Tests/ContractTests` —
real git/tmux/fd behavior pinning the fakes' fidelity; `Tests/E2ETests` — built binaries +
the slow-repo fixture, parameterized over BOTH agents):

- **Per task / inner loop:** `./scripts/test.sh` — the unit tier, ~1,050 tests in seconds.
- **Touching git/tmux command generation:** add `--contract`. **Touching binaries/daemon
  wiring:** add `--e2e`. Selection is ADDITIVE — a scoped run is never smaller than the
  full unit tier (a change-to-test map that skips is provably unsafe; see the design doc).
- **Merge gate, once per PR:** `./scripts/test.sh --all` (also runs `scripts/lint-tests.sh`).

Do NOT mandate full-suite runs after every task in plans — that is the pattern that made
past projects cost wall-clock days.

Keep it from re-clumping (enforced by `scripts/lint-tests.sh`): no wall-clock sleeps in the
unit tier (use `TestClock.advance`, a `Gate`/`SyncGate`, or `pollUntil` from TestSupport);
no ambient path statics (every test gets private roots via `TestEnv`); no real forks
(`FakeProc` is the default seam — a genuinely-real test belongs in ContractTests). New tests
go in the mirror position of the source file they cover.

Full rationale + the mechanisms: `docs/08-building-operations.md` (the tiered-test-suite section).

## Docs are the SSOT — carry the "why" in commits + `docs/`, never in a notes/ vault

The reference manual under `docs/` is the single source of truth, auto-synced from `main` by
`scripts/update-docs.sh`. There is **no tracked `notes/` planning vault** — `notes/plans/` and
`notes/designs/` are gitignored local scratch that never lands in the repo (so it can't clog PR
diffs or linger as stale references a later agent wrongly trusts as current truth). Don't cite a
`notes/` path as a source of truth; cite `docs/` or the code.

So when a PR changes behavior or a design decision, the durable **"why"** — the alternatives
weighed, the tradeoffs, the decision — has exactly two homes, and it must land in **both**:
- **the commit / PR body** — this is what the doc-sync run reads (commit messages across the
  merged range) to regenerate chapters 9 and 10, so a decision explained only in a local
  untracked file is invisible to it;
- **`docs/` directly, in the same PR** — update the right chapter (design decisions → `docs/09`,
  a shipped roadmap axis → its history entry in `docs/09`, feature narrative → the numbered
  chapter).

Treat "the rationale is in the commit body **and** reflected in `docs/`" as part of the merge
gate for any behavior- or design-changing PR.

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
