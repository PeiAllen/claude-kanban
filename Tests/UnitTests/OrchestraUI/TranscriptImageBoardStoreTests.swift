import Foundation
import XCTest
import OrchestraKit
@testable import OrchestraUI

@MainActor
final class TranscriptImageBoardStoreTests: XCTestCase {
    func testTranscriptImageUsesCardScopedMediaRPC() async throws {
        let cardID = UUID()
        let referenceID = UUID()
        let reference = TranscriptImageReference(
            id: referenceID,
            cardId: cardID,
            sessionEpoch: 7,
            caption: "preview",
            mimeType: "image/png",
            filename: "preview.png"
        )
        let expected = TranscriptImagePayload(reference: reference, dataBase64: "cG5n")
        let transport = ImmediateMediaTransport(payload: expected)
        let client = ControlClient(transport: { transport }, source: .app)
        let store = BoardStore(platform: .noop)
        store.injectClientForTesting(client)
        try client.connect()
        defer { client.close() }

        let received = try await store.transcriptImage(cardID, referenceID: referenceID)

        XCTAssertEqual(received, expected)
        XCTAssertEqual(transport.lastRequest?.method, "media")
        XCTAssertEqual(transport.lastRequest?.params["ref"], .string(cardID.uuidString))
        XCTAssertEqual(transport.lastRequest?.params["id"], .string(referenceID.uuidString))
    }

    private final class ImmediateMediaTransport: Transport, @unchecked Sendable {
        struct Request: Equatable {
            let method: String
            let params: [String: JSONValue]
        }

        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private let payload: TranscriptImagePayload
        private var lines: [Data] = []
        private var eof = false
        private var recordedRequest: Request?

        init(payload: TranscriptImagePayload) {
            self.payload = payload
        }

        var lastRequest: Request? {
            lock.withLock { recordedRequest }
        }

        func open() throws {}

        func write(_ data: Data) -> Bool {
            guard let request = try? RPCCodec.decoder.decode(RPCRequest.self, from: data),
                  let id = request.id
            else { return false }

            let response: RPCResponse
            switch request.method {
            case "version":
                response = RPCResponse(id: id, result: .object(["version": .string("fake")]))
            case "media":
                guard case let .object(params)? = request.params,
                      let encodedPayload = try? JSONValue(encodable: payload)
                else { return false }
                lock.withLock { recordedRequest = Request(method: request.method, params: params) }
                response = RPCResponse(id: id, result: encodedPayload)
            default:
                response = RPCResponse(id: id, result: nil,
                                       error: RPCError(code: -32000, message: "unexpected RPC"))
            }

            guard let line = try? RPCCodec.line(response) else { return false }
            lock.withLock { lines.append(line) }
            semaphore.signal()
            return true
        }

        func readLine() -> Data? {
            while true {
                semaphore.wait()
                let result: Data?? = lock.withLock {
                    if !lines.isEmpty { return .some(lines.removeFirst()) }
                    if eof { return .some(nil) }
                    return nil
                }
                if let result { return result }
            }
        }

        func shutdown() { close() }

        func close() {
            lock.withLock { eof = true }
            semaphore.signal()
        }
    }
}
