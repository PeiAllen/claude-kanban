import XCTest
import OrchestraKit
@testable import OrchestraUI
import TestSupport

/// Regression: the board's live-event consumer must survive a redundant `start()`.
///
/// The bug ("UI not updating with cards created by agents / archive / move — needs an app restart"):
/// `start()` bumped `connGeneration` on EVERY call, and the event-consumer Task is stamped with the
/// generation it was born under. A second `start()` on an already-live client — reachable from the
/// offline banner's "Start daemon" button (`ensureDaemonAndStart`) tapped while the link is merely
/// mid-reconnect — orphaned the running consumer (it breaks on the gen mismatch) and then skipped
/// creating a replacement (the `if !streamStarted` guard), while `client.connectAsync()` no-oped
/// (idempotent) so the socket + request/response RPCs stayed perfectly healthy. Net: the daemon keeps
/// pushing events, the app keeps reading them into the AsyncStream, but nothing consumes them — the card
/// list / archive / move / inbox freeze until the app is restarted, even though everything else works.
///
/// This drives a real `ControlClient` over a fake `Transport` (answers the `version` probe → `.live`,
/// errors every other RPC so `refresh()` completes empty, and lets the test push `event` frames), calls
/// `start()` twice, then pushes a `taskUpserted` — the exact wire shape of card 822ebf's `.mcp` move to
/// `review` that Allen saw not render — and asserts the board applied it.
@MainActor
final class EventStreamConsumerTests: XCTestCase {

    /// A controllable in-memory transport: reaches `.live` by answering the `version` probe, resolves
    /// every other request with an error (so `refresh()`'s `boardSnapshot`/`list` calls fail fast and
    /// leave `tasks` untouched), and lets the test inject server→client `event` notification frames.
    final class FakeTransport: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private let sema = DispatchSemaphore(value: 0)
        private var lines: [Data] = []
        private var eof = false

        func open() throws {}

        func write(_ data: Data) -> Bool {
            guard let req = try? RPCCodec.decoder.decode(RPCRequest.self, from: data), let id = req.id else {
                return true   // a notification from the client (none today) — nothing to answer
            }
            let resp: RPCResponse
            if req.method == "version" {
                resp = RPCResponse(id: id, result: .object(["version": .string("fake")]))
            } else if req.method == "subscribe" {
                // The lifecycle-convergence `start()` makes the subscribe RPC a SUCCESS-GATED BARRIER: an
                // error → `forceReconnect()` (not swallowed), which would tear the just-born consumer down
                // and wedge the very live updates this test asserts. A real daemon acks it, so answer it OK.
                resp = RPCResponse(id: id, result: .null)
            } else {
                // Resolve every OTHER call (boardSnapshot, list, …) so no client continuation hangs; an
                // error is fine — `refresh()` swallows it via `try?` and leaves `tasks` untouched.
                resp = RPCResponse(id: id, result: nil, error: RPCError(code: -32000, message: "fake"))
            }
            enqueue((try? RPCCodec.line(resp)) ?? Data())
            return true
        }

        func readLine() -> Data? {
            while true {
                sema.wait()
                let r: Data?? = lock.withLock {
                    if !lines.isEmpty { return .some(lines.removeFirst()) }
                    if eof { return .some(nil) }
                    return nil
                }
                if let r { return r }
            }
        }

        func shutdown() { close() }
        func close() { lock.withLock { eof = true }; sema.signal() }

        private func enqueue(_ d: Data) { lock.withLock { lines.append(d) }; sema.signal() }

        /// Push a server→client `event` notification (the wire shape `ControlServer.handleEvent` emits).
        /// The lifecycle-convergence event wire is rev-tagged: `params` is an `EventEnvelope{rev,event}`
        /// (consumed by `ControlClient.subscribeWithRev()` → BoardStore's per-card rev gate), not a bare
        /// `Event`. A fresh card id applies regardless of rev, so a monotonic rev keeps it un-stale.
        private var pushRev = 0
        func pushEvent(_ event: Event) {
            pushRev += 1
            let note = RPCNotification(method: "event",
                                       params: try? JSONValue(encodable: EventEnvelope(rev: pushRev, event: event)))
            enqueue((try? RPCCodec.line(note)) ?? Data())
        }
    }

    private func movedCard(id: UUID) -> Task {
        Task(id: id, title: "moved card", repo: "/repo", branch: "b", cwd: "/repo",
             origin: .worktree, model: AgentModel(id: "m"), startIn: .plan, column: .review,
             order: 0, initialPrompt: "p")
    }

    /// A single `start()` establishes a live consumer that applies a pushed event.
    func testLiveEventAppliesAfterSingleStart() async throws {
        let fake = FakeTransport()
        let model = BoardModel(platform: .noop)
        model.injectClientForTesting(ControlClient(transport: { fake }, source: .app))
        defer { model.disconnect() }

        await model.start()

        let id = UUID()
        fake.pushEvent(.taskUpserted(movedCard(id: id)))
        try await waitForCard(id, in: model)
        XCTAssertTrue(model.tasks.contains { $0.id == id }, "single-start consumer must apply live events")
    }

    /// The regression: a REDUNDANT `start()` (offline-banner re-entry) must not orphan the consumer.
    /// Before the fix this hangs the board — the pushed `taskUpserted` is never applied — until restart.
    func testRedundantStartKeepsEventConsumerAlive() async throws {
        let fake = FakeTransport()
        let model = BoardModel(platform: .noop)
        model.injectClientForTesting(ControlClient(transport: { fake }, source: .app))
        defer { model.disconnect() }

        await model.start()   // consumer born
        await model.start()   // redundant re-entry — must NOT orphan the consumer

        let id = UUID()   // card 822ebf's `.mcp` move to review, as a server-pushed taskUpserted
        fake.pushEvent(.taskUpserted(movedCard(id: id)))
        try await waitForCard(id, in: model)

        XCTAssertTrue(model.tasks.contains { $0.id == id },
                      "a redundant start() orphaned the event consumer — live board updates were lost until restart")
        XCTAssertTrue(model.cards(in: .review).contains { $0.id == id },
                      "the moved card must land in its new column on the live board")
    }

    /// Poll the board (the consumer applies on the MainActor) until the pushed card is applied.
    private func waitForCard(_ id: UUID, in model: BoardModel) async throws {
        try await pollUntil("the pushed card is applied to the board", timeout: .seconds(30)) {
            await model.tasks.contains { $0.id == id }
        }
    }
}
