import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("Transcript image control RPC", .serialized)
struct TranscriptImageControlTests {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL96QAAAABJRU5ErkJggg=="

    @Test("media RPC returns a card-scoped opaque image payload")
    func mediaRPCScopesOpaqueReferences() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let first = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "a", repo: repo, branch: "a"))
        let second = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "b", repo: repo, branch: "b"))
        let source = try writePNG(to: env.base + "/source.png")
        let reference = try await env.svc.publishImage(first.id, sourcePath: source, caption: "diagram")
        let socket = "/tmp/orch-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(service: env.svc, socketPath: socket)
        try server.start()
        defer { server.stop() }
        let client = ControlClient(socketPath: socket, source: .app)
        try client.connect()
        defer { client.close() }

        let payload = try await client.media(ref: first.shortId, referenceID: reference.id)
        #expect(payload.reference == reference)
        #expect(Data(base64Encoded: payload.dataBase64) == Data(base64Encoded: pngBase64))
        await #expect(throws: (any Error).self) {
            try await client.media(ref: second.shortId, referenceID: reference.id)
        }
    }

    private func writePNG(to path: String) throws -> String {
        try #require(Data(base64Encoded: pngBase64)).write(to: URL(fileURLWithPath: path))
        return path
    }
}
