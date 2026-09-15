import Testing
import Foundation
import OrchestraKit
@testable import OrchestraCore

@Suite("Adapter cardFile ⇄ writer path consistency")
struct CardFileConsistencyTests {
    private func card(cwd: String, id: UUID = UUID()) -> Task {
        Task(id: id, title: "t", repo: "", branch: "", cwd: cwd, origin: .worktree,
             model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0, initialPrompt: "")
    }

    @Test("Claude cardFile is the card-settings-<djb2>.json spec")
    func claudeSpec() {
        let spec = ClaudeCodeAdapter().cardFile
        #expect(spec?.prefix == "card-settings-")
        #expect(spec?.suffix == ".json")
        let cwd = "/wt/alpha"
        #expect(spec?.token(for: card(cwd: cwd)) == CardFileSpec.cwdHash(cwd))
        // path composes directory + prefix + token + suffix (directory is $dataDir by construction).
        #expect(spec?.path(token: "T") == "\(spec!.directory)/card-settings-T.json")
    }

    @Test("Codex cardFile path equals the file that `-p <profileName>` resolves to")
    func codexProfileAgreement() {
        let home = "/tmp/codexhome"
        let adapter = CodexAdapter(codexHome: home)
        let cwd = "/wt/beta"
        // The file `prepareToLaunch` writes:
        let filePath = CodexLaunchConfiguration.profilePath(cwd: cwd, codexHome: home)
        // The spec's path for the same card:
        let specPath = adapter.cardFile?.path(token: CardFileSpec.cwdHash(cwd))
        #expect(specPath == filePath)
        // And the -p arg (profile NAME, no dir/suffix) is prefix+token:
        #expect(CodexLaunchConfiguration.profileName(cwd: cwd) == "orch-\(CardFileSpec.cwdHash(cwd))")
    }

    @Test("Codex writes the ownership marker the sweep checks for, as the file's first line")
    func codexOwnershipMarker() {
        let adapter = CodexAdapter(codexHome: "/tmp/ch")
        #expect(adapter.cardFile?.ownershipMarker == CodexLaunchConfiguration.ownershipMarker)
        let toml = CodexLaunchConfiguration.profileTOML(
            context: AdapterContext(cwd: "/wt/x"), agentId: "codex")
        #expect(toml.hasPrefix(CodexLaunchConfiguration.ownershipMarker))   // sweep reads the head for this
    }

    @Test("Orchestra's own data-dir specs carry NO marker (the directory is the ownership proof)")
    func dataDirSpecsHaveNoMarker() {
        #expect(ClaudeCodeAdapter().cardFile?.ownershipMarker == nil)
    }

    @Test("an adapter without a cardFile is allowed (default nil)")
    func defaultNil() {
        struct Bare: Adapter {
            let id = "bare"; let name = "Bare"; let icon = "x"; let bin = "b"; let enabled = true
            var capabilities: AgentCapabilities { .claudeCode }
            func catalog() -> [AgentModel] { [] }
            func newSessionId() -> String? { nil }
            func start(_ ctx: AdapterContext) -> [String] { [] }
            func resume(_ ctx: AdapterContext) -> [String]? { nil }
            func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? { nil }
        }
        #expect(Bare().cardFile == nil)
    }
}
