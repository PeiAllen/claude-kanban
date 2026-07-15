import Foundation

/// A single `atexit`-backed registry of best-effort cleanups that run ONCE at process exit.
///
/// swift-testing gives struct/class suites no suite-scoped teardown hook, so a fixture generated once
/// for a whole suite (a shared tmux server, a shared template repo) has nowhere to be torn down "after
/// the last test". Process exit is exactly that point: it fires after every test in the run has finished,
/// and it cannot race a still-running case the way an eager per-case `removeItem`/`kill-server` would.
/// The registry installs ONE C trampoline (`atexit` takes a non-capturing `@convention(c)` function) and
/// fans out to every registered handler. TMPDIR reaping / tmux's own server GC remain the backstops.
private final class CleanupRegistry: @unchecked Sendable {
    static let shared = CleanupRegistry()
    private let lock = NSLock()
    private var handlers: [() -> Void] = []
    private var installed = false

    func add(_ handler: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
        if !installed {
            installed = true
            atexit { CleanupRegistry.shared.runAll() }   // non-capturing: references the global singleton only
        }
    }

    func runAll() {
        lock.lock(); let hs = handlers; handlers = []; lock.unlock()
        for h in hs { h() }
    }
}

/// Register a best-effort cleanup to run exactly once at process exit (after the last test in the run).
/// The deterministic "tear a suite-scoped fixture down once" mechanism where swift-testing offers no
/// suite teardown. Handlers must be self-contained (they run outside any test) and never throw.
public func registerProcessExitCleanup(_ body: @escaping @Sendable () -> Void) {
    CleanupRegistry.shared.add(body)
}
