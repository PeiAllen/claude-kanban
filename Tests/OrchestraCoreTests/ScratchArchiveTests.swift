import Foundation
import Testing
@testable import OrchestraCore

@Suite("Archive — scratch cards")
struct ScratchArchiveTests {
    @Test("archiving a scratch card rm -rf's its dir, even when non-empty")
    func archivingScratchRemovesDir() async throws {
        let env = TestEnv.make()
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", scratch: true))
        let marker = "\(t.cwd)/note.txt"
        try "keep?".write(toFile: marker, atomically: true, encoding: .utf8)
        try await env.svc.archive(t.id, source: .app)
        #expect(!FileManager.default.fileExists(atPath: t.cwd))   // unconditional, even non-empty
    }
}
