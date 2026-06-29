import Foundation

/// Builds the launch recipe for a read-only `claude`. Three layers, because no single one is a
/// complete barrier on its own:
///   1. The edit tools are denied (removed from context): `--disallowedTools` + `permissions.deny`.
///   2. The OS sandbox forbids writes to the inspected directory (`filesystem.denyWrite`), run in
///      STRICT mode (`allowUnsandboxedCommands: false`) so the `dangerouslyDisableSandbox` Bash flag
///      is a no-op — otherwise a command opts itself out of the sandbox and the write-block never
///      applies. `failIfUnavailable: true` fails closed if the sandbox can't initialize.
///   3. `permissions.deny` rules for git's WRITE subcommands. This is needed because commands on the
///      user's global `sandbox.excludedCommands` list (e.g. `git`) run UNSANDBOXED — so layer 2 never
///      sees them, and `git checkout .` / `git reset --hard` / `git stash` / `git restore .` would
///      silently rewrite the working tree. `--settings` can only *add* to `excludedCommands` (arrays
///      union, verified — it can't clear them), so we instead `deny` the writes; deny beats allow and
///      is evaluated even for excluded commands. git *reads* (log/diff/show/status/blame) stay allowed.
///
/// LIMITATION: layer 3 is command-string matching, which stops accidental + naive writes but NOT a
/// determined agent (env-prefix like `GIT_WORK_TREE=x git …`, `sh -c "…"`, or a written script all
/// evade any string rule). Only an OS-level jail wrapping the whole process is adversary-proof; that
/// is deferred. Default permission mode (no `plan` framing) and NO Orchestra hooks here, so the
/// session stays untracked and can't pollute the owner card's status.
enum ReadOnlyLaunch {
    /// git subcommands that can mutate the working tree, index, refs, config, or object store.
    /// Read-only subcommands (log/show/diff/status/blame/…) are deliberately absent so a read-only
    /// card can still inspect history.
    static let gitWriteSubcommands = [
        "add", "am", "apply", "bisect", "branch", "checkout", "cherry-pick", "clean", "commit",
        "commit-tree", "config", "fast-import", "fetch", "filter-branch", "gc", "hash-object",
        "init", "maintenance", "merge", "mergetool", "mv", "notes", "pack-refs", "prune", "pull",
        "push", "rebase", "reflog", "remote", "repack", "replace", "reset", "restore", "revert",
        "rm", "sparse-checkout", "stash", "submodule", "switch", "symbolic-ref", "tag",
        "update-index", "update-ref", "worktree", "write-tree",
    ]

    /// Deny rules that block git from writing: each mutating subcommand, plus the path/config
    /// redirect flags (`-C`, `-c`, `--git-dir`, `--work-tree`, `--exec-path`) that would otherwise
    /// prefix-evade the per-subcommand rules (e.g. `git -C dir reset …`).
    static var gitWriteDenies: [String] {
        gitWriteSubcommands.map { "Bash(git \($0):*)" }
            + ["Bash(git -C:*)", "Bash(git -c:*)", "Bash(git --git-dir:*)",
               "Bash(git --work-tree:*)", "Bash(git --exec-path:*)"]
    }

    static func settingsJSON(cwd: String, gitDir: String?) -> String {
        let denyWrite = [cwd] + (gitDir.map { [$0] } ?? [])
        let deny = ["Edit", "Write", "MultiEdit", "NotebookEdit"] + gitWriteDenies
        let obj: [String: Any] = [
            "permissions": ["deny": deny],
            "sandbox": [
                "enabled": true,
                "allowUnsandboxedCommands": false,
                "failIfUnavailable": true,
                "filesystem": ["denyWrite": denyWrite],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension ReadOnlyLaunch {
    static func gitDir(repo: String, worktreeName: String) -> String {
        "\(repo)/.git/worktrees/\(worktreeName)"
    }

    static func argv(binary: String, settingsPath: String) -> [String] {
        [binary, "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit",
         "--settings", settingsPath]
    }
}
