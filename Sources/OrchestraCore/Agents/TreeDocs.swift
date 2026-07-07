import Foundation

/// Branch-tree agent guidance (sync / restack / tree-aware ship), vendored per-agent and `.copy`-bundled
/// into `Bundle.module` — the `DelegationDocs` pattern verbatim. Claude reads it as a project skill
/// (`.claude/skills/orchestra-tree/SKILL.md`); Codex reads it as a NAMED SECTION of its single
/// `CODEX_HOME/AGENTS.md`, composed alongside the delegation section by `AgentsFileComposer`. Content is
/// keyed via `forAgent(_:)` — no per-agent branch in the adapters.
public enum TreeDocs {
    public enum Variant: String {
        case claudeSkill = "tree-skill"    // SKILL.md-style: frontmatter + body (Claude)
        case codexAgents = "tree-agents"   // plain AGENTS.md section body (Codex)
    }

    /// Read a variant's markdown; nil if absent/unreadable (callers degrade — never throws into launch).
    public static func load(_ variant: Variant) -> String? {
        guard let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Codex reads AGENTS.md; every other agent (Claude, future) gets the skill. Same substance both ways.
    public static func forAgent(_ agentId: String) -> String? {
        load(agentId == "codex" ? .codexAgents : .claudeSkill)
    }

    /// Materialize the Claude skill variant to `path` (its own `orchestra-tree` skill dir — a SEPARATE
    /// file from the delegation skill, so no composition is needed on the Claude side). Best-effort;
    /// idempotent atomic overwrite. Mirrors `DelegationDocs.install`. Codex does NOT use this — its shared
    /// `AGENTS.md` is composed via `AgentsFileComposer` (see `CodexAdapter.prepareToLaunch`).
    @discardableResult
    public static func install(agentId: String, at path: String) -> Bool {
        guard let text = forAgent(agentId) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}

/// Composes a Codex `AGENTS.md` from named sections behind idempotent HTML-comment markers, so multiple
/// Orchestra-owned docs (delegation + tree) share the one file Codex reads per scope without clobbering
/// each other. Each section is delimited by
///   `<!-- orchestra:section:<name>:start -->` … `<!-- orchestra:section:<name>:end -->`.
/// `upsert` replaces an existing same-named block IN PLACE (rewrite-idempotent) or appends a new one,
/// leaving every other section untouched. Best-effort — never throws into a launch path.
public enum AgentsFileComposer {
    public static func startMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):start -->" }
    public static func endMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):end -->" }

    @discardableResult
    public static func upsert(section name: String, content: String, at path: String) -> Bool {
        let start = startMarker(name), end = endMarker(name)
        let block = "\(start)\n\(content)\n\(end)"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // Legacy reset: a file with NO Orchestra section markers at all was written by the pre-composition
        // installer, which fully overwrote this Orchestra-owned AGENTS.md with a single bare doc. Appending
        // a marked section below it would strand that markerless copy forever (a permanent duplicate on
        // every launch). Since Orchestra owns the file (never the user's project AGENTS.md), start fresh —
        // no worse than the full-overwrite it replaces. A file that already carries markers is composed in
        // place below (idempotent, sibling sections preserved).
        if !text.contains("<!-- orchestra:section:") { text = "" }
        if let existing = sectionRange(name, in: text) {
            text.replaceSubrange(existing, with: block)
        } else {
            if !text.isEmpty {
                if !text.hasSuffix("\n") { text += "\n" }
                text += "\n"
            }
            text += block + "\n"
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    /// The full span of a named block (inclusive of both markers), or nil if not present / malformed.
    private static func sectionRange(_ name: String, in text: String) -> Range<String.Index>? {
        guard let s = text.range(of: startMarker(name)),
              let e = text.range(of: endMarker(name)),
              s.lowerBound < e.upperBound else { return nil }
        return s.lowerBound..<e.upperBound
    }
}
