import Foundation

/// Loads the vendored, PR-authored **delegation guidance** an agent reads to decide when to hand off /
/// fork / fan-out / wait (vs. doing the work inline or with a native subagent). Two per-agent variants,
/// `.copy`-bundled into `Bundle.module` (no network — offline at build & runtime), parallel to
/// `ModelCatalog`. This is content-only plumbing: the shared guidance bundle selects a variant with
/// `forAgent(_:)`, then adapters package it natively (Claude as a skill, Codex as a launch override).
public enum DelegationDocs {
    /// The two authored variants — the raw resource basename (sans `.md`) is the enum's rawValue.
    public enum Variant: String {
        case claudeSkill = "delegation-skill"   // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "delegation-agents"  // plain developer-instructions body (Codex)
    }

    /// Read a variant's markdown from the bundle. Returns `nil` if the resource is absent/unreadable
    /// (callers degrade gracefully) — never throws into a launch path (mirrors `ModelCatalog.load`).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Select the variant for an agent id: Codex receives its plain body through a launch-scoped developer
    /// instruction, while every other agent (Claude and, by default, any future agent) gets the skill.
    /// Content is identical across variants — only the packaging differs — so an unknown agent still gets
    /// correct guidance.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }

}
