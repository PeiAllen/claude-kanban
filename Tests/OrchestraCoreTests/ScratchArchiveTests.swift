import Foundation
import Testing
@testable import OrchestraCore

@Suite("Archive — scratch cards")
struct ScratchArchiveTests {
    @Test("archiving a scratch card rm -rf's its dir, even when non-empty")
    func archivingScratchRemovesDir() async throws {
        try await withScratchLock {
            let env = TestEnv.make()
            let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", scratch: true))
            let marker = "\(t.cwd)/note.txt"
            try "keep?".write(toFile: marker, atomically: true, encoding: .utf8)
            try await TestEnv.archiveAndTeardown(env.svc, t.id, source: .app)   // teardown rm -rf's the dir
            #expect(!FileManager.default.fileExists(atPath: t.cwd))   // unconditional, even non-empty
        }
    }
}
