import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("Transcript image media store")
struct MediaStoreTests {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL96QAAAABJRU5ErkJggg=="

    @Test("publish stores a bounded PNG under the card current epoch and fetches base64 bytes")
    func publishesCurrentEpochPNG() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = try writePNG(to: root + "/source.png")
        let store = MediaStore(root: root)
        let cardID = UUID()

        let reference = try await store.publish(cardId: cardID, sessionEpoch: 7,
                                                sourcePath: source, caption: "chart")
        let payload = try await store.payload(cardId: cardID, sessionEpoch: 7, referenceID: reference.id)

        #expect(reference.cardId == cardID)
        #expect(reference.sessionEpoch == 7)
        #expect(reference.caption == "chart")
        #expect(reference.mimeType == "image/png")
        #expect(reference.filename == "\(reference.id.uuidString.lowercased()).png")
        #expect(Data(base64Encoded: payload.dataBase64) == Data(base64Encoded: pngBase64))
        #expect(FileManager.default.fileExists(atPath: root + "/\(cardID.uuidString.lowercased())/7/index.json"))
    }

    @Test("symlink, non-image, and oversized source fail without a record")
    func rejectsUnsafeSources() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = MediaStore(root: root)
        let cardID = UUID()
        let text = root + "/not-image.txt"
        try Data("not an image".utf8).write(to: URL(fileURLWithPath: text))

        await #expect(throws: OrchestraError.self) {
            try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: text, caption: nil)
        }

        let link = root + "/link.png"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: text)
        await #expect(throws: OrchestraError.self) {
            try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: link, caption: nil)
        }

        let tooLarge = root + "/large.png"
        try Data(repeating: 0, count: MediaStore.defaultMaxFileBytes + 1).write(to: URL(fileURLWithPath: tooLarge))
        await #expect(throws: OrchestraError.self) {
            try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: tooLarge, caption: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/\(cardID.uuidString.lowercased())/1/index.json"))
    }

    @Test("store rejects a publish above the session quota without evicting an existing record")
    func rejectsOverQuotaWithoutEviction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/tiny.png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 1, 2, 3]).write(to: URL(fileURLWithPath: source))
        let store = MediaStore(root: root, maxFileBytes: 16, maxSessionBytes: 20)
        let cardID = UUID()

        let first = try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: source, caption: nil)
        await #expect(throws: OrchestraError.self) {
            try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: source, caption: nil)
        }
        #expect(try await store.payload(cardId: cardID, sessionEpoch: 1, referenceID: first.id).reference == first)
    }

    @Test("epoch and card cleanup make old opaque references expire")
    func cleanupExpiresOldReferences() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = try writePNG(to: root + "/source.png")
        let store = MediaStore(root: root)
        let cardID = UUID()
        let old = try await store.publish(cardId: cardID, sessionEpoch: 1, sourcePath: source, caption: nil)
        let current = try await store.publish(cardId: cardID, sessionEpoch: 2, sourcePath: source, caption: nil)

        await store.removePriorEpochs(cardId: cardID, keeping: 2)
        await #expect(throws: OrchestraError.self) {
            try await store.payload(cardId: cardID, sessionEpoch: 1, referenceID: old.id)
        }
        #expect(try await store.payload(cardId: cardID, sessionEpoch: 2, referenceID: current.id).reference == current)

        await store.removeCard(cardID)
        await #expect(throws: OrchestraError.self) {
            try await store.payload(cardId: cardID, sessionEpoch: 2, referenceID: current.id)
        }
    }

    private func temporaryRoot() -> String {
        let root = NSTemporaryDirectory() + "orch-media-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func writePNG(to path: String) throws -> String {
        try #require(Data(base64Encoded: pngBase64)).write(to: URL(fileURLWithPath: path))
        return path
    }
}
