import Foundation

/// Renders the managed Claude Code `--settings` file (statusLine + hooks) from the bundled template,
/// pointing it at the live `orchestra` binary. Written on daemon start + whenever statusLine config
/// changes (so new sessions pick it up).
public enum HooksRenderer {

    /// Path to the bundled template.
    public static var templatePath: String? {
        Bundle.module.path(forResource: "claude-hooks", ofType: "json")
    }

    /// Path to the bundled Codex hooks template.
    public static var codexTemplatePath: String? {
        Bundle.module.path(forResource: "codex-hooks", ofType: "json")
    }

    /// Render Codex's provider-specific hooks in memory for launch-scoped configuration. Keeping this in
    /// the shared renderer makes the bundled template the sole hook definition during migration.
    static func codexHooks(orchestraBin: String, agentId: String) -> [String: JSONValue]? {
        guard let root = try? JSONValue.parse(Data(renderedCodexJSON(orchestraBin: orchestraBin,
                                                                       agentId: agentId).utf8)),
              case let .object(object) = root,
              case let .object(hooks)? = object["hooks"]
        else { return nil }
        return hooks
    }

    /// Substitute the live edge-helper path and remove the developer-only top-level comment.
    static func renderedCodexJSON(orchestraBin: String, agentId: String) -> String {
        let substituted = codexTemplate()
            .replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
            .replacingOccurrences(of: "__AGENT_ID__", with: agentId)
        return strippingComment(substituted)
    }

    private static func codexTemplate() -> String {
        if let p = codexTemplatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            return s
        }
        return codexFallbackTemplate
    }

    /// Remove the top-level `_comment` key from a rendered hooks JSON string. Defensive: if the string
    /// doesn't parse as a JSON object, it's returned unchanged so a malformed template still installs its
    /// hooks rather than collapsing to empty.
    static func strippingComment(_ json: String) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              obj["_comment"] != nil else { return json }
        obj.removeValue(forKey: "_comment")
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]) else {
            return json
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static let codexFallbackTemplate = """
    {
      "hooks": {
        "SessionStart": [
          { "hooks": [ { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event session --agent __AGENT_ID__" } ] }
        ],
        "Stop": [
          { "hooks": [ { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event stop --agent __AGENT_ID__" } ] }
        ]
      }
    }
    """

    /// Render the template into `dest`, substituting the orchestra binary path. Returns the dest path.
    @discardableResult
    public static func render(orchestraBin: String, agentId: String, to dest: String = Config.hooksPath) throws -> String {
        let rendered: String
        if let p = templatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            rendered = s
                .replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
                .replacingOccurrences(of: "__AGENT_ID__", with: agentId)
        } else {
            rendered = renderedFallbackTemplate(orchestraBin: orchestraBin, agentId: agentId)
        }
        let dir = (dest as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rendered.write(toFile: dest, atomically: true, encoding: .utf8)
        return dest
    }

    static func renderedFallbackTemplate(orchestraBin: String, agentId: String) -> String {
        fallbackTemplate
            .replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
            .replacingOccurrences(of: "__AGENT_ID__", with: agentId)
    }

    private static let fallbackTemplate = """
    {
      "crossSessionInbound": "accept",
      "statusLine": { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event statusline --agent __AGENT_ID__" },
      "hooks": {
        "SessionStart": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event session --agent __AGENT_ID__" }] }],
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event prompt --agent __AGENT_ID__" }] }],
        "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event pretool --agent __AGENT_ID__" }] }],
        "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event posttool --agent __AGENT_ID__" }] }],
        "PostToolUseFailure": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event posttoolfailure --agent __AGENT_ID__" }] }],
        "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event permission --agent __AGENT_ID__" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event notification --agent __AGENT_ID__" }] }],
        "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event taskcompleted --agent __AGENT_ID__" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event stop --agent __AGENT_ID__" }] }],
        "SessionEnd": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event sessionend --agent __AGENT_ID__" }] }]
      }
    }
    """
}
