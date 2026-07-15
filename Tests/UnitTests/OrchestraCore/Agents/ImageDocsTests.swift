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

    @Test("Claude and Codex materialize their own image publishing guidance")
    func adaptersInstallTheirPackagedGuidance() throws {
        let cwd = NSTemporaryDirectory() + "image-docs-cwd-\(UUID().uuidString)"
        let home = NSTemporaryDirectory() + "image-docs-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: cwd)
            try? FileManager.default.removeItem(atPath: home)
        }

        try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: cwd))
        let claudePath = "\(cwd)/.claude/skills/orchestra-image-publishing/SKILL.md"
        #expect(try String(contentsOfFile: claudePath, encoding: .utf8) == ImageDocs.load(.claudeSkill))

        let codex = CodexAdapter(codexHome: home, hookTrustBypass: false)
        try codex.prepareToLaunch(AdapterContext(cwd: cwd, trustCwd: false))
        let agents = try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8)
        #expect(agents.contains(try #require(ImageDocs.forAgent("codex"))))
        #expect(agents.components(separatedBy: AgentsFileComposer.startMarker("image-publishing")).count == 2)
    }
}
