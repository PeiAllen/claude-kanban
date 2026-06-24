import Foundation

/// Renders the managed Claude Code `--settings` file (statusLine + hooks) from the bundled template,
/// pointing it at the live `orchestra` binary. Written on daemon start + whenever statusLine config
/// changes (so new sessions pick it up).
public enum HooksRenderer {

    /// Path to the bundled template.
    public static var templatePath: String? {
        Bundle.module.path(forResource: "claude-hooks", ofType: "json")
    }

    /// Render the template into `dest`, substituting the orchestra binary path. Returns the dest path.
    @discardableResult
    public static func render(orchestraBin: String, to dest: String = Config.hooksPath) throws -> String {
        let template: String
        if let p = templatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            template = s
        } else {
            template = fallbackTemplate
        }
        let rendered = template.replacingOccurrences(of: "__ORCHESTRA_BIN__", with: orchestraBin)
        let dir = (dest as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rendered.write(toFile: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private static let fallbackTemplate = """
    {
      "statusLine": { "type": "command", "command": "__ORCHESTRA_BIN__ _report --event statusline" },
      "hooks": {
        "SessionStart": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event session" }] }],
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event prompt" }] }],
        "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event tool" }] }],
        "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event tool" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event notify" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event notify" }] }],
        "SessionEnd": [{ "hooks": [{ "type": "command", "command": "__ORCHESTRA_BIN__ _report --event sessionend" }] }]
      }
    }
    """
}
