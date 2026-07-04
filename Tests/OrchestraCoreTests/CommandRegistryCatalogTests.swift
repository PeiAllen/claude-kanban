import XCTest
@testable import OrchestraCore   // @_exported brings in OrchestraKit's CommandCatalog

final class CommandRegistryCatalogTests: XCTestCase {
    // Every catalog schema has exactly one handler, and vice-versa — prevents drift after the split.
    func testRegistryCoversExactlyTheCatalog() {
        let catalogNames = Set(CommandCatalog.all.map(\.name))
        let registryNames = Set(CommandRegistry().names)
        XCTAssertEqual(catalogNames, registryNames,
                       "CommandRegistry handlers and CommandCatalog schemas must match 1:1")
    }

    // The registry surfaces the catalog's schema for each command (single source of truth).
    func testRegistryExposesCatalogSchema() {
        let reg = CommandRegistry()
        for schema in CommandCatalog.all {
            let cmd = reg.command(schema.name)
            XCTAssertNotNil(cmd, "missing handler for \(schema.name)")
            XCTAssertEqual(cmd?.summary, schema.summary)
            XCTAssertEqual(cmd?.params, schema.params)
        }
    }

    // The canonical set is complete (guards an accidental drop during the move).
    func testCatalogHasAllCommands() {
        XCTAssertEqual(Set(CommandCatalog.all.map(\.name)), [
            "list", "spawn", "move", "send", "inbox", "inbox-edit", "inbox-remove",
            "inbox-reorder", "wait", "handoff", "status", "archive", "reopen", "restart",
            "resume", "shell", "inspect", "closeShell", "exec", "sessions", "capture", "send-keys",
            "trustState", "batch-spawn", "trust",
        ])
    }
}
