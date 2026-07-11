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
`notes/designs/build-contention.md`.

## Keep the test suite tiered — don't let it re-clump

The mutex caps the damage from *concurrency*; it does nothing about the **165s baseline that
concurrency multiplies**. `OrchestraCoreTests` is already the biggest target in the repo
(123 files / 17k lines), `swift test` cannot skip the MCP/swift-nio dependency tree, and
every target and test you add raises that baseline permanently — for every card, forever.

When adding code, ask whether it grows the critical path, and **keep tests tiered** (a fast
unit tier agents run constantly; a slow integration tier run deliberately) rather than one
monolithic target everything must compile. Don't collapse the tiers back together.

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
