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

    // Claude Code's multiple --settings are last-file-wins (full replace), not deep-merged. A read-only
    // card therefore must pass exactly ONE --settings — the merged read-only file that carries both the
    // hooks/statusLine and the read-only permissions. Passing the bare read-only file as a SECOND
    // --settings (after the hooks file) drops the managed statusLine + telemetry hooks entirely.
    func test_start_readonly_passes_single_settings_not_hooksPath_then_readonly() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", sessionId: "sid", name: "look", access: .readOnly)
        let argv = a.start(ctx)
        let settingsArgs = argv.enumerated().filter { $0.element == "--settings" }.map { argv[$0.offset + 1] }
        XCTAssertEqual(settingsArgs.count, 1, "read-only must ship one merged --settings, not two")
        XCTAssertNotEqual(settingsArgs.first, Config.hooksPath,
                          "the single --settings must be the merged read-only file, not the bare hooks file")
        XCTAssertTrue(settingsArgs.first?.contains("card-settings-") ?? false)
    }

    func test_start_readwrite_passes_hooksPath_settings() {
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/r/app", sessionId: "sid", access: .readWrite)
        let argv = a.start(ctx)
        let settingsArgs = argv.enumerated().filter { $0.element == "--settings" }.map { argv[$0.offset + 1] }
        XCTAssertEqual(settingsArgs, [Config.hooksPath])
    }

    // Regression guard for the whole class of bug: Claude Code's multiple --settings are last-file-wins,
    // so a SECOND --settings anywhere in the argv silently clobbers the managed statusLine + telemetry
    // hooks. Every start/resume path — across access modes, startIn columns, model, and seed — must emit
    // AT MOST ONE --settings. A future change that adds a stray second --settings (instead of routing the
    // setting through `settingsOverlays` / the hooks base) fails HERE rather than shipping the default
    // statusline again.
    func test_every_launch_path_emits_at_most_one_settings_flag() {
        let a = ClaudeCodeAdapter()
        let accesses: [CardAccess] = [.readWrite, .readOnly]
        let startIns: [StartIn?] = [nil, .plan, .impl]
        for access in accesses {
            for startIn in startIns {
                let startCtx = AdapterContext(cwd: "/r/app", model: "claude-opus-4-8", startIn: startIn,
                                              sessionId: "sid", prompt: "go", name: "card",
                                              access: access)
                let start = a.start(startCtx)
                XCTAssertLessThanOrEqual(start.filter { $0 == "--settings" }.count, 1,
                                         "start(access: \(access), startIn: \(String(describing: startIn))) emitted >1 --settings")

                let resumeCtx = AdapterContext(cwd: "/r/app", model: "claude-opus-4-8", startIn: startIn,
                                               sessionId: "sid", name: "card",
                                               access: access, seed: "resume seed")
                let resume = a.resume(resumeCtx) ?? []
                XCTAssertLessThanOrEqual(resume.filter { $0 == "--settings" }.count, 1,
                                         "resume(access: \(access), startIn: \(String(describing: startIn))) emitted >1 --settings")
            }
        }
    }
}
