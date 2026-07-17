import Foundation

/// The standing Orchestra guidance each adapter packages in its native way. The content and ordering live
/// here, so providers share the same delegation/tree internals even though Claude installs project skills
/// and Codex supplies one launch-scoped developer-instructions string.
struct AgentGuidanceSection: Sendable, Equatable {
    let name: String
    let content: String
}

enum AgentGuidance {
    /// Named guidance sections in the order an agent should read them. A missing bundled resource simply
    /// omits that section; launch remains best-effort rather than failing because a documentation resource
    /// is unavailable.
    static func sections(for agentId: String) -> [AgentGuidanceSection] {
        [
            ("delegation", DelegationDocs.forAgent(agentId)),
            ("tree", TreeDocs.forAgent(agentId)),
            ("image-publishing", ImageDocs.forAgent(agentId)),
        ].compactMap { name, content in
            guard let content, !content.isEmpty else { return nil }
            return AgentGuidanceSection(name: name, content: content)
        }
    }

    /// Codex has one developer-instructions value, so its named sections are joined with a stable blank
    /// separator. Claude consumes the same sections individually as two native skills.
    static func developerInstructions(for agentId: String) -> String? {
        let content = sections(for: agentId).map(\.content)
        return content.isEmpty ? nil : content.joined(separator: "\n\n")
    }

    /// Write a preselected section to one provider-owned destination. This is intentionally a small
    /// filesystem primitive: adapters choose their own discovery path and format while sharing content.
    @discardableResult
    static func install(_ section: AgentGuidanceSection, at path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try section.content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
