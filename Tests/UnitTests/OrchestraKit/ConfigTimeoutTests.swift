import Foundation
import Testing
@testable import OrchestraKit

@Suite("Config — timeout knobs (3.1)")
struct ConfigTimeoutTests {

    @Test("timeout knobs default to 600/30/15 and are overridable")
    func test_configTimeoutDefaults() throws {
        let d = Config()
        #expect(d.worktreeAddTimeout == 600)
        #expect(d.sessionLaunchTimeout == 30)
        #expect(d.controlTimeout == 15)
        #expect(d.autoInstallMCPGlobally == false)

        let custom = Config(worktreeAddTimeout: 5, sessionLaunchTimeout: 6, controlTimeout: 7,
                            autoInstallMCPGlobally: true)
        #expect(custom.worktreeAddTimeout == 5)
        #expect(custom.sessionLaunchTimeout == 6)
        #expect(custom.controlTimeout == 7)
        #expect(custom.autoInstallMCPGlobally)

        // round-trips through Codable
        let data = try JSONEncoder().encode(custom)
        let back = try JSONDecoder().decode(Config.self, from: data)
        #expect(back == custom)
    }

    @Test("a config.json without the new keys still decodes, keeping defaults")
    func test_configForwardCompat() throws {
        // A pre-upgrade config.json with NONE of the three new keys.
        let legacy = """
        {
          "reposRoot": "/r",
          "worktreesRoot": "/w",
          "defaultAgentId": "claude-code",
          "allowlist": [],
          "maxConcurrentRevivals": 4,
          "revivalGraceSeconds": 15,
          "statusLineMode": "passthroughGlobal"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: legacy)
        #expect(c.worktreeAddTimeout == 600)
        #expect(c.sessionLaunchTimeout == 30)
        #expect(c.controlTimeout == 15)
        #expect(c.autoInstallMCPGlobally == false)
        // existing fields survived
        #expect(c.reposRoot == "/r")
        #expect(c.worktreesRoot == "/w")

        // and a config.json that DOES set one new key keeps that override
        let withOne = """
        {
          "reposRoot": "/r", "worktreesRoot": "/w", "defaultAgentId": "claude-code",
          "allowlist": [], "maxConcurrentRevivals": 4, "revivalGraceSeconds": 15,
          "statusLineMode": "passthroughGlobal", "controlTimeout": 3
        }
        """.data(using: .utf8)!
        let c2 = try JSONDecoder().decode(Config.self, from: withOne)
        #expect(c2.controlTimeout == 3)
        #expect(c2.worktreeAddTimeout == 600)   // the unset ones still default
    }
}
