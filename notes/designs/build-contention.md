# Killing the build tax — measured

**Status:** design v2 (rewritten after two adversarial reviews)
**Branch:** `perf/build-cache-and-contention`
**Scope:** repo-local (claude-kanban). **No Orchestra/daemon changes.**

---

## TL;DR

The "8m36s cold build" is not a cold-build cost. **It is contention.** A cold build alone
takes **165s**. Three cards building at once take **520s each** — and 520s *is* the 8m36s.

The fix is a **build mutex, not a cache**. Both caching directions in the brief were tested
and rejected on evidence.

**Be honest about the size of the win.** With N=1, three cards that want to build finish at
165s / 330s / 495s. Only the *first* gets 165s.

| | before | after | |
|---|---|---|---|
| total wall for 3 cards' builds | 520s | ~495s | **−5%. Marginal.** |
| time to *first* build result | 520s | **165s** | **3.1× — real** |
| daemon p95 while 3 cards build | 22.0 ms | ~6.5 ms | **3.4× — real** |
| a queued build | silently 3× slower | **visibly queued, bounded** | predictability |

So we serialize for **responsiveness and predictability**, *not* throughput. An earlier
draft of this doc claimed "a new card's first build: 520s → 165s" for any card. That was
wrong — only the lock winner sees 165s — and the claim is retracted.

---

## Measurements

18-core / 64 GB / APFS. Every timing run was gated on machine quiescence and marked INVALID
if a foreign build appeared mid-run. Without that gate every number on this machine is
garbage — which is itself the thesis.

### Concurrency is the tax

| concurrent builds | wall each | all done at | vs serializing | daemon p50 | daemon p95 |
|---|---|---|---|---|---|
| idle | — | — | — | 1.4 ms | 3.8 ms |
| 1 | **165s** | 165s | — | 1.1 ms | 6.5 ms |
| 2 | 444s | 444s | 330s → serial wins | 0.8 ms | 22.3 ms |
| 3 | **520 / 521 / 522s** | 520s | 495s → serial wins | 7.0 ms | 22.0 ms |
| 3 + `taskpolicy -b` | 542 / 542 / 544s | 544s | — | 5.1 ms | 26.6 ms |

Degradation is **super-linear** (2 concurrent builds are 2.7× slower *each*). No level of
build concurrency pays for itself, so N=1 trades away no throughput.

**Not CPU-bound:** ~40% busy / **60% idle** at **load 28** during a cold build — dozens of
`swift-frontend` processes exist but are *blocked*. (The brief's "~105% CPU, essentially
serial" came from `/usr/bin/time`, which only counts reaped children.) **Not memory:** 64 GB,
572 MB swap, no pressure. It is I/O/lock-bound. The exact contended resource is not
identified — **and the prescription does not depend on it**, which is why serializing was
validated directly rather than inferred.

### Rejected on evidence

1. **Clone-seeding `.build` — REJECTED.** A whole-directory `clonefile()` seeds 3.9 GB in
   **0.88s / 12 MB** (`cp -c -R` takes **148s** — it clones each of 32,230 files). But the
   seeded worktree **recompiled all 655 tasks anyway**. SwiftPM's build DB is keyed on
   **absolute source paths**. Cloned Clang `.pcm`s are worse than useless: they embed their
   absolute module-cache path, are rejected every build, and the build never converges.
   Seeding buys only `.build/checkouts` (offline dependency resolution) — **zero seconds**.
2. **Shared `--scratch-path` — REJECTED**, same absolute-path keying: cards would each force
   a *full* rebuild and thrash the shared dir.
3. **`taskpolicy -b` — REJECTED.** ~4% *slower*, no p95 improvement.
4. **Building less — REJECTED.** `swift test` does **not** skip the MCP/swift-nio tree
   (123 compile lines either way).

### Sandbox: documented, not fixed

Sandboxed `swift build` **cannot run at all** — SwiftPM wraps manifest compilation in its
own `sandbox-exec`, which cannot nest inside Claude Code's Seatbelt
(`sandbox_apply: Operation not permitted`); the build dies in 13–21s having compiled
nothing. Making it work needs `--disable-sandbox` **and** write access to the two SwiftPM
cache dirs.

**We are not shipping that**, for a concrete reason: `.claude/settings.json` is
**gitignored** (`.gitignore:3-5`; `git ls-files .claude/` → only `commands/ship.md`) and does
not exist in this repo. Sandbox config lives in the *user's* `~/.claude/settings.json`, so a
repo change could never reach another card's worktree. `--disable-sandbox` would also weaken
SwiftPM's manifest/plugin sandbox for humans and CI to serve the agent case.

`docs/08-building-operations.md:52` already says to run these unsandboxed. We keep that,
and document the root cause. (DoD: *"or you have shown they don't matter, with evidence"*.)

---

## Design

**One rule makes the whole thing safe: wrap individual build COMMANDS, never whole SCRIPTS.**

Two earlier drafts died on this. `iso-stack.sh:195` and `orch-test.sh:133` **background a
daemon that outlives the script**. Had the lock wrapped those scripts:
- the daemon would inherit the lock fd — and `flock` releases on last close of the *file
  description*, so the machine-wide build mutex would be **held for the daemon's lifetime**;
- an env-based re-entrancy marker would land in the daemon's environment, then in every
  agent it spawns, **silently disabling locking for every card on that stack**.

Wrapping only build commands (`swift build`, `swift test`, `xcodebuild` — none of which
daemonize) means the lock's child is always a short-lived compiler. It also means **nothing
nests**, so **no re-entrancy guard is needed at all** — deleting an entire class of bugs.

### `scripts/lib/with-lock.sh <name> -- <cmd…>`

- Lock file: `$(git rev-parse --git-common-dir)/orchestra-<name>.lock`. Every worktree of the
  repo resolves to the same one (correct scope: all cards of a repo share it), it is already
  **sandbox-writable**, and nothing deletes it. **Not `~/.orchestra/locks/`**:
  `reset-state.sh:60` does `rm -rf "$HOME/.orchestra"`, and since `flock` locks the **inode,
  not the path**, deleting the file while held would let a second builder create a fresh
  inode and acquire it — **silently losing mutual exclusion**. It is also outside the
  sandbox's writable set.
- A **holder process** takes the lock and spawns the command with `close_fds` (the lock fd is
  *not* inherited), then waits. The kernel releases the lock when the holder exits — so a
  crashed or `kill -9`'d build cannot strand it, and no descendant can leak it.
- Writes its pid into the lock file, because BSD `flock` **cannot report the holder** (only
  POSIX record locks expose `l_pid`, and those have semantics we can't use). This pid is the
  design's only shared mutable state; a stale pid can produce a wrong *log line* and nothing
  else.
- Polls with `LOCK_NB` and **re-emits the wait message every 15s** to stderr, so a card that
  waits 5 minutes says so continuously rather than printing one instantly-stale line.

**Bounded wait, failing OPEN — the reliability requirement.** Callers impose deadlines we
must respect: Claude Code's Bash tool caps at **600s**, and `orchestra exec` defaults to a
**120s** timeout whose expiry *kills* the process (`Proc.run`). A build that waited and then
got killed would be a build that **fails because of our lock** — violating "nothing may make
a single card's build less reliable." So the helper waits at most `ORCH_BUILD_LOCK_TIMEOUT`
(**default 300s**) and then **runs the build anyway, unlocked, with a loud warning**. Worst
case degrades to today's behaviour (an extra concurrent build — slow), never to a broken or
killed one. This also means a hung holder can never wedge the repo, and it keeps
`orch-ux-e2e.sh:140`'s pre-existing 20-minute "build lock stuck" abort from ever firing on
our account.

### Lock 1 — build mutex (N=1)

Wraps each `swift build` / `xcodebuild` invocation. N=1 chosen on evidence (N=2 and N=3 both
lose to serial).

**`swift test` compiles under the lock but RUNS outside it**: `scripts/test.sh` becomes
`with-lock build -- swift build --build-tests` followed by an unlocked
`swift test --skip-build`. Test *execution* is tmux/socket/sleep-bound, not the contended
resource; serializing it would cost throughput with no evidence behind it.

### Lock 2 — ship mutex

`/ship` is a **markdown recipe run as separate agent tool calls**, and an `flock` lives only
as long as the process holding it. A lock "held across merge → build → relaunch" is therefore
**impossible** — an earlier draft specified exactly that, and it would have double-acquired
and wedged the whole board. Retracted.

What is actually implementable, and sufficient:

1. **The merge is one locked command.** `with-lock ship -- git merge …` inside the main
   checkout. `/ship` (and `AGENTS.md`, the Codex twin) additionally require: **on conflict,
   `git merge --abort` immediately** — so the shared main checkout is *never left dirty
   between agent turns*. That dissolves the need to hold a lock across turns: resolve on your
   own branch, then retry the merge.
2. **`build-app.sh` takes the ship lock** (`--strict`) by re-exec'ing itself under it, covering
   `xcodegen generate` rewriting the shared `App/Orchestra.xcodeproj`, the `xcodebuild`, and the
   install into `/Applications/Orchestra.app` — today two overlapping ships can interleave a
   project regeneration with a build and leave a half-written bundle. It sits in `build-app.sh`
   rather than `build-and-launch-app.sh` so that a *direct* `build-app.sh` call is protected too;
   `build-and-launch-app.sh` calls it, so the lock is still taken exactly once per tree (flock is
   not recursive — a second acquisition would hang against our own ancestor).

   The re-exec sentinel is an **argv flag, not an environment variable**: macOS `open`
   propagates the caller's environment into the launched app, so an env marker would leak into
   `Orchestra.app` and — if the daemon were ever spawned as its child — silently disable the lock
   board-wide. That is the exact leak class this design forbids elsewhere; argv cannot leak that way.

   **`--strict` never fails open.** The build mutex only throttles, so proceeding unlocked after a
   timeout is safe (it degrades to today's behaviour). The ship mutex guards *real shared state*,
   where proceeding unlocked would produce the half-written bundle we are trying to prevent — so it
   waits long and then **fails closed** with an error. Two locks, two policies; conflating them
   (one timeout for both) was a bug caught in review.

Lock order is **ship ⊐ build** (a ship's inner `swift build`s take the build lock). Nothing
under the build lock ever reaches for the ship lock, so there is no cycle. `orch-ux-e2e.sh`'s
pre-existing `mkdir`-based build lock (`:127-144`) is a **third** lock: it orders
consistently (mkdir ⊐ flock) and **is kept, not replaced** — it guards shared DerivedData
(real shared state), whereas ours only throttles.

### Why this cannot race

**Nothing is shared.** Every card keeps its own `.build`. The build mutex limits *how many*
builds run, not *where* they write. A lock that guards no shared mutable state cannot corrupt
anything: a bug in it yields "too many builds ran" (today's behaviour) or "a build waited" —
never a bad artifact. This is exactly why the shared-`.build` designs were dangerous and this
one is not. The ship mutex *does* guard shared state (the main checkout, the xcodeproj,
`/Applications`), which is why it is a strict mutex with no fail-open.

### Enforcement — honest about its limit

Repo-local, so enforcement is **advisory**: the lock lives in `scripts/`, mandated by
`CLAUDE.md` + `AGENTS.md` (one instruction, identical for both agent backends — plain shell
and docs, no `if agent == …` anywhere). An agent that types raw `swift build` bypasses it and
degrades to **today's behaviour** — slow, never incorrect. Closing that hole would need a
daemon-injected PATH shim, which would put `swift`-specific knowledge into a general-purpose
orchestrator: **out of scope by owner decision.**

### Keeping the baseline from creeping back (owner's standing rule)

The mutex caps the damage from *concurrency*; it does nothing about the **165s baseline that
concurrency multiplies**. `OrchestraCoreTests` is already the largest target in the repo
(123 files / 17k lines vs OrchestraCore's 64 / 10k), and `swift test` cannot skip the
dependency tree — so every added target and test raises that baseline permanently, for every
card, forever. `CLAUDE.md` gains a standing note: **keep the test suite tiered as code is
added; do not let it re-clump into one monolithic target.** (`perf/tiered-test-suite` is
doing the tiering.)

---

## Verification plan

1. Lock helper unit tests: two processes contend → strictly serialized; holder `kill -9`'d →
   lock released, waiter proceeds; wait exceeding the timeout → **proceeds unlocked**, exit
   code preserved; a backgrounded grandchild does **not** inherit the lock.
2. Re-run the contention harness *through the locked scripts*: 3 cards' builds serialize,
   each ≈165s, daemon p95 stays at the 1-build level (~6.5ms).
3. Uncontended build wall-clock unchanged (no regression from taking a free lock).
4. `swift test --skip-build` runs the suite green outside the lock.

## Non-goals

- Any Orchestra/daemon change; a generic named-semaphore primitive (deferred until a second
  repo wants one).
- `Proc.run` cooperative-pool starvation — owned by `fix/nudge-leak-cooperative-pool-starvation`.
  Complementary: that fixes the daemon's *own* blocking; this removes the load that exposes it.
