import Foundation

/// Loads the vendored guidance that lets an agent deliberately publish an image it generated or derived
/// for a human to inspect. Content only: `AgentGuidance` owns the ordering, and each adapter packages
/// this in its native way — a Claude project skill, or a section of Codex's launch-scoped instructions.
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
}
