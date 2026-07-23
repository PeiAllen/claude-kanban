import Foundation
import Testing
@testable import OrchestraCore

@Suite("MCP configuration")
struct MCPConfigurationTests {
    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "mcp-config-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Claude inline JSON names the local Orchestra stdio server")
    func claudeJSON() throws {
        let data = try #require(MCPConfiguration.claudeJSON(command: "/bin/orchestra-mcp").data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let server = try #require(servers["orchestra"] as? [String: Any])
        #expect(server["type"] as? String == "stdio")
        #expect(server["command"] as? String == "/bin/orchestra-mcp")
        #expect((server["args"] as? [Any])?.isEmpty == true)
    }

    @Test("Codex TOML names the local Orchestra stdio server")
    func codexTOML() {
        let toml = MCPConfiguration.codexTOML(command: "/bin/orchestra-mcp")
        #expect(toml.contains("[mcp_servers.orchestra]"))
        #expect(toml.contains("command = \"/bin/orchestra-mcp\""))
        #expect(toml.contains("args = []"))
    }

    @Test("Claude global install adds Orchestra and preserves unrelated servers")
    func installClaudeGlobalAddsOnlyMissingServer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/claude.json"
        try """
        {"theme":"dark","mcpServers":{"other":{"type":"stdio","command":"/other"}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installClaudeGlobally(command: "/bin/orchestra-mcp", at: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        #expect((servers["orchestra"] as? [String: Any])?["command"] as? String == "/bin/orchestra-mcp")
    }

    @Test("Claude global install creates a missing file and leaves an existing entry byte-identical")
    func installClaudeGlobalIsAddOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nested/claude.json"

        #expect(MCPConfiguration.installClaudeGlobally(command: "/bin/orchestra-mcp", at: path))
        let before = try String(contentsOfFile: path, encoding: .utf8)
        #expect(MCPConfiguration.installClaudeGlobally(command: "/other", at: path) == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
    }

    @Test("Claude global install fails closed for malformed JSON")
    func installClaudeGlobalIgnoresMalformedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/claude.json"
        let malformed = "not json"
        try malformed.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installClaudeGlobally(command: "/bin/orchestra-mcp", at: path) == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == malformed)
    }

    @Test("Codex global install appends Orchestra and preserves existing text")
    func installCodexGlobalAddsOnlyMissingServer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/config.toml"
        let existing = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"/other\"\n"
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installCodexGlobally(command: "/bin/orchestra-mcp", at: path))
        let once = try String(contentsOfFile: path, encoding: .utf8)
        #expect(once.hasPrefix(existing))
        #expect(once.contains("[mcp_servers.orchestra]"))
        #expect(once.contains("command = \"/bin/orchestra-mcp\""))
        #expect(!once.contains("default_tools_approval_mode"))
        #expect(!once.contains("disabled_tools"))
    }

    @Test("Codex global install creates a missing file and leaves an existing entry byte-identical")
    func installCodexGlobalIsAddOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nested/config.toml"

        #expect(MCPConfiguration.installCodexGlobally(command: "/bin/orchestra-mcp", at: path))
        let before = try String(contentsOfFile: path, encoding: .utf8)
        #expect(MCPConfiguration.installCodexGlobally(command: "/other", at: path) == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
    }

    @Test("Codex global install recognizes a quoted existing Orchestra table")
    func installCodexGlobalRecognizesQuotedServer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/config.toml"
        let existing = "[mcp_servers.\"orchestra\"]\ncommand = \"/old\"\n"
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installCodexGlobally(command: "/other", at: path) == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == existing)
    }

    @Test("user command install creates both shims and an idempotent PATH block")
    func installUserCommandsCreatesShimsAndPath() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/.local/bin"
        let profile = home + "/.zprofile"
        try "export EDITOR=vim\n".write(toFile: profile, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installUserCommands(orchestra: "/bin/orchestra",
                                                      orchestraMCP: "/bin/orchestra-mcp",
                                                      binDirectory: bin,
                                                      profilePaths: [profile]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/orchestra") == "/bin/orchestra")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/orchestra-mcp") == "/bin/orchestra-mcp")

        let once = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(once.hasPrefix("export EDITOR=vim\n"))
        #expect(once.components(separatedBy: "Orchestra user-local command path").count == 2)
        #expect(once.contains("$HOME/.local/bin"))
        #expect(MCPConfiguration.installUserCommands(orchestra: "/other/orchestra",
                                                      orchestraMCP: "/other/orchestra-mcp",
                                                      binDirectory: bin,
                                                      profilePaths: [profile]) == false)
        #expect(try String(contentsOfFile: profile, encoding: .utf8) == once)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/orchestra") == "/bin/orchestra")
    }

    @Test("user command install preserves conflicting files and symlinks")
    func installUserCommandsPreservesConflicts() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/.local/bin"
        let profile = home + "/.profile"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "user orchestra\n".write(toFile: bin + "/orchestra", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: bin + "/orchestra-mcp", withDestinationPath: "/other/mcp")
        try "# Orchestra user-local command path\n".write(toFile: profile, atomically: true, encoding: .utf8)

        #expect(MCPConfiguration.installUserCommands(orchestra: "/bin/orchestra",
                                                      orchestraMCP: "/bin/orchestra-mcp",
                                                      binDirectory: bin,
                                                      profilePaths: [profile]) == false)
        #expect(try String(contentsOfFile: bin + "/orchestra", encoding: .utf8) == "user orchestra\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/orchestra-mcp") == "/other/mcp")
        #expect(try String(contentsOfFile: profile, encoding: .utf8) == "# Orchestra user-local command path\n")
    }
}
