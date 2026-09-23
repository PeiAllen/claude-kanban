import Foundation

/// Pure argv/env builder for every git call the daemon makes inside a store or checkout git dir.
/// No proc, no I/O — a caller runs the returned invocation through `ProcRunning`. Hermetic on every
/// call: an inherited `GIT_INDEX_FILE`/`GIT_DIR` can never redirect staging, and `--attr-source` plus
/// `core.fsmonitor=false` neutralize an agent-writable `.gitattributes`/filter driver in the checkout —
/// proven necessary: an agent-declared filter driver ran inside the daemon's git call without this pin.
public enum StoreGit {
    /// One built git invocation: argv (starting with `"git"`), its hermetic environment, and the
    /// process cwd. `hash-object <relative path>` resolves against cwd, so cwd is always the checkout.
    public struct Invocation: Sendable, Equatable {
        public let argv: [String]
        public let env: [String: String]
        public let cwd: String

        public init(argv: [String], env: [String: String], cwd: String) {
            self.argv = argv
            self.env = env
            self.cwd = cwd
        }
    }

    /// Builds one hermetic invocation. `emptyTreeHash` is computed once per process by the caller
    /// (see `emptyTreeHashArgv`) — `StoreGit` never runs a process itself, so it cannot compute it.
    public static func invocation(
        gitDir: String, workTree: String, emptyTreeHash: String, extraArgs: [String]
    ) -> Invocation {
        let argv =
            ["git", "--attr-source=\(emptyTreeHash)"]
            + configPins
            + extraArgs
        let env: [String: String] = [
            "GIT_DIR": gitDir,
            "GIT_WORK_TREE": workTree,
            "GIT_INDEX_FILE": gitDir + "/index",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_EDITOR": "true",
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        return Invocation(argv: argv, env: env, cwd: workTree)
    }

    /// The `-c` pins every invocation carries, after `--attr-source`.
    public static let configPins: [String] = [
        "-c", "user.name=Orchestra",
        "-c", "user.email=orchestra@localhost",
        "-c", "commit.gpgsign=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.autocrlf=false",
    ]

    /// Argv to compute the empty-tree hash, for `--attr-source`. Never hard-coded, so a SHA-256
    /// repository gets its own empty-tree object id.
    ///
    /// `/dev/null` as a positional argument, not `--stdin`: `ProcRunning`/`FakeProc` (the injectable
    /// proc seam) has no stdin parameter, so a positional empty file keeps this call runnable
    /// through the same seam every other call in this file uses. No `-w`: `--attr-source` accepts
    /// the empty tree's hash without the object being written to the store — verified against real
    /// git in a fresh repo with no prior `hash-object -w`. Do not "fix" this back to `-w`.
    public static let emptyTreeHashArgv: [String] = ["git", "hash-object", "-t", "tree", "/dev/null"]

    /// Argv to check the installed git version, for the minimum-version gate.
    public static let versionCheckArgv: [String] = ["git", "version"]

    /// `merge-tree --write-tree` needs git 2.38; `--attr-source` (used on every call) needs 2.40 —
    /// the stricter floor. Parses `git version X.Y.Z...` (a trailing platform suffix, e.g.
    /// "(Apple Git-154)", is ignored). Malformed output fails closed (`false`).
    public static func meetsMinimumVersion(_ versionOutput: String) -> Bool {
        guard let versionToken = versionOutput.split(separator: " ").first(where: { $0.first?.isNumber == true })
        else { return false }
        let parts = versionToken.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        return (major, minor) >= (2, 40)
    }
}
