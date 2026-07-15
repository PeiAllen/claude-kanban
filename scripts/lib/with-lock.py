#!/usr/bin/env python3
"""Run a command under a named, machine-wide mutex — the build/ship throttle.

    with-lock.py [--strict] <name> -- <cmd> [args...]

WHY THIS EXISTS
    Measured on an 18-core box: one cold `swift build --build-tests` takes 165s; THREE
    concurrent ones take 520s EACH. Degradation is super-linear, so build concurrency has
    negative value — serializing is faster in total AND keeps the machine responsive
    (daemon RPC p95: 22ms under 3 builds vs 6.5ms under 1). See
    notes/designs/build-contention.md.

TWO LOCK POLICIES — they are not interchangeable
  * default (the BUILD lock) — FAILS OPEN. It only throttles; it guards no shared state.
    Callers impose deadlines that KILL: `orchestra exec` defaults to 120s and kills on
    expiry, and Claude Code's Bash tool caps at 600s. A build that queued and was then
    killed would be a build that FAILS because of this lock. So after a bounded wait we run
    the command anyway, unlocked, and say so loudly. Worst case degrades to the old
    behaviour (an extra concurrent build — slow), never to a broken build.
  * --strict (the SHIP lock) — NEVER fails open. It guards real shared state (the main
    checkout, App/Orchestra.xcodeproj, /Applications/Orchestra.app). Proceeding unlocked
    there would produce a half-written app bundle — strictly worse than waiting. So it waits
    (a long time), and if it truly cannot acquire, it FAILS CLOSED with an error rather than
    corrupting anything.

OTHER LOAD-BEARING DETAILS (each one is a bug a review caught)
  * The lock fd is never inherited by the child (`close_fds`, and PEP 446 makes os.open fds
    non-inheritable). A daemonised grandchild — iso-stack.sh/orch-test.sh background a
    daemon that outlives the script — must not be able to hold the machine-wide mutex.
  * SIGTERM/SIGINT/SIGHUP are FORWARDED to the child and we wait for it. Otherwise a killed
    wrapper would drop the flock while the compiler kept running unlocked, and another card
    would immediately start a second concurrent build against it.
  * The lock path is derived from THIS FILE's location, not the cwd. `orch-test.sh` never
    cds to the repo root, and CLAUDE.md tells agents to call this from anywhere.
  * Acquisition NEVER kills the build: any unexpected error while locking degrades to
    running unlocked (except under --strict).
"""
import fcntl
import os
import signal
import subprocess
import sys
import time

WAIT_POLL = 0.25
NOTIFY_EVERY = 15.0

# The fail-open bound must EXCEED the queue it is meant to absorb, or it defeats the lock.
# Measured the hard way: at 300s, three contending cards each waited out the timeout, gave up,
# ran unlocked, and re-created the very concurrency the mutex exists to prevent (walls went
# 450s/1025s/1025s instead of ~165/330/495). A clean queue of N cards makes the last one wait
# (N-1) x 165s, so 300s is under water at N=3.
#
# 1200s covers a realistic queue (~7 deep) and only trips on a pathological/stuck holder. It
# does NOT introduce a new failure mode: today three concurrent builds take 520s EACH, so a
# card that queues is strictly better off than it is now — and a build long enough to hit a
# caller's deadline was already hitting it before this change.
DEFAULT_TIMEOUT = 1200.0         # build lock: bounded, then fail OPEN
DEFAULT_STRICT_TIMEOUT = 3600.0  # ship lock: long, then fail CLOSED (never unlocked)


def repo_root() -> str:
    """Repo root from THIS FILE (scripts/lib/with-lock.py), never from the cwd."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def lock_path(name: str) -> str:
    """Lock file in the git common dir — one per repo, shared by every worktree.

    NOT ~/.orchestra/locks: reset-state.sh does `rm -rf ~/.orchestra`, and flock locks the
    INODE, not the path — deleting the file while held would let a second builder create a
    fresh inode and acquire it, silently losing mutual exclusion.
    """
    root = repo_root()
    common = subprocess.run(
        ["git", "-C", root, "rev-parse", "--git-common-dir"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not os.path.isabs(common):
        common = os.path.join(root, common)
    return os.path.join(os.path.abspath(common), f"orchestra-{name}.lock")


def holder_of(path: str) -> str:
    """Best-effort holder pid. BSD flock cannot report it, so the holder writes it in."""
    try:
        with open(path) as fh:
            return fh.read().strip() or "?"
    except OSError:
        return "?"


def run_forwarding_signals(cmd) -> int:
    """Run cmd, forwarding termination signals to it, and wait. Returns a shell-style code.

    Critical: we must NOT die while the child keeps running — that would release the flock
    and leave an unlocked compiler racing the next card's build.
    """
    proc = subprocess.Popen(cmd, close_fds=True)

    def forward(signum, _frame):
        try:
            proc.send_signal(signum)
        except ProcessLookupError:
            pass

    previous = {}
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            previous[sig] = signal.signal(sig, forward)
        except (ValueError, OSError):
            pass
    try:
        while True:
            try:
                rc = proc.wait()
                break
            except KeyboardInterrupt:
                forward(signal.SIGINT, None)
    finally:
        for sig, handler in previous.items():
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass
    # subprocess returns -N when killed by signal N; shells report 128+N.
    return 128 - rc if rc < 0 else rc


def main() -> int:
    argv = sys.argv[1:]
    strict = False
    if argv and argv[0] == "--strict":
        strict = True
        argv = argv[1:]
    if "--" not in argv or not argv:
        sys.exit("usage: with-lock.py [--strict] <name> -- <cmd> [args...]")
    name = argv[0]
    cmd = argv[argv.index("--") + 1:]
    if not cmd:
        sys.exit("usage: with-lock.py [--strict] <name> -- <cmd> [args...]")

    env_key = f"ORCH_{name.upper()}_LOCK_TIMEOUT"
    default = DEFAULT_STRICT_TIMEOUT if strict else DEFAULT_TIMEOUT
    try:
        timeout = float(os.environ.get(env_key, os.environ.get("ORCH_BUILD_LOCK_TIMEOUT", default)))
    except ValueError:
        timeout = default  # a malformed setting must never stop a build

    try:
        path = lock_path(name)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    except Exception as exc:  # noqa: BLE001 — the lock must never be the thing that fails
        if strict:
            sys.exit(f"[{name}-lock] FATAL: cannot open lock file: {exc}")
        print(f"[{name}-lock] WARNING: cannot open lock file ({exc}) — running UNLOCKED.",
              file=sys.stderr, flush=True)
        return run_forwarding_signals(cmd)

    try:
        start = time.monotonic()
        have_lock = False
        first = True
        announced = 0.0
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                have_lock = True
                break
            except OSError:
                pass  # held elsewhere
            waited = time.monotonic() - start
            if waited >= timeout:
                if strict:
                    sys.exit(
                        f"[{name}-lock] FATAL: could not acquire after {waited:.0f}s. "
                        f"Refusing to proceed unlocked — this lock guards shared state "
                        f"(main checkout / xcodeproj / /Applications). Holder pid "
                        f"{holder_of(path)}. Retry, or clear a stuck holder."
                    )
                print(
                    f"[{name}-lock] WARNING: waited {waited:.0f}s (limit {timeout:.0f}s) — "
                    f"proceeding WITHOUT the lock so a caller timeout cannot kill this build. "
                    f"Expect contention.",
                    file=sys.stderr, flush=True,
                )
                break
            if first or waited - announced >= NOTIFY_EVERY:
                first, announced = False, waited
                print(
                    f"[{name}-lock] waiting for slot (held by pid {holder_of(path)}) — "
                    f"{waited:.0f}s elapsed…",
                    file=sys.stderr, flush=True,
                )
            time.sleep(WAIT_POLL)

        if have_lock:
            waited = time.monotonic() - start
            if waited >= NOTIFY_EVERY:
                print(f"[{name}-lock] acquired after {waited:.0f}s", file=sys.stderr, flush=True)
            try:
                os.ftruncate(fd, 0)
                os.write(fd, f"{os.getpid()}\n".encode())
                os.fsync(fd)
            except OSError:
                pass  # the pid only ever feeds a log line

        return run_forwarding_signals(cmd)
    finally:
        os.close(fd)  # releases the flock if held


if __name__ == "__main__":
    sys.exit(main())
