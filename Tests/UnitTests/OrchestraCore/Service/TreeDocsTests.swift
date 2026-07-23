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

    @Test("both variants document the remote RESTACK path (BT6)")
    func remoteGuidancePresent() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            #expect(doc.contains("force-with-lease"))
            #expect(doc.contains("pr#"))          // canonical remote form documented
        }
    }

    /// Slice 3a — `merge-request` is the SINGULAR taught ship verb, so the guidance must offer no second
    /// path for an agent to pick instead. Publishing a branch and opening a stacked PR remain primitives a
    /// human may direct; they are not something an agent is taught to do on its own, and `borrow` is not a
    /// ship instruction. This is a NEGATIVE anchor on purpose: the failure mode is a well-meaning edit
    /// re-adding "and if the parent is remote, open a PR", which quietly restores the four-way fork.
    @Test("neither variant teaches a second ship path")
    func singularShipVerb() throws {
        for doc in [try #require(TreeDocs.load(.claudeSkill)), try #require(TreeDocs.load(.codexAgents))] {
            #expect(!doc.contains("gh pr create"))
            #expect(!doc.contains("push -u origin"))
            #expect(!doc.contains("orchestra borrow"))
            #expect(!doc.contains("merge --squash"))
            // …and the one verb IS taught, next to the instruction to stop.
            #expect(doc.contains("orchestra merge-request <you>"))
            #expect(doc.uppercased().contains("STOP"))
        }
    }

}
