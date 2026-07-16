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

/// Finds the named HTML-comment markers written by the former Codex global-installation path. Each section
/// was delimited by
///   `<!-- orchestra:section:<name>:start -->` … `<!-- orchestra:section:<name>:end -->`.
/// Only removal remains: a launch-scoped Codex configuration must retire its own legacy content without
/// clobbering arbitrary user text. Best-effort — never throws into a launch path.
public enum AgentsFileComposer {
    public static func startMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):start -->" }
    public static func endMarker(_ name: String) -> String { "<!-- orchestra:section:\(name):end -->" }

    /// Remove only named Orchestra marker blocks from an existing file. This supports retiring the old
    /// global Codex installation without treating arbitrary markerless user text as Orchestra-owned.
    /// Missing or malformed blocks are left alone, and a now-empty file is removed instead of replaced by
    /// blank content. Best-effort by design.
    @discardableResult
    public static func remove(sections names: [String], at path: String) -> Bool {
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var changed = false

        for name in names {
            while let range = sectionRange(name, in: text) {
                text.replaceSubrange(range, with: "")
                changed = true
            }
        }
        guard changed else { return false }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try FileManager.default.removeItem(atPath: path)
                return true
            } catch {
                return false
            }
        }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The full span of a named block (inclusive of both markers), or nil if not present / malformed.
    private static func sectionRange(_ name: String, in text: String) -> Range<String.Index>? {
        guard let s = text.range(of: startMarker(name)),
              let e = text.range(of: endMarker(name)),
              s.lowerBound < e.upperBound else { return nil }
        return s.lowerBound..<e.upperBound
    }
}
