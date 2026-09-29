import Foundation

/// Which declared paths this checkout's `.gitignore` rules actually ignore. The store shares only
/// the ignored subset, and every Orchestra writer writes on `.repo` for an ignored path and on
/// `.notARepo`, and never on `.unknown` — a probe failure must never be read as "safe to write".
///
/// **One `check-ignore -q` fork per path, not a single batched `--stdin -z` call.** Verified against
/// real git (2.54.0): `-z` is rejected outright ("fatal: -z only makes sense with --stdin") unless
/// `--stdin` is also given, and `ProcRunning`/`FakeProc` (the injectable proc seam this file uses)
/// has no stdin parameter — extending it would widen a shared seam outside this file's scope. A
/// single path needs no `-z`: `check-ignore -q -- <path>` reports its answer entirely through the
/// exit code (0 ignored, 1 not ignored, 128 fatal), so no output-parsing ambiguity exists and no
/// C-quoting of a path containing a newline is ever needed — `argv` carries it as one opaque
/// element regardless of its content. The batched form remains the more efficient shape for a large
/// candidate set; revisit once the proc seam grows stdin support.
///
/// Every probe call here runs directly in the AGENT's own checkout (not a store git dir), so it
/// deliberately does **not** use `StoreGit`'s hermetic environment — this checkout's real ignore
/// rules are exactly what must be consulted, discovered via the process cwd. `GIT_OPTIONAL_LOCKS=0`
/// is still passed explicitly: `Proc.run` merges extra environment over the daemon's own and cannot
/// unset a variable, so an ambient `GIT_DIR`/`GIT_INDEX_FILE` inherited by the daemon process could
/// otherwise redirect a read that must stay scoped to this checkout.
public enum IgnoreProbe {
    public enum IgnoreResult: Sendable, Equatable {
        case repo(ignored: Set<String>)
        case notARepo
        case unknown(detail: String)
    }

    /// `LC_ALL=C` pins the English wording `isInsideWorkTree` matches on a non-repo.
    private static let probeEnv: [String: String] = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]

    /// The exact argv `classify` runs for one candidate. Exposed so the contract tier can pin
    /// against what production actually emits, rather than a hand-copied literal that could drift
    /// out of sync with a future change here — the same class of gap that let a bad argv reach
    /// implementation once already (a batched `--stdin -z` call that real git rejects).
    static func classifyArgv(_ candidate: String) -> [String] { ["git", "check-ignore", "-q", "--", candidate] }

    /// The exact argv `ignoredByPatterns` runs for one path.
    static func ignoredByPatternsArgv(_ path: String) -> [String] { ["git", "check-ignore", "--no-index", "-q", "--", path] }

    /// Classifies `paths` (checkout-relative) against this checkout's ignore rules.
    public static func classify(_ paths: [String], inCheckout checkout: String, proc: any ProcRunning) async -> IgnoreResult {
        switch await isInsideWorkTree(checkout, proc: proc) {
        case .throwOrTimeout:
            return .unknown(detail: "rev-parse --is-inside-work-tree did not complete")
        case .no:
            return .notARepo
        case .yes:
            break
        }

        let pruned = paths.filter { !hasSymlinkedAncestor($0, checkout: checkout) }
        guard !pruned.isEmpty else { return .repo(ignored: []) }

        var ignored = Set<String>()
        for path in pruned {
            // A directory item is also probed through a synthetic `<dir>/.orchestra-probe` child,
            // because git only matches a `dir/*`-style pattern against an actual path under it.
            var candidates = [path]
            if isDirectory(path, checkout: checkout) {
                candidates.append(path.hasSuffix("/") ? path + ".orchestra-probe" : path + "/.orchestra-probe")
            }
            var pathIsIgnored = false
            candidateLoop: for candidate in candidates {
                guard
                    let result = try? await proc.run(
                        classifyArgv(candidate), cwd: checkout, env: probeEnv, timeout: .seconds(10))
                else {
                    return .unknown(detail: "check-ignore did not run for \(candidate)")
                }
                switch result.exitCode {
                case 0:
                    pathIsIgnored = true
                    break candidateLoop  // already confirmed ignored — skip probing its synthetic child
                case 1: continue
                default: return .unknown(detail: result.stderr)
                }
            }
            if pathIsIgnored { ignored.insert(path) }
        }
        return .repo(ignored: ignored)
    }

    /// `adopt`'s (PR4) re-probe by pattern: the default mode reports a still-tracked path as not
    /// ignored even when a pattern now matches it; `--no-index` reports the pattern match regardless
    /// of tracking state. Fails safe: any single path's probe failing empties the whole result,
    /// because `adopt` reads an incomplete match as "stop before `rm --cached`", never as "proceed".
    public static func ignoredByPatterns(_ paths: [String], inCheckout checkout: String, proc: any ProcRunning) async -> Set<String> {
        var ignored = Set<String>()
        for path in paths {
            guard
                let result = try? await proc.run(
                    ignoredByPatternsArgv(path), cwd: checkout, env: probeEnv, timeout: .seconds(10))
            else {
                return []
            }
            switch result.exitCode {
            case 0: ignored.insert(path)
            case 1: continue
            default: return []
            }
        }
        return ignored
    }

    private enum WorkTreeCheck { case yes, no, throwOrTimeout }

    /// Three completed answers count as "not inside a work tree" (`.no`): exit 0 with stdout other than
    /// `true` (a bare repository answers `false` with exit 0 — verified against real git), and exit 128 whose
    /// stderr says `not a git repository`. Any OTHER completed failure — a corrupt or unreadable git config,
    /// a killed timeout — has empty stdout too, but it is not proof of a non-repo. It is `.throwOrTimeout`,
    /// which classify() maps to `.unknown`, never to the write-permitting `.notARepo`.
    private static func isInsideWorkTree(_ checkout: String, proc: any ProcRunning) async -> WorkTreeCheck {
        guard
            let result = try? await proc.run(
                ["git", "rev-parse", "--is-inside-work-tree"], cwd: checkout, env: probeEnv, timeout: .seconds(10))
        else {
            return .throwOrTimeout
        }
        if result.exitCode == 0 {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" ? .yes : .no
        }
        // A worktree with a dangling `.git` gitfile (its real gitdir was pruned or moved) fails with the SAME
        // "not a git repository" wording as a plain non-repo directory. That is a broken repo, not a proven
        // absent one, so `.git` existing at all — file or directory — keeps it `.throwOrTimeout` → `.unknown`.
        guard result.stderr.contains("not a git repository") else { return .throwOrTimeout }
        return FileManager.default.fileExists(atPath: checkout + "/.git") ? .throwOrTimeout : .no
    }

    /// True when any directory strictly between `checkout` and `path`'s parent is a symlink.
    /// Component-wise, not a raw string prefix check, so `/foo/bar2` never matches ancestor
    /// `/foo/bar`.
    static func hasSymlinkedAncestor(_ path: String, checkout: String) -> Bool {
        let checkoutComponents = (checkout as NSString).pathComponents
        let fullPath = (checkout as NSString).appendingPathComponent(path)
        let relativeComponents = Array((fullPath as NSString).pathComponents.dropFirst(checkoutComponents.count))
        guard relativeComponents.count > 1 else { return false }
        var ancestorComponents = checkoutComponents
        for component in relativeComponents.dropLast() {
            ancestorComponents.append(component)
            let ancestorPath = NSString.path(withComponents: ancestorComponents)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: ancestorPath),
                let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink
            {
                return true
            }
        }
        return false
    }

    static func isDirectory(_ path: String, checkout: String) -> Bool {
        let fullPath = (checkout as NSString).appendingPathComponent(path)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
    }
}
