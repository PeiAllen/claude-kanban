import Foundation
import Testing
@testable import OrchestraCore

@Suite("Delegation docs — vendored skill + AGENTS.md resources")
struct DelegationDocsTests {

    // MARK: present + loadable

    @Test("both variants load non-empty from the bundle")
    func bothLoad() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        let agents = try #require(DelegationDocs.load(.codexAgents))
        #expect(!skill.isEmpty)
        #expect(!agents.isEmpty)
    }

    @Test("resources are bundled as local files, loaded OFFLINE (no network)")
    func offlineLocalResource() throws {
        let skillURL = try #require(Bundle.module.url(forResource: "delegation-skill", withExtension: "md"))
        let agentsURL = try #require(Bundle.module.url(forResource: "delegation-agents", withExtension: "md"))
        #expect(skillURL.isFileURL)
        #expect(agentsURL.isFileURL)
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
        #expect(FileManager.default.fileExists(atPath: agentsURL.path))
    }

    // MARK: per-agent selection (the Claude-vs-Codex variant)

    @Test("forAgent maps codex → AGENTS.md, everything else → the skill")
    func perAgentSelection() throws {
        #expect(DelegationDocs.forAgent("codex") == DelegationDocs.load(.codexAgents))
        #expect(DelegationDocs.forAgent("claude-code") == DelegationDocs.load(.claudeSkill))
        #expect(DelegationDocs.forAgent("some-future-agent") == DelegationDocs.load(.claudeSkill))
    }

    // MARK: well-formedness — skill frontmatter

    @Test("skill has YAML frontmatter with name + description")
    func skillFrontmatter() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        #expect(skill.hasPrefix("---\n"))
        // second `---` closes the frontmatter block
        let afterOpen = skill.dropFirst(4)
        #expect(afterOpen.contains("\n---\n"))
        #expect(skill.contains("name: orchestra-delegation"))
        #expect(skill.contains("description:"))
    }

    @Test("AGENTS.md is plain markdown (no YAML frontmatter)")
    func agentsHasNoFrontmatter() throws {
        let agents = try #require(DelegationDocs.load(.codexAgents))
        #expect(!agents.hasPrefix("---\n"))
        #expect(agents.hasPrefix("# "))   // starts with a heading
    }

    // MARK: well-formedness — required heuristic anchors in BOTH variants

    @Test("both variants cover the four moves + the card-vs-subagent line")
    func requiredAnchors() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            let lower = doc.lowercased()
            for anchor in ["handoff", "fork", "fan-out", "wait", "spawn",
                           "card", "in-context", "durable"] {
                #expect(lower.contains(anchor), "missing anchor: \(anchor)")
            }
        }
    }

    @Test("both variants tell the agent to KEEP ephemeral in-context helpers (don't replace)")
    func keepSubagentsLine() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            let lower = doc.lowercased()
            #expect(lower.contains("in addition to"))
            #expect(lower.contains("never") && lower.contains("instead of"))
        }
    }

    @Test("the Claude skill names the native subagent Task tool explicitly")
    func claudeNamesSubagent() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        #expect(skill.lowercased().contains("subagent"))
        #expect(skill.contains("Task"))
    }
}
