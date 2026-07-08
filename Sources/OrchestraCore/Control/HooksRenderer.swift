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

    /// Render the Codex hooks template into `dest` (default `Config.codexHooksPath`), substituting the
    /// orchestra binary path — mirrors `render` for the second agent. CodexAdapter later installs this
    /// rendered file into the pinned `$CODEX_HOME/hooks.json`.
    @discardableResult
    public static func renderCodex(orchestraBin: String, agentId: String, to dest: String = Config.codexHooksPath) throws -> String {
        let template: String
        if let p = codexTemplatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            template = s
        } else {
            template = codexFallbackTemplate
        }
        let rendered = template
            .replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
            .replacingOccurrences(of: "__AGENT_ID__", with: agentId)
        let dir = (dest as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rendered.write(toFile: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private static let codexFallbackTemplate = """
    {
      "hooks": {
        "SessionStart": [
          { "hooks": [ { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event session --agent __AGENT_ID__" } ] }
        ],
        "PermissionRequest": [
          { "hooks": [ { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event permission --agent __AGENT_ID__" } ] }
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
        let template: String
        if let p = templatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            template = s
        } else {
            template = fallbackTemplate
        }
        let rendered = template
            .replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
            .replacingOccurrences(of: "__AGENT_ID__", with: agentId)
        let dir = (dest as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rendered.write(toFile: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private static let fallbackTemplate = """
    {
      "statusLine": { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event statusline --agent __AGENT_ID__" },
      "hooks": {
        "SessionStart": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event session --agent __AGENT_ID__" }] }],
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event prompt --agent __AGENT_ID__" }] }],
        "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event pretool --agent __AGENT_ID__" }] }],
        "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event posttool --agent __AGENT_ID__" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event notification --agent __AGENT_ID__" }] }],
        "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event taskcompleted --agent __AGENT_ID__" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event stop --agent __AGENT_ID__" }] }],
        "SessionEnd": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event sessionend --agent __AGENT_ID__" }] }]
      }
    }
    """
}
