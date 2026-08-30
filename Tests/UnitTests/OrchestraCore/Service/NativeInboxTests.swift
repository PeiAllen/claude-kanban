import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

@Suite("Native inbox delivery")
struct NativeInboxTests {
    @Test("a live native sender accepts queued work while the provider reports running")
    func sendsThroughLiveHandleWithoutStatusGate() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-inbox")
        )
        let sender = RecordingNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        await env.svc.testSetTurnStatus(card.id, .running)
        try await env.svc.send(card.id, "deliver while running")

        try await pollUntil("native sender accepts the queued message") {
            sender.messages == ["deliver while running"]
        }
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)
        #expect(await env.svc.inbox.history(card.id).map(\.text) == ["deliver while running"])
    }

    @Test("three rejected submissions fail the FIFO head until its owner retries it")
    func failsAfterThreeAttemptsThenRetriesInFIFOOrder() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-retry")
        )
        let sender = ScriptedNativeInboxSender(failuresRemaining: 3)
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        try await env.svc.send(card.id, "first")
        try await env.svc.send(card.id, "later")
        try await pollUntil("three bounded provider attempts") { sender.messages.count == 3 }

        let unresolved = try await env.svc.inboxPeek(card.id)
        #expect(unresolved.map(\.text) == ["first", "later"])
        #expect(unresolved.map(\.state) == [.failed, .queued])
        #expect(sender.messages == ["first", "first", "first"])

        sender.setFailuresRemaining(0)
        let retry = try #require(CommandRegistry().command("inbox-retry"))
        _ = try await retry.run(env.svc, .object([
            "ref": .string(card.shortId),
            "id": .string(unresolved[0].id.uuidString),
        ]), .mcp)

        try await pollUntil("retried head and following FIFO row to be accepted") {
            await env.svc.inbox.history(card.id).map(\.text) == ["first", "later"]
        }
        #expect(sender.messages == ["first", "first", "first", "first", "later"])
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)
    }

    @Test("an edit during submission prevents the old text from becoming provider-accepted history")
    func editWinsOverStaleProviderAcceptance() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-cas")
        )
        let sender = GatedNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        try await env.svc.send(card.id, "old text")
        await sender.waitUntilFirstSendIsParked()
        let original = try #require(await env.svc.inboxPeek(card.id).first)
        try await env.svc.inboxUpdate(card.id, messageId: original.id, text: "new text")
        sender.releaseFirstSend()

        try await pollUntil("only edited text to reach accepted history") {
            await env.svc.inbox.history(card.id).map(\.text) == ["new text"]
        }
        #expect(sender.messages == ["old text", "new text"])
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)
    }

    @Test("endpoint replacement cancels, closes, replaces, and rearms the native sender")
    func replacementOwnsTheQueuedMessage() async throws {
        let adapter = ClaudeCodeAdapter(binOverride: "fake-claude")
        let env = TestEnv.make(
            grace: 2,
            registry: AgentRegistry(adapters: [adapter])
        )
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-replace")
        )
        let oldSender = GatedNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: oldSender)

        try await env.svc.send(card.id, "deliver through replacement")
        await oldSender.waitUntilFirstSendIsParked()

        let socketPath = "/tmp/orch-native-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UDS.listen(path: socketPath)
        defer {
            closeFD(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let serverFinished = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { serverFinished.signal() }
            let client = UDS.accept(listener)
            guard client >= 0 else { return }
            defer { closeFD(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while UDS.read(client, into: &buffer) != nil {}
        }
        server.start()

        let replacement = AgentMessageEndpointReport(
            providerId: stored.agentId,
            harnessSessionId: try #require(stored.agentSessionId),
            endpoint: .claudeHookRPC(socketPath: socketPath, token: "replacement-token")
        )
        await env.svc.receiveAgentMessageEndpoint(
            cardId: card.id, report: replacement, observedEpoch: stored.sessionEpoch, event: .statusLine
        )

        try await pollUntil("replacement sender to accept the queued row") {
            await env.svc.inbox.history(card.id).map(\.text) == ["deliver through replacement"]
        }
        #expect(oldSender.shutdownCount == 1)
        #expect(await env.svc.runtime[card.id]?.agentMessageHandle?.endpoint == replacement.endpoint)
        #expect(await Self.wait(serverFinished) == .success)
    }

    private static func wait(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10))
            }
        }
    }
}

private extension OrchestraService {
    func installNativeInboxSenderForTest(card: Task, sender: any AgentMessageSender) {
        ensureRuntime(for: card)
        runtime[card.id]?.agentMessageHandle = .init(
            identity: .init(
                providerId: card.agentId,
                sessionEpoch: card.sessionEpoch,
                harnessSessionId: card.agentSessionId!
            ),
            endpoint: .claudeHookRPC(socketPath: "/tmp/native-inbox-test.sock", token: "test-token"),
            sender: sender
        )
    }
}

private final class RecordingNativeInboxSender: AgentMessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var shutdowns = 0

    var messages: [String] { lock.withLock { storage } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func send(_ message: String) async throws {
        lock.withLock { storage.append(message) }
    }

    func shutdown() { lock.withLock { shutdowns += 1 } }
}

private enum NativeInboxTestError: Error { case rejected }

private final class ScriptedNativeInboxSender: AgentMessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int) { self.failuresRemaining = failuresRemaining }

    var messages: [String] { lock.withLock { storage } }
    func setFailuresRemaining(_ count: Int) { lock.withLock { failuresRemaining = count } }

    func send(_ message: String) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            storage.append(message)
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldFail { throw NativeInboxTestError.rejected }
    }

    func shutdown() {}
}

private final class GatedNativeInboxSender: AgentMessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private let firstSendGate = Gate()
    private var storage: [String] = []
    private var blocksFirstSend = true
    private var shutdowns = 0

    var messages: [String] { lock.withLock { storage } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func waitUntilFirstSendIsParked() async { await firstSendGate.reached() }
    func releaseFirstSend() { firstSendGate.release() }

    func send(_ message: String) async throws {
        let shouldBlock = lock.withLock { () -> Bool in
            storage.append(message)
            defer { blocksFirstSend = false }
            return blocksFirstSend
        }
        if shouldBlock { _ = await firstSendGate.park() }
    }

    func shutdown() {
        lock.withLock { shutdowns += 1 }
        firstSendGate.release()
    }
}
