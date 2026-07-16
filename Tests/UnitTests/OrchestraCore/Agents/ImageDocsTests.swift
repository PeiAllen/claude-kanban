import Foundation
import Testing
@testable import OrchestraCore

@Suite("Transcript image publishing docs")
struct ImageDocsTests {
    @Test("both agent variants require an explicit safe publish command")
    func bothVariantsTeachExplicitPublishing() throws {
        let claude = try #require(ImageDocs.load(.claudeSkill))
        let codex = try #require(ImageDocs.load(.codexAgents))

        #expect(claude.hasPrefix("---\n"))
        #expect(claude.contains("name: orchestra-image-publishing"))
        #expect(!codex.hasPrefix("---\n"))
        for doc in [claude, codex] {
            #expect(doc.contains("orchestra publish-image <absolute-image-path> [--caption <text>]"))
            #expect(doc.contains("absolute PNG or JPEG"))
            #expect(doc.contains("Do not publish an arbitrary path"))
            #expect(doc.contains("temporary"))
        }
    }

    @Test("image publishing reaches both providers through the shared guidance bundle")
    func bothProvidersReceiveImageGuidance() throws {
        // The bundle is the seam: registering the section once is what gets it to Claude (a project
        // skill) and Codex (launch-scoped developer instructions), with no per-adapter branch.
        for agentId in ["claude-code", "codex"] {
            let section = try #require(AgentGuidance.sections(for: agentId)
                .first { $0.name == "image-publishing" })
            #expect(section.content == (try #require(ImageDocs.forAgent(agentId))))
        }

        let codexInstructions = try #require(AgentGuidance.developerInstructions(for: "codex"))
        #expect(codexInstructions.contains(try #require(ImageDocs.forAgent("codex"))))
    }
}
