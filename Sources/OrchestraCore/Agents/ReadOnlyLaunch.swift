import Foundation

/// Builds the launch recipe for a read-only `claude`. Three independent layers, because no single one
/// is a complete barrier:
///   1. The edit TOOLS are denied (removed from context): `--disallowedTools` + `permissions.deny`.
///   2. The OS sandbox forbids writes to the inspected dir (`filesystem.denyWrite`), run in STRICT
///      mode (`allowUnsandboxedCommands: false`) so the `dangerouslyDisableSandbox` Bash flag is a
///      no-op (otherwise a command opts out of the sandbox and the write-block never applies).
///      `failIfUnavailable: true` fails closed if the sandbox can't initialize. This deterministically
///      blocks every *sandboxable* Bash write — for free, at the kernel.
///   3. A read-only POLICY handed to the auto-mode classifier via `autoMode.hard_deny`. The classifier
///      reads these prose rules and denies anything that mutates state — and crucially it covers the
///      commands layer 2 can't: those on the user's global `sandbox.excludedCommands` list (e.g.
///      `git`) run UNSANDBOXED, so the classifier is the only thing standing between them and a write.
///      We let the classifier *judge* mutation semantically instead of maintaining a deny-list of
///      command strings (which is tied to the user's exact config, rots as the ecosystem changes, and
///      is trivially prefix-evaded by `git -C`, env-prefixes, `sh -c`, …). git *reads* stay allowed.
///      Verified: with this policy the classifier hard-blocks `git config`/`git tag`/`git checkout`
///      while letting `git log` through.
///
/// LIMITATIONS: layer 3 is the auto-mode classifier (an LLM judge) and only runs in auto mode — it is
/// best-effort, not adversary-proof (a determined agent may still craft something it misjudges). Only
/// an OS-level jail wrapping the whole process would be a hard guarantee; that is deferred. Default
/// permission mode (no `plan` framing) and NO Orchestra hooks here, so the session stays untracked.
enum ReadOnlyLaunch {
    /// Prose policy fed to the auto-mode classifier (`autoMode.hard_deny`). The classifier generalizes
    /// from it semantically, so it needs no per-command enumeration and no upkeep as tools change.
    /// Ends with default-deny-on-ambiguity so it fails closed.
    static let readOnlyPolicy =
        "READ-ONLY SESSION — deny ANY command that modifies the filesystem or the git/repository/system "
        + "state. This includes: creating, writing, deleting, moving, or truncating files; output "
        + "redirection or appends to files (>, >>, tee); in-place edits (sed -i, perl -i); git mutations "
        + "(checkout, switch, reset, restore, stash, clean, commit, add, rm, mv, branch, tag, config, "
        + "merge, rebase, push, fetch, pull); package installs; and process/service/permission changes. "
        + "Reading, searching, and inspection are allowed (e.g. cat, ls, grep, find, and read-only git "
        + "such as log, diff, show, status, blame). Treat anything ambiguous as a mutation and deny it."

    static func settingsJSON(cwd: String, gitDir: String?) -> String {
        let denyWrite = [cwd] + (gitDir.map { [$0] } ?? [])
        let obj: [String: Any] = [
            "permissions": ["deny": ["Edit", "Write", "MultiEdit", "NotebookEdit"]],
            "autoMode": ["hard_deny": [readOnlyPolicy]],
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
