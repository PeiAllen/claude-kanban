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

    @Test("the Claude skill prefers MCP wait in sandboxes and keeps CLI background wait terminal-native")
    func claudeWaitUsesMCPInSandboxes() throws {
        let skill = try #require(DelegationDocs.load(.claudeSkill))
        #expect(skill.contains("orchestra wait <refs>"))
        #expect(skill.contains("run_in_background: true"))
        #expect(skill.contains("Monitor"))
        #expect(skill.contains("MCP `wait`"))
        #expect(skill.contains("managed/sandboxed"))
        #expect(skill.contains("terminal-native Claude"))
        #expect(skill.contains("do not retry"))
    }

    @Test("the Codex AGENTS variant does not claim a send-keys wait wake")
    func codexWaitDoesNotPromiseSendKeysWake() throws {
        let agents = try #require(DelegationDocs.load(.codexAgents))
        #expect(!agents.lowercased().contains("send-keys"))
        #expect(agents.contains("Orchestra records the durable watch"))
        #expect(agents.contains("resumes you when a"))
    }

    @Test("both variants make sandboxed Orchestra control calls MCP-first")
    func sandboxedControlCallsPreferMCP() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            #expect(doc.contains("MCP tools"))
            #expect(doc.contains("Operation not permitted"))
            #expect(doc.contains("do not retry"))
            #expect(doc.contains("same Orchestra service"))
        }
    }

    @Test("delegation docs tell agents to choose one child completion return channel")
    func docsChooseOneCompletionChannel() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            #expect(doc.contains("Choose one completion return channel"))
            #expect(doc.contains("If you subscribe with `wait`"))
            #expect(doc.contains("do not also ask those same children to `send`"))
            #expect(doc.contains("If you need a child-authored result message"))
            #expect(doc.contains("in your inbox"))
            #expect(doc.contains("do not also `wait` on that child"))
        }
    }

    @Test("delegation docs tell the parent to archive children that send-and-stop, reviewers included")
    func docsArchiveParkedChildren() throws {
        for doc in [try #require(DelegationDocs.load(.claudeSkill)),
                    try #require(DelegationDocs.load(.codexAgents))] {
            // A send-and-stop child (fork / probe / reviewer) parks in `waiting` — the parent reclaims it.
            #expect(doc.contains("ends its turn is left `waiting`, not"))
            #expect(doc.contains("`archive` the card"))
            #expect(doc.contains("research forks, fan-out probes, reviewers alike"))
            // …and the review pair's teardown happens only once the bound pass CLOSES.
            #expect(doc.contains("Then archive both reviewers — the parent's job"))
            #expect(doc.contains("confirm/deny turn needs their context"))
            #expect(doc.contains("A reviewer left `waiting` is a leak"))
        }
    }

    @Test("shared guidance bundle keeps the same named delegation and tree sources for each provider")
    func guidanceBundleUsesSharedSources() throws {
        let codex = AgentGuidance.sections(for: "codex")
        #expect(codex.map(\.name) == ["delegation", "tree", "image-publishing"])
        #expect(codex[0].content == (try #require(DelegationDocs.forAgent("codex"))))
        #expect(codex[1].content == (try #require(TreeDocs.forAgent("codex"))))
        #expect(codex[2].content == (try #require(ImageDocs.forAgent("codex"))))
        let instructions = try #require(AgentGuidance.developerInstructions(for: "codex"))
        #expect(instructions.contains(codex[0].content))
        #expect(instructions.contains(codex[1].content))
        #expect(instructions.contains(codex[2].content))

        let claude = AgentGuidance.sections(for: "claude-code")
        #expect(claude.map(\.name) == ["delegation", "tree", "image-publishing"])
        #expect(claude[0].content == (try #require(DelegationDocs.forAgent("claude-code"))))
        #expect(claude[1].content == (try #require(TreeDocs.forAgent("claude-code"))))
        #expect(claude[2].content == (try #require(ImageDocs.forAgent("claude-code"))))
    }

    // MARK: provider-owned filesystem packaging

    @Test("shared guidance install writes a preselected Claude section, creating parents")
    func guidanceInstallWritesSection() throws {
        let base = NSTemporaryDirectory() + "guidance-install-\(UUID().uuidString)"
        let path = "\(base)/.claude/skills/orchestra-delegation/SKILL.md"
        let section = try #require(AgentGuidance.sections(for: "claude-code").first { $0.name == "delegation" })
        #expect(AgentGuidance.install(section, at: path))
        #expect(AgentGuidance.install(section, at: path)) // idempotent overwrite
        #expect(try String(contentsOfFile: path, encoding: .utf8) == section.content)
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("shared guidance install degrades gracefully when the directory cannot be created")
    func guidanceInstallGracefulOnUnwritable() throws {
        let section = try #require(AgentGuidance.sections(for: "claude-code").first)
        #expect(!AgentGuidance.install(section,
                                      at: "/System/nonexistent-\(UUID().uuidString)/SKILL.md"))
    }
}
