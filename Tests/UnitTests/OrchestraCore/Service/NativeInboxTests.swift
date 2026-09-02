import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

@Suite("Native inbox delivery", .serialized)
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

        try await env.svc.testSetTurnStatus(card.id, .running)
        try await env.svc.send(card.id, "deliver while running")

        try await pollUntil("native sender accepts the queued message") {
            sender.messages == ["deliver while running"]
        }
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)
        #expect(await env.svc.inbox.history(card.id).map(\.text) == ["deliver while running"])
    }

    @Test("three rejected submissions fail the FIFO head until its owner retries it")
    func failsAfterThreeAttemptsThenRetriesInFIFOOrder() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", scratch: true)
        )
        let sender = ScriptedNativeInboxSender(failuresRemaining: 3)
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        try await env.svc.send(card.id, "first")
        try await env.svc.send(card.id, "later")
        try await pollUntil("the first provider attempt") { sender.messages.count >= 1 }
        guard sender.messages == ["first"] else {
            #expect(sender.messages == ["first"])
            return
        }
        await clock.parked(1, deadlineAtLeast: .milliseconds(500))
        clock.advance(by: .milliseconds(500))
        try await pollUntil("the second provider attempt") { sender.messages.count >= 2 }
        #expect(sender.messages == ["first", "first"])
        await clock.parked(1, deadlineAtLeast: .seconds(1))
        clock.advance(by: .seconds(1))
        try await pollUntil("the third bounded provider attempt to fail its FIFO head") {
            guard let first = try? await env.svc.inboxPeek(card.id).first else { return false }
            return first.state == .failed
        }

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

    @Test("an explicit-id replay rearms its still-queued row")
    func dedupReplayRearmsQueuedMessage() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-dedup")
        )
        let sender = RecordingNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)
        let messageID = UUID()

        #expect(try await env.svc.inbox.enqueueIfUnknown(
            card.id, "replay me", id: messageID, source: .human
        ))
        _ = try await env.svc.send(card.id, "replay me", messageId: messageID)

        try await pollUntil("deduplicated replay to rearm native delivery", timeout: .seconds(3)) {
            sender.messages == ["replay me"]
        }
        #expect(await env.svc.inbox.history(card.id).map(\.text) == ["replay me"])
    }

    @Test("a missing handle and a same-session replacement share one three-attempt budget")
    func missingHandleAndReplacementShareBudget() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", scratch: true)
        )
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: RecordingNativeInboxSender())
        await env.svc.removeNativeInboxSenderForTest(card: stored)

        try await env.svc.send(card.id, "shared budget")
        await yieldBriefly()
        guard await env.svc.runtime[card.id]?.tasks[.nativeInbox] != nil else {
            #expect(await env.svc.runtime[card.id]?.tasks[.nativeInbox] != nil)
            return
        }
        await clock.parked(1, deadlineAtLeast: .milliseconds(500))

        let replacement = ScriptedNativeInboxSender(failuresRemaining: 2)
        await env.svc.replaceNativeInboxSenderForTest(card: stored, sender: replacement)
        try await pollUntil("the replacement's second budgeted attempt") { replacement.messages.count == 1 }
        await clock.parked(1, deadlineAtLeast: .seconds(1))
        clock.advance(by: .seconds(1))
        try await pollUntil("the shared budget to fail the queued row") {
            guard let row = try? await env.svc.inboxPeek(card.id).first else { return false }
            return row.state == .failed
        }

        #expect(replacement.messages == ["shared budget", "shared budget"])
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

    @Test("a live status refresh cannot resend queued work after provider acceptance was not persisted")
    func liveRefreshDoesNotResendAfterAcceptedPersistenceFailure() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-persist-failure")
        )
        let sender = RecordingNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        // A failed `markHandedOff` rolls its mutation back, leaving this exact queued/no-attempt state
        // after the provider has already accepted the text. Only an explicit user action or a genuine
        // sender/lifecycle edge may replay it; a live status refresh must not.
        try await env.svc.inbox.enqueue(card.id, "accepted before history write")
        #expect(try await env.svc.inboxPeek(card.id).map(\.state) == [.queued])
        #expect(await env.svc.runtime[card.id]?.tasks[.nativeInbox] == nil)

        await env.svc.stageMatchingNativeInboxEndpointForTest(card: stored)
        #expect(await env.svc.transition(card.id, to: .live(.waiting)) == .applied)
        // The first refresh consumes the matching hook endpoint. A later status-only refresh has no new
        // endpoint, but it must still preserve the current sender without turning status into a send arm.
        #expect(await env.svc.transition(card.id, to: .live(.running)) == .applied)
        await yieldBriefly()

        #expect(sender.messages.isEmpty)
        #expect(await env.svc.runtime[card.id]?.tasks[.nativeInbox] == nil)
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

    @Test("a live session rollover cannot hand off an old sender's held success")
    func liveSessionRolloverFencesHeldSuccess() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-rollover")
        )
        let sender = GatedNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        try await env.svc.send(card.id, "must remain queued")
        await sender.waitUntilFirstSendIsParked()
        try await env.svc.report(
            card.id,
            StatusReport(sessionId: "replacement-session", sessionSource: "clear"),
            observedEpoch: stored.sessionEpoch
        )
        #expect(sender.shutdownCount == 1)
        sender.releaseFirstSend()
        await yieldBriefly()

        #expect(try await env.svc.inboxPeek(card.id).map(\.state) == [.queued])
        #expect(await env.svc.store.get(card.id)?.agentSessionId == "replacement-session")
    }

    @Test("an epoch transition cannot hand off an old sender's held success")
    func transitionFencesHeldSuccess() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "native-epoch")
        )
        let sender = GatedNativeInboxSender()
        let stored = try #require(await env.svc.store.get(card.id))
        await env.svc.installNativeInboxSenderForTest(card: stored, sender: sender)

        try await env.svc.send(card.id, "must remain queued")
        await sender.waitUntilFirstSendIsParked()
        #expect(await env.svc.transition(card.id, to: .relaunching) == .applied)
        #expect(sender.shutdownCount == 1)
        sender.releaseFirstSend()
        await yieldBriefly()

        #expect(try await env.svc.inboxPeek(card.id).map(\.state) == [.queued])
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
        disarm(card.id, .nativeInbox)
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

    func removeNativeInboxSenderForTest(card: Task) {
        let previous = runtime[card.id]?.agentMessageHandle
        runtime[card.id]?.agentMessageHandle = nil
        previous?.sender.shutdown()
        armNativeInbox(card)
    }

    func replaceNativeInboxSenderForTest(card: Task, sender: any AgentMessageSender) {
        disarm(card.id, .nativeInbox)
        let previous = runtime[card.id]?.agentMessageHandle
        runtime[card.id]?.agentMessageHandle = nil
        previous?.sender.shutdown()
        installNativeInboxSenderForTest(card: card, sender: sender)
        armNativeInbox(card)
    }

    func stageMatchingNativeInboxEndpointForTest(card: Task) {
        guard let handle = runtime[card.id]?.agentMessageHandle else { return }
        runtime[card.id]?.pendingAgentMessageEndpoint = .init(
            identity: handle.identity,
            endpoint: handle.endpoint
        )
    }
}

private final class RecordingNativeInboxSender: AgentMessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var shutdowns = 0

    var messages: [String] { lock.withLock { storage } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func send(_ message: String, timeout: TimeInterval) async throws {
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

    func send(_ message: String, timeout: TimeInterval) async throws {
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

    func send(_ message: String, timeout: TimeInterval) async throws {
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
