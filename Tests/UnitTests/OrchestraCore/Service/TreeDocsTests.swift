import Foundation
import Testing
@testable import OrchestraCore

@Suite("Tree docs — vendored skills + legacy AGENTS cleanup")
struct TreeDocsTests {

    // MARK: loader parity with DelegationDocs

    @Test("both variants load non-empty from the bundle (offline)")
    func bothLoad() throws {
        let skill = try #require(TreeDocs.load(.claudeSkill))
        let agents = try #require(TreeDocs.load(.codexAgents))
        #expect(!skill.isEmpty)
        #expect(!agents.isEmpty)
        let skillURL = try #require(Bundle.module.url(forResource: "tree-skill", withExtension: "md"))
        #expect(skillURL.isFileURL)
    }

    @Test("forAgent maps codex → AGENTS variant, everything else → the skill")
    func perAgentSelection() throws {
        #expect(TreeDocs.forAgent("codex") == TreeDocs.load(.codexAgents))
        #expect(TreeDocs.forAgent("claude-code") == TreeDocs.load(.claudeSkill))
        #expect(TreeDocs.forAgent("some-future-agent") == TreeDocs.load(.claudeSkill))
    }

    @Test("Claude skill has orchestra-tree frontmatter; Codex variant is plain markdown")
    func wellFormed() throws {
        let skill = try #require(TreeDocs.load(.claudeSkill))
        #expect(skill.hasPrefix("---\n"))
        #expect(skill.contains("name: orchestra-tree"))
        #expect(skill.contains("description:"))
        let agents = try #require(TreeDocs.load(.codexAgents))
        #expect(!agents.hasPrefix("---\n"))
        #expect(agents.hasPrefix("# "))
    }

    @Test("both variants cover sync / restack / tree-aware ship anchors")
    func requiredAnchors() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            for anchor in ["orchestra synced", "orchestra shipped", "orchestra tree",
                           "rebase --onto", "merge-request", "squash", "restack"] {
                #expect(doc.contains(anchor), "missing anchor: \(anchor)")
            }
            #expect(doc.lowercased().contains("never autostash") || doc.lowercased().contains("never leave"))
        }
    }

    @Test("both variants make sandboxed Orchestra control calls MCP-first")
    func sandboxedControlCallsPreferMCP() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            #expect(doc.contains("MCP tools"))
            #expect(doc.contains("Operation not permitted"))
            #expect(doc.contains("do not retry"))
            #expect(doc.contains("same service"))
        }
    }

    @Test("both variants document the remote publish + restack path (BT6)")
    func remoteGuidancePresent() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            #expect(doc.contains("gh pr create --base"))
            #expect(doc.contains("force-with-lease"))
            #expect(doc.contains("push -u origin"))
            #expect(doc.contains("pr#"))          // canonical remote form documented
        }
    }

    @Test("removing Orchestra sections preserves markerless user AGENTS content")
    func removePreservesUserContent() throws {
        let base = NSTemporaryDirectory() + "agents-remove-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let user = "USER GUIDANCE\\n"
        let managed = """
        \(AgentsFileComposer.startMarker("delegation"))
        DELEG
        \(AgentsFileComposer.endMarker("delegation"))
        \(AgentsFileComposer.startMarker("tree"))
        TREE
        \(AgentsFileComposer.endMarker("tree"))
        """
        try (user + managed).write(toFile: path, atomically: true, encoding: .utf8)

        #expect(AgentsFileComposer.remove(sections: ["delegation", "tree"], at: path))
        let surviving = try String(contentsOfFile: path, encoding: .utf8)
        #expect(surviving.contains(user))
        #expect(!surviving.contains("DELEG"))
        #expect(!surviving.contains("TREE"))
        #expect(!surviving.contains("<!-- orchestra:section:"))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("removing a pure managed AGENTS file deletes the empty legacy artifact")
    func removeDeletesEmptyManagedFile() throws {
        let base = NSTemporaryDirectory() + "agents-empty-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let managed = """
        \(AgentsFileComposer.startMarker("delegation"))
        DELEG
        \(AgentsFileComposer.endMarker("delegation"))
        """
        try managed.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(AgentsFileComposer.remove(sections: ["delegation", "tree"], at: path))
        #expect(!FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("removing named sections never resets markerless user AGENTS content")
    func removeLeavesMarkerlessUserContentAlone() throws {
        let base = NSTemporaryDirectory() + "agents-markerless-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        let user = "MY EXISTING AGENTS FILE\\n"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try user.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(!AgentsFileComposer.remove(sections: ["delegation", "tree"], at: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == user)
        try? FileManager.default.removeItem(atPath: base)
    }
}
