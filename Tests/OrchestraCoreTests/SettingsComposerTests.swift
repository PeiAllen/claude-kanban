import XCTest
@testable import OrchestraCore

final class SettingsComposerTests: XCTestCase {
    private func parse(_ s: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    func test_keeps_base_statusLine_and_hooks_when_overlay_adds_disjoint_keys() throws {
        // The bug this guards: an overlay (read-only permissions/sandbox) must NOT drop the managed
        // statusLine + telemetry hooks. Claude's multiple --settings are last-file-wins, so we ship ONE
        // merged file — the composed result must carry both the base side-channel AND the overlay.
        let base = """
        { "_comment": "managed", "statusLine": { "type": "command", "command": "orchestra _report --event statusline" },
          "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "orchestra _report --event session" } ] } ] } }
        """
        let overlay = ReadOnlyLaunch.settingsObject(cwd: "/wt/foo", gitDir: "/repo/.git/worktrees/foo")
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: base, overlays: [overlay]))
        XCTAssertEqual((obj["statusLine"] as! [String: Any])["command"] as? String,
                       "orchestra _report --event statusline")
        XCTAssertNotNil(obj["hooks"])
        let deny = (obj["permissions"] as! [String: Any])["deny"] as! [String]
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] { XCTAssertTrue(deny.contains(tool)) }
        XCTAssertNotNil(obj["autoMode"])
        XCTAssertEqual(Set((((obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any])["denyWrite"] as! [String])),
                       ["/wt/foo", "/repo/.git/worktrees/foo"])
        XCTAssertNil(obj["_comment"], "the base _comment must be stripped from the composed file")
    }

    func test_deepMerge_merges_nested_objects_and_concatenates_arrays() throws {
        // A future overlay that adds its own hooks must ADD to the base hooks, not replace the object.
        let base = """
        { "hooks": { "SessionStart": [ {"a": 1} ], "PreToolUse": [ {"x": 1} ] } }
        """
        let overlay: [String: Any] = ["hooks": ["SessionStart": [["b": 2]], "Stop": [["s": 1]]]]
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: base, overlays: [overlay]))
        let hooks = obj["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["SessionStart"] as! [Any]).count, 2, "same event: arrays concatenate")
        XCTAssertEqual((hooks["PreToolUse"] as! [Any]).count, 1, "base-only event: preserved")
        XCTAssertEqual((hooks["Stop"] as! [Any]).count, 1, "overlay-only event: added")
    }

    func test_deepMerge_dedupes_string_arrays_and_overlays_win_on_scalars() throws {
        let base = """
        { "permissions": { "deny": ["Edit", "Write"] }, "model": "opus" }
        """
        let overlay: [String: Any] = ["permissions": ["deny": ["Write", "Bash"]], "model": "sonnet"]
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: base, overlays: [overlay]))
        XCTAssertEqual((obj["permissions"] as! [String: Any])["deny"] as! [String], ["Edit", "Write", "Bash"])
        XCTAssertEqual(obj["model"] as? String, "sonnet", "later overlay wins on scalar conflict")
    }

    func test_applies_overlays_in_order() throws {
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: "{}",
                                                         overlays: [["k": "first"], ["k": "second"]]))
        XCTAssertEqual(obj["k"] as? String, "second")
    }

    func test_no_overlays_returns_base_minus_comment() throws {
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: #"{"_comment":"x","statusLine":{"a":1}}"#,
                                                         overlays: []))
        XCTAssertNotNil(obj["statusLine"])
        XCTAssertNil(obj["_comment"])
    }

    func test_tolerates_unparseable_base() throws {
        // A missing/garbage rendered hooks file must still yield a valid file carrying the overlays.
        let obj = try parse(SettingsComposer.composeJSON(baseJSON: "not json",
                                                         overlays: [ReadOnlyLaunch.settingsObject(cwd: "/wt", gitDir: nil)]))
        XCTAssertTrue(((obj["permissions"] as! [String: Any])["deny"] as! [String]).contains("Edit"))
    }
}
