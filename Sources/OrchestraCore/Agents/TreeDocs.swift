import Foundation

/// Branch-tree agent guidance (sync / restack / tree-aware ship), vendored per-agent and copied into the
/// module bundle. Claude receives it as a project skill; Codex receives the same selected variant through
/// launch-scoped developer instructions. Content stays keyed by agent id rather than adapter branching.
public enum TreeDocs {
    public enum Variant: String {
        case claudeSkill = "tree-skill"    // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "tree-agents"   // plain developer-instructions section body (Codex)
    }

    /// Read a variant's markdown; nil if absent/unreadable (callers degrade — never throws into launch).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Codex receives the plain body through a launch-scoped developer instruction; every other agent
    /// (Claude, future) gets the skill. Same substance both ways.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }
}
