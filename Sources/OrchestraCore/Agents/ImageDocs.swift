import Foundation

/// Loads the vendored guidance that lets an agent deliberately publish an image it generated or derived
/// for a human to inspect. Claude gets a project skill; Codex gets a named section in its isolated
/// `CODEX_HOME/AGENTS.md`, composed beside the other Orchestra-owned sections.
public enum ImageDocs {
    public enum Variant: String {
        case claudeSkill = "image-publishing-skill"
        case codexAgents = "image-publishing-agents"
    }

    /// Read a variant's markdown; an unavailable resource is non-fatal to a card launch.
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Codex reads `AGENTS.md`; Claude and future adapters receive the skill-shaped variant.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }

    /// Materialize a Claude-style project skill. Codex uses `AgentsFileComposer` instead.
    @discardableResult
    public static func install(agentId: String, at path: String) -> Bool {
        guard let text = forAgent(agentId) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}
