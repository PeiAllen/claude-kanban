import Foundation
import Testing
@testable import OrchestraCore

@Suite("Tree docs — vendored skill + sectioned AGENTS.md composer")
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

    // MARK: Claude install — its own skill dir

    @Test("Claude install writes the skill under .claude/skills/orchestra-tree/, creating parents")
    func claudeInstall() throws {
        let base = NSTemporaryDirectory() + "tree-install-\(UUID().uuidString)"
        let path = "\(base)/.claude/skills/orchestra-tree/SKILL.md"
        #expect(TreeDocs.install(agentId: "claude-code", at: path) == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == TreeDocs.load(.claudeSkill))
        #expect(TreeDocs.install(agentId: "claude-code", at: path) == true)   // idempotent
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: Codex sectioned AGENTS.md — delegation + tree coexist across reinstall

    @Test("composer keeps BOTH delegation and tree sections across a reinstall (idempotent)")
    func sectionedIdempotence() throws {
        let base = NSTemporaryDirectory() + "agents-compose-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        let deleg = try #require(DelegationDocs.forAgent("codex"))
        let tree = try #require(TreeDocs.forAgent("codex"))

        for _ in 0..<2 {   // install twice — must not duplicate
            #expect(AgentsFileComposer.upsert(section: "delegation", content: deleg, at: path) == true)
            #expect(AgentsFileComposer.upsert(section: "tree", content: tree, at: path) == true)
        }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        // exactly one of each marker pair
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("tree")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.endMarker("tree")).count == 2)
        // both bodies present
        #expect(text.contains(deleg))
        #expect(text.contains(tree))
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("upsert replaces a section's body in place without touching its neighbor")
    func upsertReplacesInPlace() throws {
        let base = NSTemporaryDirectory() + "agents-replace-\(UUID().uuidString)"
        let path = "\(base)/AGENTS.md"
        AgentsFileComposer.upsert(section: "delegation", content: "OLD-DELEG", at: path)
        AgentsFileComposer.upsert(section: "tree", content: "TREE-BODY", at: path)
        AgentsFileComposer.upsert(section: "delegation", content: "NEW-DELEG", at: path)  // replace
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("NEW-DELEG"))
        #expect(!text.contains("OLD-DELEG"))
        #expect(text.contains("TREE-BODY"))   // neighbor untouched
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        try? FileManager.default.removeItem(atPath: base)
    }
}
