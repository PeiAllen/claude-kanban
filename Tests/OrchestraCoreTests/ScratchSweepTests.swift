import Foundation
import Testing
@testable import OrchestraCore

@Suite("Sweep — orphan scratch dirs", .serialized)
struct ScratchSweepTests {
    @Test("sweep removes scratch dirs with no live card, keeps live ones")
    func sweepRemovesOrphansKeepsLive() async throws {
        try await withScratchLock {
            let env = TestEnv.make()
            let orphan = Config.scratchDir(UUID())
            try FileManager.default.createDirectory(atPath: orphan, withIntermediateDirectories: true)
            let live = try await env.svc.spawn(SpawnInput(prompt: "x", scratch: true))
            await env.svc.sweepOrphanScratch()
            #expect(!FileManager.default.fileExists(atPath: orphan))   // orphan gone
            #expect(FileManager.default.fileExists(atPath: live.cwd))  // live kept
            try? FileManager.default.removeItem(atPath: live.cwd)
        }
    }
}
