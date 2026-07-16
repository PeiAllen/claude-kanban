import Foundation
import Testing
@testable import OrchestraCore

@Suite("Tmux terminal configuration")
struct TmuxConfigurationTests {

    @Test("embedded config advertises synchronized updates to SwiftTerm")
    func advertisesSynchronizedUpdates() throws {
        let path = try #require(SessionManager.bundledConf)
        let config = try String(contentsOfFile: path, encoding: .utf8)

        // Codex uses DECSET 2026 around high-rate TUI frames. tmux must know that its xterm client
        // supports the `sync` feature or it unwraps that batching before SwiftTerm can render it.
        #expect(config.contains("xterm-256color:sixel:sync"))
    }
}
