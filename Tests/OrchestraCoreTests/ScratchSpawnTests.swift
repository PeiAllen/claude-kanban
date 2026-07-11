import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn — scratch cards")
struct ScratchSpawnTests {
    @Test("scratch spawn creates the dir and marks origin .scratch")
    func scratchSpawnCreatesDirAndMarksOrigin() async throws {
        try await withScratchLock {
            let env = TestEnv.make()
            let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "mess around", scratch: true))
            #expect(t.origin == .scratch)
            #expect(t.cwd == Config.scratchDir(t.id))
            #expect(FileManager.default.fileExists(atPath: t.cwd))
            try? FileManager.default.removeItem(atPath: t.cwd)   // cleanup
        }
    }
}
