import Foundation

/// Loads the vendored, PR-authored **delegation guidance** an agent reads to decide when to hand off /
/// fork / fan-out / wait (vs. doing the work inline or with a native subagent). Two per-agent variants,
/// `.copy`-bundled into `Bundle.module` (no network — offline at build & runtime), parallel to
/// `ModelCatalog`. This is content-only plumbing: the seed-injection path selects a variant with
/// `forAgent(_:)` and delivers it (Claude as a skill, Codex as AGENTS.md); the docs never mutate launch
/// behavior on their own.
public enum DelegationDocs {
    /// The two authored variants — the raw resource basename (sans `.md`) is the enum's rawValue.
    public enum Variant: String {
        case claudeSkill = "delegation-skill"   // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "delegation-agents"  // plain AGENTS.md (Codex)
    }

    /// Read a variant's markdown from the bundle. Returns `nil` if the resource is absent/unreadable
    /// (callers degrade gracefully) — never throws into a launch path (mirrors `ModelCatalog.load`).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Select the variant for an agent id: Codex reads AGENTS.md; every other agent (Claude and, by
    /// default, any future agent) gets the skill. Content is identical across variants — only the
    /// packaging differs — so an unknown agent still gets correct guidance.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }

    /// Materialize an agent's delegation guidance to `path` (creating parent dirs) — the seed-injection
    /// launch step each adapter calls from `prepareToLaunch`. Best-effort by design: returns `false` and
    /// does nothing if the resource is absent (`forAgent` nil) or any filesystem step fails — it NEVER
    /// throws into a launch path (mirrors `load`'s nil-tolerance). Idempotent: an atomic overwrite of the
    /// same content. Content is keyed via `forAgent(agentId)` — the caller passes its own agent id, so
    /// there is no per-agent branch here.
    @discardableResult
    public static func install(agentId: String, at path: String) -> Bool {
        guard let text = forAgent(agentId) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}
