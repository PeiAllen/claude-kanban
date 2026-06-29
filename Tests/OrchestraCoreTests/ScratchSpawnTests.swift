import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn — scratch cards")
struct ScratchSpawnTests {
    @Test("scratch spawn creates the dir and marks origin .scratch")
    func scratchSpawnCreatesDirAndMarksOrigin() async throws {
        let env = TestEnv.make()
        let t = try await env.svc.spawn(SpawnInput(prompt: "mess around", scratch: true))
        #expect(t.origin == .scratch)
        #expect(t.cwd == Config.scratchDir(t.id))
        #expect(FileManager.default.fileExists(atPath: t.cwd))
        try? FileManager.default.removeItem(atPath: t.cwd)   // cleanup
    }
}
