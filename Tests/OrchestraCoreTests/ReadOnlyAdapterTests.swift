import XCTest
@testable import OrchestraCore

final class ReadOnlyAdapterTests: XCTestCase {
    func test_start_readonly_appends_disallowed_edit_tools() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", model: "claude-opus-4-8",
                                 sessionId: "sid", name: "look", access: .readOnly)
        let argv = a.start(ctx)
        XCTAssertTrue(argv.contains("--disallowedTools"))
        for t in ["Edit", "Write", "MultiEdit", "NotebookEdit"] { XCTAssertTrue(argv.contains(t)) }
    }
    func test_start_readwrite_has_no_disallowed_tools() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", sessionId: "sid", access: .readWrite)
        XCTAssertFalse(a.start(ctx).contains("--disallowedTools"))
    }
}
