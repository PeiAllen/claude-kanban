import XCTest
@testable import OrchestraCore   // @_exported brings in OrchestraKit's CommandCatalog

final class CommandRegistryCatalogTests: XCTestCase {
    // Every catalog schema has exactly one handler, and vice-versa — prevents drift after the split.
    func testRegistryCoversExactlyTheCatalog() {
        let catalogNames = Set(CommandCatalog.all.map(\.name))
        let registryNames = Set(CommandRegistry().commands.map(\.name))
        XCTAssertEqual(catalogNames, registryNames,
                       "CommandRegistry handlers and CommandCatalog schemas must match 1:1")
    }

    // The registry surfaces the catalog's schema for each command (single source of truth).
    func testRegistryExposesCatalogSchema() {
        let reg = CommandRegistry()
        for schema in CommandCatalog.all {
            let cmd = reg.command(schema.name)
            XCTAssertNotNil(cmd, "missing handler for \(schema.name)")
            XCTAssertEqual(cmd?.schema.summary, schema.summary)
            XCTAssertEqual(cmd?.schema.params, schema.params)
        }
    }

    // `inspect` launches an interactive read-only `claude` INSIDE the target card's tmux session (a
    // visible shell tab on that card). That makes it a HUMAN affordance — the inspector's "eye" button —
    // not an agent tool: an agent calling `mcp__orchestra__inspect` opens a surprise claude session on a
    // *peer* card (empirically the cause of "random shells appear on orchestrator/impl cards"). So it must
    // stay off the MCP surface, exactly like the `send-keys`/`capture` human-only primitives.
    func testInspectIsAppOnlyNotAgentExposed() {
        let mcpNames = Set(CommandCatalog.mcpExposed.map(\.name))
        XCTAssertFalse(mcpNames.contains("inspect"), "inspect must NOT be an agent-facing MCP tool")
        // The other human-only primitives stay withheld too (regression guard).
        XCTAssertFalse(mcpNames.contains("send-keys"))
        XCTAssertFalse(mcpNames.contains("capture"))
        // But the plain worktree-shell opener (no claude) remains available to agents.
        XCTAssertTrue(mcpNames.contains("shell"))
        // And the daemon still dispatches inspect — the app's eye button + the CLI use it.
        XCTAssertNotNil(CommandRegistry().command("inspect"))
    }

    func testPublishImageIsAllAndMCPExposed() {
        let command = try! XCTUnwrap(CommandRegistry().command("publish-image"))
        XCTAssertEqual(command.schema.exposure, .all)
        XCTAssertTrue(CommandCatalog.mcpExposed.map(\.name).contains("publish-image"))
    }

    // `shared` is advertised to agents over MCP; `shared-policy` is not. `.appOnly` only withholds it from the
    // MCP bridge — the daemon and the CLI still dispatch it, so this is not an access control.
    func testSharedIsAllAndSharedPolicyIsAppOnly() throws {
        let mcpNames = Set(CommandCatalog.mcpExposed.map(\.name))
        XCTAssertTrue(mcpNames.contains("shared"))
        XCTAssertFalse(mcpNames.contains("shared-policy"))
        XCTAssertEqual(try XCTUnwrap(CommandRegistry().command("shared-policy")).schema.exposure, .appOnly)
    }

    func testSendSummaryDoesNotDescribeTheRemovedTurnEndDrain() throws {
        let send = try XCTUnwrap(CommandCatalog.all.first { $0.name == "send" })
        XCTAssertFalse(send.summary.contains("next turn-end"))
    }

    // The canonical set is complete (guards an accidental drop during the move).
    func testCatalogHasAllCommands() {
        XCTAssertEqual(Set(CommandCatalog.all.map(\.name)), [
            "list", "spawn", "move", "set-title", "set-note", "set-planned", "needs-input", "send", "inbox", "inbox-edit",
            "inbox-remove", "inbox-retry", "inbox-reorder", "wait", "handoff", "status", "archive", "reopen", "restart",
            "resume", "shell", "inspect", "closeShell", "exec", "sessions", "capture", "send-keys",
            "trustState", "batch-spawn", "trust", "set-parent", "tree", "synced", "shipped",
            "borrow", "release", "merge-request", "publish-image", "shared", "shared-policy",
        ])
    }
}
