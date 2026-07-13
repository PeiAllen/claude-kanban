# Environment isolation for the test suite — git config, and `HOME`

**Date:** 2026-07-11 (git hermeticity) · 2026-07-12 (HOME isolation)
**Status:** approved (design), both parts implemented
**Cards:** `test/git-hermeticity`, `fix/test-suite-home-isolation`

## Problem

`Tests/` has no `HOME` / `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_NOSYSTEM` isolation anywhere. Every
real-`git` fork made during a test run — ~116 from test code, plus every fork made by *production*
code under test (`SessionManager`, `DiffService`, `BranchLineage`, worktree creation) — reads the
**developer's personal `~/.gitconfig`**.

Two consequences:

1. **Credential-helper fallout.** On Allen's machine `credential.helper = osxkeychain` is configured,
   so git invokes the keychain helper. Under the Claude Code sandbox (which denies
   `~/Library/Keychains`) that surfaces as keychain-not-found errors and dialogs during test runs.
2. **Non-reproducibility.** Test results depend on whatever the developer happens to have configured:
   aliases, `init.defaultBranch`, `commit.gpgsign`, `core.excludesfile`, hooks. The suite is not
   reproducible across machines or in CI.

The suite's existing guard, `RemoteParents.remoteEnv()` (`GIT_TERMINAL_PROMPT=0` +
`GIT_ASKPASS=/usr/bin/false`), is applied at only 3 call sites and does **not** disable the
credential helper — only clearing `credential.helper` does that.

## Key facts established during design

- **Every git fork funnels through `Proc.run`**, which rebuilds the child environment from
  `ProcessInfo.processInfo.environment` on *every* call. So a single `setenv()` performed once in the
  test process covers all of them — test-side forks, production-code forks, and even the
  out-of-process `orchestrad` / `orchestra` binaries that `E2EBinaryTests` spawns (they inherit the
  test process's environment).
- There is **no shared repo-creating test helper**. Roughly 20 test files each define their own local
  `git(...)` closure. Any scheme requiring test authors to opt in would leak.
- **A C target's `__attribute__((constructor))` runs at test-bundle load, before the first test**, in
  *both* the XCTest and swift-testing runs — with the target living outside `Sources/`, with no import
  and no call site in Swift. Verified empirically in this suite (debug) and in a standalone probe
  package (debug + release; this package's `swift test -c release` does not build, for a pre-existing
  reason unrelated to this change — a `#if DEBUG`-gated test hook).

  It survives dead-stripping *structurally*, not by luck, which is the stronger guarantee: **SwiftPM
  emits no static archive** for a target here — it links each binary from a flat object list
  (`<product>.product/Objects.LinkFileList`), and `bootstrap.c.o` is named directly on the test
  bundle's link line. An object named on the link line is loaded unconditionally; the classic
  "archive member never pulled in because nothing references a symbol" failure *requires an archive*.
  Independently, a constructor emits a pointer into `__DATA,__mod_init_func` (ELF: `.init_array`),
  and ld64/LLD treat initializer sections as GC roots, so `-dead_strip` and LTO preserve it too.
- Several tests (and `Tests/IntegrationTests/Fixtures/gen-slow-repo.sh`) commit using the developer's
  **global** git identity. Cutting global config without supplying an identity would break them.
- **No test asserts a commit author.**

## Approach

A **test-only load-time constructor** that installs a hermetic git environment into the test process.

### Chosen: C constructor target (Option A)

`Tests/GitHermeticBootstrap/bootstrap.c`, declared in `Package.swift` as

```swift
.target(name: "GitHermeticBootstrap", path: "Tests/GitHermeticBootstrap")
```

and added to the `dependencies` of `OrchestraCoreTests`, `IntegrationTests`, and `OrchestraUITests`.

Because the target lives under `Tests/` and is depended on only by test targets, it **cannot** be
linked into `orchestrad`, `orchestra`, or `orchestra-mcp`. Production behavior is unchanged *by
construction*, not by discipline. The daemon still reads the user's real gitconfig.

### Rejected alternatives

| Option | Why not |
|---|---|
| **B. Idempotent bootstrap called from shared test helpers** | There is no shared helper — ~20 files each roll their own `git(...)`. Worse, git forks made by *production* code under test would escape unless every test remembered to call the bootstrap first. Hermeticity by discipline is hermeticity you eventually lose. |
| **C. A `Proc.envOverlay` test seam** | Adds a mutable global to production code purely for tests, and *still* needs a bootstrap to set it — it relocates the hard part rather than solving it. |
| **D. Wrapper script (`scripts/test.sh` exports the env)** | Bare `swift test` — what developers, CI, and agents actually type — bypasses it entirely. |

## What the bootstrap does

Runs once, at bundle load. The whole body is skipped if `ORCHESTRA_TEST_GIT_HERMETIC=0`, an escape
hatch for debugging a config-sensitive failure against the real gitconfig.

### 1. It clears EVERY inherited `GIT_*` variable

Controlling git's *config* is not sufficient on its own — git takes a great deal of its behavior
straight from the environment, and one inherited variable silently defeats the whole scheme. Three
found in review, each demonstrated live against the otherwise-complete hermetic env:

- **`GIT_CONFIG_PARAMETERS`** is the older form of `-c`, parsed **in addition to** `GIT_CONFIG_COUNT`.
  An inherited one injects config straight past our overrides:
  `GIT_CONFIG_PARAMETERS="'credential.helper=!…'"` still **ran the helper** — the exact keychain
  invocation this card exists to prevent, walking back in through a side door.
- **`GIT_DIR` / `GIT_WORK_TREE`** point git at a *different repository*, overriding even an explicit
  `git -C <tmpdir>`. Demonstrated: with `GIT_DIR` inherited, `git -C target config orchestra.probe
  HIJACKED` wrote into the **other repo**. A test's commits and config writes could land in the
  developer's real repository.
- **`GIT_EXTERNAL_DIFF`** replaces git's builtin diff with a program of the parent's choosing — which
  hijacks the very code under test, since `DiffService`/`DiffProvider`/`DiffTextParser` are all built
  on `git diff`. Demonstrated: with it set, `git diff` emits no diff at all, just blob paths.

These are inherited for real whenever the suite runs from inside a git operation — a hook, an alias, a
rebase's `exec` step.

**The sweep is a wildcard over the whole `GIT_*` namespace, not a denylist — deliberately.** The first
implementation used a denylist, and two successive reviews each found *one more variable* it had missed
(`GIT_CONFIG_PARAMETERS`, then `GIT_EXTERNAL_DIFF`). A list you have to keep guessing at is an
invitation to miss the next one — `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`, or whatever a future git
release adds. Clearing the entire namespace and then installing exactly the variables we want is the
only version of this that is complete *by construction* rather than by vigilance. Nothing is lost:
every git variable the suite wants is set explicitly below, and production passes its own via
`Proc.run`'s per-call `env:` argument, which the test process's environment does not touch.

Verified end-to-end by launching `swift test` with a hostile environment — `GIT_DIR`,
`GIT_CONFIG_PARAMETERS` carrying a credential-helper injection, plus `GIT_SSH_COMMAND`,
`GIT_PROXY_COMMAND`, `GIT_PAGER`, `GIT_FLUSH`, `GIT_NO_REPLACE_OBJECTS` (none of which were ever on any
denylist) — and observing the canary stay green with none of them surviving.

### 2. It sets the hermetic environment

All writes use `overwrite = 1`.

| Variable | Value | Purpose |
|---|---|---|
| `GIT_CONFIG_NOSYSTEM` | `1` | cuts `/etc/gitconfig` |
| `GIT_CONFIG_GLOBAL` | `/dev/null` | cuts `~/.gitconfig` **and** the XDG config (`$XDG_CONFIG_HOME/git/config`) |
| `GIT_CONFIG_COUNT` | `2` | enables the two `-c`-equivalent overrides below |
| `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` | `credential.helper` / `""` | disables the osxkeychain helper at `-c` precedence, so it beats even a repo-local helper |
| `GIT_CONFIG_KEY_1` / `GIT_CONFIG_VALUE_1` | `init.defaultBranch` / `main` | deterministic default branch (no longer inherited from the developer) |
| `GIT_TERMINAL_PROMPT` | `0` | never prompt on a terminal |
| `GIT_ASKPASS` | `/usr/bin/false` | never prompt via an askpass helper |
| `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME` | `Orchestra Test` | identity that cutting global config takes away |
| `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_EMAIL` | `test@orchestra.invalid` | ditto |

### 3. It relocates `HOME` to a per-run temp dir (added 2026-07-12)

The 2026-07-11 version of this design left `HOME` alone, and said so explicitly: for *git*, a temp home
is redundant (`GIT_CONFIG_GLOBAL` already displaces `~/.gitconfig` **and** the XDG config), and moving
it would change what every non-git test sees. That reasoning was sound about git and wrong about
everything else — it treated "what the suite reads" as the only hazard and never asked what the suite
**writes**. See "The `HOME` hole" below. `HOME` is now relocated, and `GIT_CONFIG_GLOBAL` stays: it is
what keeps git hermetic even under the home escape hatch, and it is the only thing that cuts the XDG
config path.

### Identity precedence — the one accepted trade-off

`GIT_AUTHOR_*` / `GIT_COMMITTER_*` outrank a repo-local `git config user.email`. The ~8 tests that set
a local identity will therefore have that setting become a no-op. This is safe (no test asserts a
commit author) and the resulting commit identity is *more* deterministic, not less. Repo-local config
for every other key — notably `BranchLineage`'s `branch.<x>.orchestra-*` lineage SSOT — is untouched,
since we set no such keys.

## The `HOME` hole (2026-07-12)

### What broke

Every live Claude card on the board started failing *every* hook at once:

```
PreToolUse:Read hook error — /bin/sh: …/XcodeDefault.xctoolchain/usr/libexec/swift/pm/orchestra:
No such file or directory
```

The chain: `ClaudeCodeAdapter.prepareToLaunch` renders the managed `--settings` file to
`Config.hooksPath` — one **HOME-derived, shared** path, `~/Library/Application
Support/Orchestra/claude-hooks.json` — substituting `__ORCHESTRA_BIN__` with `siblingBinary("orchestra")`,
i.e. a path derived from the *running executable*. Tests call `prepareToLaunch` directly
(`AdapterTests`, and the `CodexAdapter` equivalents). Under `swift test` the running executable is
Xcode's `swiftpm-testing-helper`, so the suite resolved a nonexistent
`…/libexec/swift/pm/orchestra` and wrote **that** into the real settings file — the same file every
running Claude session was launched with (verified: all 17 live `claude` processes shared it). Claude
re-reads it mid-session, so the whole board broke the moment a test ran. The Codex equivalent
(`codex-hooks.json`) was found still holding the bogus path; it only self-heals when a Codex card next
launches.

The hooks file is the instance; the class is that **`swift test` could write the developer's live
state at all**. A full run under an instrumented home wrote all of this into it:

```
.orchestra/scratch/<uuids>/                          production scratch root
.claude/projects/<slug>/<uuid>.jsonl                 fake-agent transcripts
.claude.json                                         Claude Code's own state file
Library/Application Support/Orchestra/claude-hooks.json
Library/Application Support/Orchestra/card-settings-*.json
.codex/tmp/arg0, .local/state/gh/device-id, .zsh_history
```

### The fix

The same load-time constructor `mkdtemp`s a per-run home and `setenv("HOME", …, 1)` before the first
test of either runner. `Config.home` reads `$HOME` from the process environment on every access, so
every derived path (`dataDir`, `hooksPath`, `codexHooksPath`, `scratchRoot`, `worktreesRoot`,
`defaultReposRoot`) follows it, as does every child process — `Proc.run` rebuilds the child environment
from the test process's, so even the out-of-process `orchestrad`/`orchestra` binaries that
`E2EBinaryTests` spawns inherit the temp home.

Three details that are load-bearing:

- **It must be outside the checkout.** `Config.defaultReposRoot` *is* `$HOME` and `RepoScanner` scans
  recursively under it, so a home inside the working copy would make the suite scan itself — and
  `RepoScannerTests` asserts the root does not contain `/Documents/Projects`. `mkdtemp` under `$TMPDIR`
  (falling back to `/tmp`) is outside any checkout by construction.
- **It fails closed.** If `mkdtemp` fails, the bootstrap prints why and `abort()`s rather than letting
  the suite fall back to the real home — the fallback is the exact failure being prevented, and it
  corrupts live state rather than merely failing a test.
- **`XDG_DATA_HOME` is unset.** On Linux `Config.dataDir` prefers it over `$HOME`, so an inherited one
  would walk straight back out of the temp home.

Escape hatch: `ORCHESTRA_TEST_HOME_ISOLATION=0`, mirroring `ORCHESTRA_TEST_GIT_HERMETIC=0` — and, like
it, it cannot be silent (see the canary below).

### Lifecycle of the temp home: left for the OS to reap

Decided explicitly, not by omission. The temp home is **not** removed at exit:

- An `atexit` sweep does not run when the suite crashes or is killed, so it could never be the thing we
  rely on anyway — it would be a cleanup that works exactly when cleanup matters least.
- `E2EBinaryTests` spawns real `orchestrad`/`orchestra` processes that inherit this `HOME` and can
  outlive the test process, so deleting the tree at exit is racy.
- It lives under `$TMPDIR` (per-user `/var/folders/…` on macOS), which the OS reaps; and keeping it
  means a failed run's artifacts — the rendered hooks files, transcripts, scratch dirs — are still
  there to inspect.

### How it was verified

The canary asserts the property; the *proof* is where a full run's writes actually landed. After a
complete `swift test` with the developer's real `HOME` inherited, the per-run temp home contained the
entire list from the diagnosis above — including a `claude-hooks.json` holding the bogus
`…/XcodeDefault.xctoolchain/usr/libexec/swift/pm/orchestra` path, i.e. the exact string that broke the
board, now harmlessly inside the temp dir:

```
/var/folders/…/T/orchestra-test-home-XXXXXX/
  Library/Application Support/Orchestra/{claude-hooks,codex-hooks,card-settings-*,trust-ledger}.json
  .claude/projects/-private-var-folders-…-orch-it-e2e-…/<uuid>.jsonl     fake-agent transcript
  .orchestra/scratch/<uuid>/ , .claude.json, .zsh_history, .local/state/gh/device-id
```

The transcript is worth calling out: agents are launched with `tmux new-session -e …`, which forwards
only the variables it names, so a pane's `HOME` comes from the **tmux server**. It lands in the temp
home because the suite starts its own server (which inherits the isolated environment) — had it joined a
pre-existing one, `setenv` in the test process could not have reached it. Child agents are covered *only*
for as long as that stays true.

One trap when checking this on a live machine: the developer's real `~/Library/Application
Support/Orchestra/claude-hooks.json` may still be rewritten with the bogus path **during** a verification
run — by *other* cards running the suite from worktrees that don't have this fix. Attribute a live-home
write before blaming it on the run under test; the temp-home contents are the reliable evidence.

### Rejected alternatives (2026-07-12)

| Option | Why not |
|---|---|
| Make production `Config` detect a test bundle | A test-awareness branch in production code is the wrong structure, and invasive. The isolation belongs in the test bundle. |
| Fail-closed guard in `HooksRenderer.render` (refuse a non-executable bin path) | With the suite off the live data dir there is no realistic writer left holding a bogus path. It guards the instance, not the class. |
| Per-card settings files instead of the shared `Config.hooksPath` | The rendered content is byte-identical for every read-write Claude card, and `cardSettingsPath` keys on cwd rather than card id — so freeform cards sharing a repo root would share a file regardless. Litter without isolation. |

## The canary tests

### `GitHermeticityTests`

`Tests/OrchestraCoreTests/GitHermeticityTests.swift`, exercised through `Proc.run` (the real
production fork path), asserts:

1. `git config --global --list` yields nothing — proving the developer's `~/.gitconfig` is invisible.
2. `git config --get credential.helper` resolves empty — proving the keychain helper is disabled.
3. `GIT_CONFIG_NOSYSTEM == "1"` in the process environment.
4. A commit in a fresh temp repo **with no local identity configured** succeeds, and
   `git log -1 --format=%ae` is `test@orchestra.invalid` — proving the hermetic identity is supplied
   and the suite no longer depends on the developer having one.
5. NO inherited `GIT_*` variable survives — the environment contains exactly the set the bootstrap
   installs, asserted over the whole namespace rather than a list of known-bad names.
6. **The functional one, and the only helper assertion that is not vacuous on a clean machine:** plant a
   hostile credential helper in a temp repo at *both* the plain and the URL-scoped key, run
   `git credential fill`, and assert neither ran. Without the empty-helper reset both fire; with it,
   neither does. (A non-zero exit is expected there — with no helper, git falls through to a prompt,
   which `GIT_TERMINAL_PROMPT`/`GIT_ASKPASS` refuse. The assertion is on the helper markers, not the
   exit code.)

Assertions 1, 2, 3 and 5 are vacuous on a machine that has no global config, no helper and a clean
environment — i.e. exactly a CI box. Assertions 4 and 6 are what carry the load there.

Assertions 1–4 are skipped when `ORCHESTRA_TEST_GIT_HERMETIC=0` — but a fifth, **ungated** test always
runs and *fails* when the escape hatch is engaged. Without it the off-switch would be silent: exporting
the variable (a shell profile, a CI env block, a card's environment) would strip the suite of both its
hermeticity and its only guard, skip every canary test, and still exit 0. The opt-out stays available;
it just can never be quiet.

This is the TDD entry point: it fails on `main` today. It is also the permanent guard on the design's
single fragile assumption — if SwiftPM ever stops linking the constructor, the suite goes **red**
instead of silently reverting to reading the developer's gitconfig.

### `HomeIsolationTests`

`Tests/OrchestraCoreTests/HomeIsolationTests.swift`, the same shape (one ungated test that fails when
`ORCHESTRA_TEST_HOME_ISOLATION=0`, so the off-switch can never be quiet, plus gated ones), asserts:

1. `$HOME` is set, is **not** the real home (read from the passwd db via `getpwuid`, which `setenv`
   cannot move), and `Config.home` resolves it from the environment.
2. The temp home is an existing, writable directory outside both the real home and the repo checkout.
3. Every HOME-derived `Config` path — `dataDir`, `hooksPath`, `codexHooksPath`, `scratchRoot`,
   `defaultWorktreesRoot`, `defaultReposRoot` — lands inside it.
4. **The functional one:** it replays the write that broke the board. `ClaudeCodeAdapter.prepareToLaunch`
   is called for real; the rendered hooks file must appear under the temp home, and the live
   `~/Library/Application Support/Orchestra/claude-hooks.json` must be **byte-for-byte untouched** —
   asserted on its mtime, not just on the path.

## Explicitly out of scope

- **Suite slowness** (12k-file slow-repo fixture, per-test tmux servers, per-test git repos, 73
  hardcoded sleeps) — a separate card.
- **The cooperative-pool deadlock** that stops `swift test` from terminating on `main` — being fixed on
  `fix/nudge-leak-cooperative-pool-starvation`. Rebase onto it rather than fixing it here.
- Any change to production git behavior. The daemon must keep reading the user's real gitconfig.

## Risks

| Risk | Mitigation |
|---|---|
| SwiftPM dead-strips the constructor object, silently un-hermeticizing the suite | The canary test fails loudly. Verified today that it links in debug and release. |
| A future test genuinely needs the developer's git config | `ORCHESTRA_TEST_GIT_HERMETIC=0` escape hatch. |
| A future test genuinely needs the developer's real home (e.g. probing a real Claude transcript) | `ORCHESTRA_TEST_HOME_ISOLATION=0` escape hatch — which fails `HomeIsolationTests` by name, so it can only ever be used deliberately. |
| `mkdtemp` fails and the suite silently runs against the real home | It can't: the bootstrap `abort()`s with an explanatory message instead of falling back. |
| `GIT_CONFIG_COUNT` collides with a test that sets its own | No test does; `RemoteParents.remoteEnv()` sets neither. |
