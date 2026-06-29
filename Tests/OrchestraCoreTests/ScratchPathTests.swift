import Foundation
import Testing
@testable import OrchestraCore

@Suite("Config — scratch paths")
struct ScratchPathTests {
    @Test("scratchDir is under scratchRoot, keyed by id")
    func scratchDirUnderRootKeyedById() {
        let id = UUID()
        let dir = Config.scratchDir(id)
        #expect(dir.hasPrefix(Config.scratchRoot + "/"))
        #expect(dir.hasSuffix(id.uuidString.lowercased()))
    }
}
