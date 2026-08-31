import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex app-server observer")
struct CodexAppServerObserverTests {
    @Test("observer initializes, subscribes, reconciles, and forwards pushed notifications")
    func subscribeAndForward() throws {
        let resumeResult: JSONValue = .object([
            "thread": .object([
                "id": .string("thread-1"),
                "status": .object(["type": .string("idle")]),
            ]),
        ])
        let peer = FakeCodexAppServerPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: resumeResult),
            Self.notification("turn/started", ["threadId": .string("thread-1")]),
            Self.notification("turn/completed", ["threadId": .string("thread-1")]),
        ])
        let observer = CodexAppServerObserver(peer: peer)
        var observations: [RawTelemetry] = []

        #expect(throws: CodexAppServerError.connectionClosed) {
            try observer.run(
                binding: .init(harnessSessionId: "thread-1", cwd: "/work", startedAfter: nil)
            ) { observations.append($0) }
        }

        #expect(peer.didOpen)
        #expect(peer.didClose)
        #expect(peer.sent.count == 3)
        #expect(peer.sent[0]["method"]?.stringValue == "initialize")
        #expect(peer.sent[0]["id"]?.intValue == 1)
        #expect(peer.sent[1]["method"]?.stringValue == "initialized")
        #expect(peer.sent[1]["id"] == nil)
        #expect(peer.sent[2]["method"]?.stringValue == "thread/resume")
        #expect(peer.sent[2]["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(observations == [
            .rpcResponse(method: "thread/resume", result: resumeResult),
            .rpcNotification(method: "turn/started", params: .object(["threadId": .string("thread-1")])),
            .rpcNotification(method: "turn/completed", params: .object(["threadId": .string("thread-1")])),
        ])
    }

    @Test("observer leaves server requests unanswered so the co-present TUI remains the sole responder")
    func ignoresServerRequests() throws {
        let peer = FakeCodexAppServerPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: .object([
                "thread": .object([
                    "id": .string("thread-1"),
                    "status": .object(["type": .string("active"), "activeFlags": .array([])]),
                ]),
            ])),
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(91),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([:]),
            ]),
        ])
        let observer = CodexAppServerObserver(peer: peer)

        #expect(throws: CodexAppServerError.connectionClosed) {
            try observer.run(
                binding: .init(harnessSessionId: "thread-1", cwd: "/work", startedAfter: nil)
            ) { _ in }
        }

        #expect(peer.sent.count == 3)
        #expect(!peer.sent.contains { $0["id"]?.intValue == 91 })
    }

    @Test("unbound observer binds only one launch-scoped root thread, then follows exact starts")
    func discoverUnboundThread() throws {
        let eligible = Self.thread(id: "thread-1", cwd: "/work", createdAt: 101)
        let peer = FakeCodexAppServerPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: .object(["data": .array([
                Self.thread(id: "stale", cwd: "/work", createdAt: 99),
                Self.thread(id: "child", cwd: "/work", createdAt: 101, parent: "thread-1"),
                Self.thread(id: "ephemeral", cwd: "/work", createdAt: 101, ephemeral: true),
                Self.thread(id: "other-cwd", cwd: "/other", createdAt: 101),
                eligible,
            ])])),
        ])
        let observer = CodexAppServerObserver(peer: peer)
        var observations: [RawTelemetry] = []

        #expect(throws: CodexAppServerError.connectionClosed) {
            try observer.run(binding: .init(
                harnessSessionId: nil,
                cwd: "/work",
                startedAfter: Date(timeIntervalSince1970: 100.9)
            )) { observations.append($0) }
        }

        #expect(peer.sent[2]["method"]?.stringValue == "thread/list")
        #expect(peer.sent[2]["params"]?["cwd"]?.stringValue == "/work")
        #expect(observations == [
            .rpcResponse(method: "thread/list", result: .object(["data": .array([eligible])])),
        ])

        let replacement = Self.thread(id: "thread-3", cwd: "/work", createdAt: 102)
        let ambiguousPeer = FakeCodexAppServerPeer(incoming: [
            Self.response(id: 1, result: .object([:])),
            Self.response(id: 2, result: .object(["data": .array([
                eligible,
                Self.thread(id: "thread-2", cwd: "/work", createdAt: 101),
            ])])),
            Self.notification("thread/started", ["thread": replacement]),
        ])
        let ambiguousObserver = CodexAppServerObserver(peer: ambiguousPeer)
        observations.removeAll()

        #expect(throws: CodexAppServerError.connectionClosed) {
            try ambiguousObserver.run(binding: .init(
                harnessSessionId: nil,
                cwd: "/work",
                startedAfter: Date(timeIntervalSince1970: 100.9)
            )) { observations.append($0) }
        }
        #expect(observations == [
            .rpcNotification(method: "thread/started", params: .object(["thread": replacement])),
        ])
    }

    private static func response(id: Int, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .int(id), "result": result])
    }

    private static func notification(_ method: String, _ params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
    }

    private static func thread(
        id: String,
        cwd: String,
        createdAt: Int,
        parent: String? = nil,
        ephemeral: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "cwd": .string(cwd),
            "createdAt": .int(createdAt),
            "parentThreadId": parent.map(JSONValue.string) ?? .null,
            "ephemeral": .bool(ephemeral),
            "status": .object(["type": .string("idle")]),
        ])
    }
}

private final class FakeCodexAppServerPeer: CodexAppServerPeer, @unchecked Sendable {
    var incoming: [JSONValue]
    var sent: [JSONValue] = []
    var didOpen = false
    var didClose = false

    init(incoming: [JSONValue]) { self.incoming = incoming }

    func open() throws { didOpen = true }
    func send(_ message: JSONValue) throws { sent.append(message) }
    func receive() throws -> JSONValue {
        guard !incoming.isEmpty else { throw CodexAppServerError.connectionClosed }
        return incoming.removeFirst()
    }
    func shutdown() {}
    func close() { didClose = true }
}
