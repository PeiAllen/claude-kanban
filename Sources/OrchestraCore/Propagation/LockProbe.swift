import Foundation

/// Whether any live process holds a git lock file open. Exists because a crash mid-write leaves a
/// lock file (`index.lock`, etc.) that fails every later git call forever, unless something can
/// prove no live process holds it. The caller (`PropagationService`, PR4) removes an unheld lock
/// once, with a warning, and retries the failed call once; a held lock is `.busy` and left alone.
///
/// One call site, one behavior, regardless of platform: `lsof -t <lock>` on macOS, a scan of
/// `/proc/*/fd` on Linux. Each platform's OS-specific glue is a thin, untestable shim around a pure
/// parse/match function, so the actual logic unit-tests without a real process or a real `/proc`.
public enum LockProbe {
    /// `lsof -t <lock>` on macOS, via the injected proc seam. Returns `nil` when the probe itself
    /// didn't complete (spawn failure, timeout) — distinct from an empty set, which means the probe
    /// ran and found no holder. The caller (`PropagationService`, PR4) must treat `nil` as `.busy`:
    /// a probe that never ran is not proof that nobody holds the lock, and removing a lock on that
    /// unproven basis would race a live writer.
    public static func holders(_ lockPath: String, proc: any ProcRunning) async -> Set<Int32>? {
        #if os(Linux)
        return linuxHolders(lockPath)
        #else
        guard let result = try? await proc.run(["lsof", "-t", lockPath], cwd: nil, env: [:], timeout: .seconds(10))
        else { return nil }
        // A genuine "no holder" answer is empty stdout AND empty stderr (exit 1) — verified. `lsof`
        // failing on its own terms (a bad path, a permission error) also exits non-zero with empty
        // stdout, but leaves a usage dump or an error on stderr; that case must not be read the same
        // way as a clean "nobody holds this", since PR4 only reaches this call after a lock file's
        // own git error, so it's always expected to exist.
        guard result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parsePIDs(result.stdout)
        #endif
    }

    /// Pure: parses `lsof -t` output (one PID per line) into a PID set. Unparseable lines are
    /// dropped rather than failing the whole parse.
    public static func parsePIDs(_ lsofOutput: String) -> Set<Int32> {
        Set(lsofOutput.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Pure: which of the given `(pid, fd-symlink-target)` pairs point at `lockPath` — the Linux
    /// probe's matching logic, separated from its `/proc` walk so it unit-tests without a real
    /// filesystem.
    public static func matchingHolders(fdTargets: [(pid: Int32, target: String)], lockPath: String) -> Set<Int32> {
        Set(fdTargets.filter { $0.target == lockPath }.map(\.pid))
    }

    #if os(Linux)
    private static func linuxHolders(_ lockPath: String) -> Set<Int32> {
        var fdTargets: [(pid: Int32, target: String)] = []
        guard let procEntries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        for entry in procEntries {
            guard let pid = Int32(entry) else { continue }
            let fdDir = "/proc/\(entry)/fd"
            guard let fds = try? FileManager.default.contentsOfDirectory(atPath: fdDir) else { continue }
            for fd in fds {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: fdDir + "/" + fd) {
                    fdTargets.append((pid, target))
                }
            }
        }
        return matchingHolders(fdTargets: fdTargets, lockPath: lockPath)
    }
    #endif
}
