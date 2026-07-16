import Foundation

/// The provider-specific spelling of Orchestra's launch-local MCP server and its optional global
/// installation. Local configuration is always emitted by the adapters; global writes are explicitly
/// opt-in and add-only so an existing user choice remains authoritative when the name is already used.
enum MCPConfiguration {
    static let serverName = "orchestra"

    /// JSON accepted by Claude Code's `--mcp-config` argument. It is passed inline as one argv value,
    /// which avoids a shared per-card file and lets Claude apply its normal local-over-user precedence.
    static func claudeJSON(command: String) -> String {
        let object: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "stdio",
                    "command": command,
                    "args": [],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// TOML table layered into Codex's existing per-card profile. The profile has the same server name
    /// as any global entry, so Codex's profile precedence makes this launch-local path win without
    /// discarding other global MCP servers.
    static func codexTOML(command: String) -> String {
        [
            "[mcp_servers." + serverName + "]",
            "command = " + TOMLOverride.string(command),
            "args = []",
        ].joined(separator: "\n") + "\n"
    }

    /// Add the Orchestra server to a Claude user config only when the canonical name is absent. A
    /// malformed or unreadable existing file is left untouched so the optional convenience setting
    /// cannot damage a user's configuration.
    @discardableResult
    static func installClaudeGlobally(command: String, at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var root: [String: Any]

        if FileManager.default.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  var decoded = object as? [String: Any]
            else { return false }

            if let existing = decoded["mcpServers"] {
                guard var servers = existing as? [String: Any], servers[serverName] == nil else {
                    return false
                }
                servers[serverName] = claudeServer(command: command)
                decoded["mcpServers"] = servers
            } else {
                decoded["mcpServers"] = [serverName: claudeServer(command: command)]
            }
            root = decoded
        } else {
            root = ["mcpServers": [serverName: claudeServer(command: command)]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                       options: [.sortedKeys, .prettyPrinted])
        else { return false }
        return write(data: data, to: url)
    }

    /// Add the Orchestra table to a Codex user config only when no equivalent table or dotted key is
    /// already present. Appending keeps every existing byte intact and remains valid after a final table.
    @discardableResult
    static func installCodexGlobally(command: String, at path: String) -> Bool {
        let exists = FileManager.default.fileExists(atPath: path)
        guard !exists || (try? String(contentsOfFile: path, encoding: .utf8)) != nil else { return false }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard !hasCodexServer(in: existing) else { return false }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated.append("\n") }
        if !updated.isEmpty { updated.append("\n") }
        updated.append(codexTOML(command: command))
        return write(text: updated, to: URL(fileURLWithPath: path))
    }

    private static func claudeServer(command: String) -> [String: Any] {
        ["type": "stdio", "command": command, "args": []]
    }

    private static func hasCodexServer(in contents: String) -> Bool {
        for raw in contents.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let comment = line.firstIndex(of: "#") { line.removeSubrange(comment...) }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let header = codexHeader(line), normalizedCodexPath(header) == "mcp_servers.\(serverName)" {
                return true
            }

            let key = String(line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKey = normalizedCodexPath(key)
            if normalizedKey == "mcp_servers.\(serverName)"
                || normalizedKey?.hasPrefix("mcp_servers.\(serverName).") == true {
                return true
            }
        }
        return false
    }

    private static func codexHeader(_ line: String) -> String? {
        if line.hasPrefix("[["), line.hasSuffix("]]"), line.count >= 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
            return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func normalizedCodexPath(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func write(data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func write(text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
