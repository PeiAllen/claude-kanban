import Foundation
import Testing
@testable import OrchestraCore

@Suite("Tree docs — vendored skills")
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

}
