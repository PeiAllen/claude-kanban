import Foundation

/// Builds the launch recipe for a read-only `claude`: two independent locks — the edit tools are
/// denied (removed from context) and the OS sandbox forbids writes to the inspected directory (the
/// Bash escape hatch). Default permission mode (no `plan` framing) and NO Orchestra hooks, so the
/// session stays untracked and can't pollute the owner card's status.
enum ReadOnlyLaunch {
    static func settingsJSON(cwd: String, gitDir: String?) -> String {
        let denyWrite = [cwd] + (gitDir.map { [$0] } ?? [])
        let obj: [String: Any] = [
            "permissions": ["deny": ["Edit", "Write", "MultiEdit", "NotebookEdit"]],
            "sandbox": ["filesystem": ["denyWrite": denyWrite]],
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
