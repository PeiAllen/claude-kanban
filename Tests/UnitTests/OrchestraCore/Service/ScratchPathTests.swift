import Foundation
import Testing
@testable import OrchestraCore

@Suite("Config — scratch paths")
struct ScratchPathTests {
    @Test("scratchDir is under the instance scratchRoot, keyed by id")
    func scratchDirUnderRootKeyedById() {
        let id = UUID()
        let cfg = Config(scratchRoot: "/tmp/xyz/scratch")
        let dir = cfg.scratchDir(id)
        #expect(dir.hasPrefix(cfg.scratchRoot + "/"))
        #expect(dir.hasSuffix(id.uuidString.lowercased()))
    }

    @Test("scratchRoot is per-Config state: two services sweep only their own roots")
    func scratchRootIsInjected() async throws {
        let a = TestEnv.make(), b = TestEnv.make()
        let cardA = try await TestEnv.spawnAndAwaitLive(a.svc, SpawnInput(id: UUID(), prompt: "p", scratch: true))
        // Give b a live scratch card of its own so its sweep passes the empty-store guard and actually
        // walks b's root — the sweep must still never see (or delete) a's dir, which lives under a's root.
        let cardB = try await TestEnv.spawnAndAwaitLive(b.svc, SpawnInput(id: UUID(), prompt: "q", scratch: true))
        await b.svc.sweepOrphanScratch(graceInterval: 0)
        #expect(FileManager.default.fileExists(atPath: cardA.cwd))
        #expect(cardA.cwd.hasPrefix(a.base))                  // the scratch dir lives under a's private base
        try? FileManager.default.removeItem(atPath: cardA.cwd)
        try? FileManager.default.removeItem(atPath: cardB.cwd)
    }

    @Test("setConfig cannot move the scratch fence")
    func setConfigPreservesScratchRoot() async throws {
        let env = TestEnv.make()
        let before = await env.svc.getConfig().scratchRoot
        #expect(before.hasPrefix(env.base))                   // TestEnv wired a private root
        await env.svc.setConfig { $0.reposRoot = $0.reposRoot + "" }   // wire-shaped wholesale replacement
        #expect(await env.svc.getConfig().scratchRoot == before)
    }
}
