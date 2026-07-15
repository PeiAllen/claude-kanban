import Foundation
import Testing
@testable import OrchestraCore

@Suite("Transcript image lifecycle cleanup")
struct TranscriptImageLifecycleTests {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL96QAAAABJRU5ErkJggg=="

    @Test("relaunch and archive remove media outside the card current session")
    func relaunchAndArchiveExpireReferences() async throws {
        let env = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let source = try writePNG(to: env.base + "/source.png")
        let old = try await env.svc.publishImage(card.id, sourcePath: source, caption: "before")

        _ = await env.svc.transition(card.id, to: .relaunching)
        await #expect(throws: OrchestraError.self) {
            try await env.svc.transcriptImage(card.id, referenceID: old.id)
        }

        let current = try await env.svc.publishImage(card.id, sourcePath: source, caption: "current")
        try await env.svc.archive(card.id)
        await #expect(throws: OrchestraError.self) {
            try await env.svc.transcriptImage(card.id, referenceID: current.id)
        }
        #expect(!FileManager.default.fileExists(atPath: env.base + "/state/media/\(card.id.uuidString.lowercased())"))
    }

    @Test("boot reconciliation retains only a non-archived card current epoch")
    func bootReconciliationPrunesOrphanedMedia() async throws {
        let env = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let source = try writePNG(to: env.base + "/source.png")
        let reference = try await env.svc.publishImage(card.id, sourcePath: source, caption: nil)
        let orphanID = UUID()
        try FileManager.default.createDirectory(atPath: env.base + "/state/media/\(orphanID.uuidString.lowercased())/1",
                                                withIntermediateDirectories: true)

        await env.svc.reconcileTranscriptMediaAtBoot()

        #expect(try await env.svc.transcriptImage(card.id, referenceID: reference.id).reference == reference)
        #expect(!FileManager.default.fileExists(atPath: env.base + "/state/media/\(orphanID.uuidString.lowercased())"))
    }

    private func writePNG(to path: String) throws -> String {
        try #require(Data(base64Encoded: pngBase64)).write(to: URL(fileURLWithPath: path))
        return path
    }
}
