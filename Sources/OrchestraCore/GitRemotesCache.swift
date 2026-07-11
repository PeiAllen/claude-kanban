import Foundation

/// Per-repo memo of `git remote` output, keyed by the repo's `.git/config` mtime so a mid-run
/// `git remote add/remove` invalidates it (no-behavior-change). Callable from `nonisolated` git-probe
/// code, so it owns its own lock rather than relying on actor isolation.
final class GitRemotesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (mtime: Date?, value: [String])] = [:]
    func remotes(repo: String, configMtime: Date?, compute: () -> [String]) -> [String] {
        lock.lock()
        if let hit = cache[repo], hit.mtime == configMtime { lock.unlock(); return hit.value }
        lock.unlock()
        let v = compute()
        lock.lock(); cache[repo] = (configMtime, v); lock.unlock()
        return v
    }
}

/// `Sendable`-locked holder for the `computeTreeStat` test probe (PR5 actor-hygiene, Task 5.1.4). A test
/// injects a blocking probe via `OrchestraService._setTreeProbeForTest`; `recomputeTreeStat` reads it
/// ON-ACTOR and passes it as a call-scoped argument into the `nonisolated computeTreeStat` — the probe is
/// never read as actor state from inside the offActor hop (that would reintroduce a data race). `nil` in
/// production.
final class TreeProbeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var probe: (@Sendable () -> Void)?
    func get() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return probe
    }
    func set(_ p: (@Sendable () -> Void)?) {
        lock.lock(); probe = p; lock.unlock()
    }
}
