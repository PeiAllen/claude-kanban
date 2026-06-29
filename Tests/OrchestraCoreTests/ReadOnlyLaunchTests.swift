import XCTest
@testable import OrchestraCore

final class ReadOnlyLaunchTests: XCTestCase {
    func test_settingsJSON_denies_edit_tools_and_denies_writes() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: "/repo/.git/worktrees/foo")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let perms = obj["permissions"] as! [String: Any]
        XCTAssertEqual(perms["deny"] as! [String], ["Edit", "Write", "MultiEdit", "NotebookEdit"])
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(Set(fs["denyWrite"] as! [String]), ["/wt/foo", "/repo/.git/worktrees/foo"])
    }

    func test_settingsJSON_omits_nil_gitDir() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(fs["denyWrite"] as! [String], ["/wt/foo"])
    }
}
