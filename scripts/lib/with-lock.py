#!/usr/bin/env python3
"""Run a command under a named, machine-wide mutex — the build/ship throttle.

    with-lock.py <name> -- <cmd> [args...]

WHY THIS EXISTS
    Measured on an 18-core box: one cold `swift build --build-tests` takes 165s; THREE
    concurrent ones take 520s EACH. Degradation is super-linear, so build concurrency has
    negative value — serializing is faster in total AND keeps the machine responsive
    (daemon RPC p95: 22ms under 3 builds vs 6.5ms under 1). See
    notes/designs/build-contention.md.

DESIGN NOTES (each one is load-bearing; see the design doc for the reviews that forced them)

  * Wrap COMMANDS, never whole SCRIPTS. `flock` releases on last close of the *file
    description*, so any descendant that inherits the fd keeps holding the lock. Scripts
    like iso-stack.sh/orch-test.sh background a daemon that outlives them — wrapping those
    would strand the machine-wide mutex for hours. We therefore spawn the child WITHOUT
    the lock fd (close_fds=True) and hold the lock in THIS process only.

  * Lock file lives in the git common dir: shared by every worktree of the repo (the
    correct scope), already sandbox-writable, and never deleted. NOT ~/.orchestra/locks —
    `reset-state.sh` does `rm -rf ~/.orchestra`, and since flock locks the INODE, not the
    path, deleting it while held would let a second builder create a fresh inode and
    acquire it, silently losing mutual exclusion.

  * FAIL OPEN on timeout. Callers impose deadlines that KILL: Claude Code's Bash tool caps
    at 600s, and `orchestra exec` defaults to a 120s timeout that kills on expiry. A build
    that waited and then got killed would be a build that FAILS because of this lock. So
    after ORCH_BUILD_LOCK_TIMEOUT (default 300s) we run the command anyway, unlocked, and
    say so loudly. Worst case degrades to today's behaviour (an extra concurrent build —
    slow), never to a broken build. A hung holder can never wedge the repo.

  * The wait is VISIBLE: re-emitted every 15s, not printed once and left to go stale.
"""
import fcntl
import os
import subprocess
import sys
import time

WAIT_POLL = 0.25
NOTIFY_EVERY = 15.0
DEFAULT_TIMEOUT = 300.0


def lock_path(name: str) -> str:
    """Lock file in the git common dir — shared by all worktrees of the repo."""
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        common = ".git"
    if not os.path.isabs(common):
        common = os.path.abspath(common)
    return os.path.join(common, f"orchestra-{name}.lock")


def holder_of(path: str) -> str:
    """Best-effort holder pid. BSD flock cannot report it, so the holder writes it in."""
    try:
        with open(path) as fh:
            pid = fh.read().strip()
        return pid or "?"
    except OSError:
        return "?"


def main() -> int:
    if "--" not in sys.argv[1:]:
        sys.exit("usage: with-lock.py <name> -- <cmd> [args...]")
    name = sys.argv[1]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    if not cmd:
        sys.exit("usage: with-lock.py <name> -- <cmd> [args...]")

    timeout = float(os.environ.get("ORCH_BUILD_LOCK_TIMEOUT", DEFAULT_TIMEOUT))
    path = lock_path(name)

    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        start = time.monotonic()
        have_lock = False
        announced = 0.0
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                have_lock = True
                break
            except OSError:
                pass  # held by someone else
            waited = time.monotonic() - start
            if waited >= timeout:
                print(
                    f"[{name}-lock] WARNING: waited {waited:.0f}s (limit {timeout:.0f}s) — "
                    f"proceeding WITHOUT the lock so this build cannot be killed by a "
                    f"caller timeout. Expect contention.",
                    file=sys.stderr, flush=True,
                )
                break
            if waited - announced >= NOTIFY_EVERY or announced == 0.0:
                announced = waited
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
                pass  # the pid is only ever used for a log line

        # close_fds=True (the default) keeps the lock fd OUT of the child, so a daemonised
        # grandchild can never inherit and strand the mutex.
        return subprocess.call(cmd, close_fds=True)
    finally:
        os.close(fd)  # releases the flock if we held it


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
