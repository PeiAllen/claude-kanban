# Git hermeticity for the test suite

**Date:** 2026-07-11
**Status:** approved (design)
**Card:** `test/git-hermeticity`

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

### 1. It clears the git state it INHERITED

Controlling git's *config* is not sufficient on its own — git reads more of its behavior from the
environment, and an inherited value silently defeats the scheme. Two matter, both demonstrated live:

- **`GIT_CONFIG_PARAMETERS`** is the older form of `-c`, and is parsed **in addition to**
  `GIT_CONFIG_COUNT`. An inherited one injects config straight past our overrides: with the full set of
  variables below in place, `GIT_CONFIG_PARAMETERS="'credential.helper=!…'"` still **ran the helper**.
- **`GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE`** point git at a *different
  repository*, overriding even an explicit `git -C <tmpdir>`. Demonstrated: with `GIT_DIR` inherited,
  `git -C target config orchestra.probe HIJACKED` wrote into the **other repo**. A test's commits and
  config writes could therefore land in the developer's real repository.

These are inherited for real whenever the suite runs from inside a git operation — a hook, an alias, a
rebase's `exec` step. So the bootstrap `unsetenv`s them first: the two above plus `GIT_CONFIG`,
`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`, `GIT_PREFIX`,
`GIT_CEILING_DIRECTORIES`, `GIT_INDEX_VERSION`, `GIT_TEMPLATE_DIR` (which would seed hooks into every
`git init` a test runs), and `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` (an inherited fixed date would
stamp every test commit).

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

### HOME is deliberately left alone

The original brief asked for a temp `HOME`. It is **redundant**: once `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_NOSYSTEM` are set, git never consults `HOME` for configuration at all. The only other
`HOME`-derived git input is `~/.git-credentials`, which is read solely by `credential.helper = store`
— and no helper survives the settings above.

Meanwhile, overriding `HOME` process-wide *would* change what every **non-git** test sees: the trust
ledger (`~/.claude.json`), `Config.dataDir`, and Claude transcript discovery all read the real home
directory. Pinning a temp `HOME` would therefore buy nothing for git while forcing an audit-and-fix
sweep across unrelated tests. Decision: leave `HOME` untouched; keep the blast radius to git.

### Identity precedence — the one accepted trade-off

`GIT_AUTHOR_*` / `GIT_COMMITTER_*` outrank a repo-local `git config user.email`. The ~8 tests that set
a local identity will therefore have that setting become a no-op. This is safe (no test asserts a
commit author) and the resulting commit identity is *more* deterministic, not less. Repo-local config
for every other key — notably `BranchLineage`'s `branch.<x>.orchestra-*` lineage SSOT — is untouched,
since we set no such keys.

## The canary test

`Tests/OrchestraCoreTests/GitHermeticityTests.swift`, exercised through `Proc.run` (the real
production fork path), asserts:

1. `git config --global --list` yields nothing — proving the developer's `~/.gitconfig` is invisible.
2. `git config --get credential.helper` resolves empty — proving the keychain helper is disabled.
3. `GIT_CONFIG_NOSYSTEM == "1"` in the process environment.
4. A commit in a fresh temp repo **with no local identity configured** succeeds, and
   `git log -1 --format=%ae` is `test@orchestra.invalid` — proving the hermetic identity is supplied
   and the suite no longer depends on the developer having one.
5. The inherited-state variables above are absent from the process environment.
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
| `GIT_CONFIG_COUNT` collides with a test that sets its own | No test does; `RemoteParents.remoteEnv()` sets neither. |
