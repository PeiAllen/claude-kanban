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
}
