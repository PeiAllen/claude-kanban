import XCTest
@testable import OrchestraCore

final class ReadOnlyLaunchTests: XCTestCase {
    func test_settingsJSON_denies_edit_tools_and_denies_writes() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: "/repo/.git/worktrees/foo")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let perms = obj["permissions"] as! [String: Any]
        let deny = perms["deny"] as! [String]
        // The four edit tools are still denied (now alongside the git-write rules).
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] { XCTAssertTrue(deny.contains(tool)) }
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(Set(fs["denyWrite"] as! [String]), ["/wt/foo", "/repo/.git/worktrees/foo"])
    }

    func test_settingsJSON_runs_strict_sandbox() throws {
        // The sandbox must be a real barrier: strict mode neutralizes `dangerouslyDisableSandbox`,
        // and fail-closed means a read-only card never silently degrades to unsandboxed.
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let sandbox = obj["sandbox"] as! [String: Any]
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
    }

    func test_settingsJSON_hands_readonly_policy_to_auto_mode_classifier() throws {
        // Excluded commands (git) run unsandboxed, so the write-block can't reach them. Instead of a
        // brittle per-command deny-list, hand the auto-mode classifier a read-only policy via
        // `autoMode.hard_deny` — it judges mutation semantically (verified to block git config/tag/
        // checkout while allowing git log).
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let hardDeny = (obj["autoMode"] as! [String: Any])["hard_deny"] as! [String]
        XCTAssertEqual(hardDeny.count, 1)
        XCTAssertTrue(hardDeny[0].contains("READ-ONLY SESSION"))
        XCTAssertTrue(hardDeny[0].lowercased().contains("deny"))
        // The brittle git command-string deny-list is gone — the policy replaces it.
        let deny = (obj["permissions"] as! [String: Any])["deny"] as! [String]
        XCTAssertFalse(deny.contains { $0.hasPrefix("Bash(git") })
    }

    func test_settingsJSON_omits_nil_gitDir() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(fs["denyWrite"] as! [String], ["/wt/foo"])
    }

    func test_argv_disallows_edit_tools_and_passes_settings() {
        let argv = ReadOnlyLaunch.argv(binary: "claude", settingsPath: "/tmp/ro.json")
        XCTAssertEqual(argv, ["claude", "--disallowedTools", "Edit", "Write", "MultiEdit",
                              "NotebookEdit", "--settings", "/tmp/ro.json"])
    }

    func test_gitDir_points_into_repo_worktrees() {
        XCTAssertEqual(ReadOnlyLaunch.gitDir(repo: "/r/app", worktreeName: "feature"),
                       "/r/app/.git/worktrees/feature")
    }

}
