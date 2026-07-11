import Foundation
import Testing
@testable import OrchestraCore

/// The acceptance harness for the shell-sync fix: a shell opened on one surface must appear on the
/// other. Two `ControlClient`s ("desktop" + "phone") talk to one in-process `ControlServer` over a
/// throwaway UDS, backed by the in-memory `StubSessions` (whose `windows()` faithfully reflects
/// opens/closes) — exactly the topology that used to diverge. We assert that each open/close broadcasts
/// a `shellsChanged` event whose set reaches the *other* client's subscription and always lists BOTH
/// surfaces' windows.
///
/// DETERMINISM: this test USED to flake in the full suite. The flake was in the test's own timing, not
/// the product logic — it asserted on an ASYNC broadcast immediately after a FIXED `sleep`, so when the
/// parallel suite starved the scheduler the event hadn't been delivered yet and the assertion read stale
/// (or nil) state. The daemon is already the single writer of the broadcast set, so the settled value is
/// never wrong — only late. The fix is to WAIT for the settled broadcast (bounded poll) instead of a
/// wall-clock guess: `waitForShells` returns as soon as the expected set arrives, so no amount of
/// scheduler starvation can make us assert against a not-yet-delivered event. Subscription establishment
/// is likewise made deterministic: the card is spawned BEFORE the phone subscribes, so the spawn's
/// activity is replayed from the ring under the same lock that registers the subscriber — observing it
/// proves the phone is registered and will receive every subsequent live broadcast.
@Suite("Shell sync ⇄ ControlServer — the acceptance harness", .serialized)
struct ShellSyncRoundTripTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    /// The `shells` of the latest `shellsChanged` for `cardId`, or nil if none seen yet.
    private func latestShellWindows(_ events: [Event], _ cardId: UUID) -> [String]? {
        events.compactMap {
            if case .shellsChanged(let s) = $0, s.cardId == cardId { return s.shells.map(\.window) }
            return nil
        }.last
    }

    /// Wait (bounded) until `cardId`'s latest broadcast shell set equals `expected` (order-insensitive:
    /// the invariant is the SET reaching the other surface, not window order). Returns as soon as it
    /// matches; on timeout returns the last-observed value so the caller's `#expect` prints what settled.
    private func waitForShells(_ box: EventBox, _ cardId: UUID, equals expected: [String],
                               within: Duration = .seconds(5)) async throws -> [String]? {
        let want = expected.sorted()
        let deadline = ContinuousClock.now.advanced(by: within)
        while true {
            let latest = latestShellWindows(await box.events, cardId)
            if latest?.sorted() == want || ContinuousClock.now >= deadline { return latest }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
    }

    /// Wait (bounded) until the phone has demonstrably registered its subscription: the pre-subscribe
    /// spawn's activity is replayed from the ring under the same lock that registers the subscriber, so
    /// observing any event for `cardId` proves every subsequent live broadcast will be delivered.
    private func waitForCard(_ box: EventBox, _ cardId: UUID, within: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            let seen = await box.events.contains { e in
                switch e {
                case .activity(let a): return a.taskId == cardId
                case .taskUpserted(let t): return t.id == cardId
                default: return false
                }
            }
            if seen { return }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a shell opened on the desktop reaches the phone's subscription, and vice versa; close reconciles")
    func acceptance() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)

        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        // Two clients: "desktop" and "phone".
        let desktop = ControlClient(socketPath: path, source: .app)
        try desktop.connect(); defer { desktop.close() }
        let phone = ControlClient(socketPath: path, source: .app)
        try phone.connect(); defer { phone.close() }

        // Spawn the card BEFORE the phone subscribes, so the spawn's activity is in the ring and gets
        // replayed to the phone on subscribe — a deterministic registration anchor (see `waitForCard`).
        let task = try await desktop.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("shells"), "repo": .string(repo), "branch": .string("feat")]))
            .decode(Task.self)
        let ref = task.shortId
        // Non-blocking spawn: drive the reconciler to bring the card's session up before opening shells.
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == task.id }?.phase.kind == .live
        }

        // The PHONE subscribes — it must learn about a shell the DESKTOP opens (the reported bug).
        let box = EventBox()
        let stream = phone.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        // Block until the phone's subscription is provably live (ring replay of the spawn activity).
        try await waitForCard(box, task.id)

        // 1) Desktop opens a shell (window omitted → a fresh shell-N).
        let opened = try await desktop.call("shell", .object(["ref": .string(ref)]))
        let shellN = try #require(opened["window"]?.stringValue)

        // The phone's subscription received a shellsChanged listing the desktop's shell.
        _ = try await waitForShells(box, task.id, equals: [shellN])
        #expect(latestShellWindows(await box.events, task.id) == [shellN])

        // 2) Phone opens ITS OWN shell (deterministic phone-<client> window).
        _ = try await phone.call("shell", .object(["ref": .string(ref),
                                                   "window": .string("phone-abc12345")]))
        // Both surfaces' windows are now in the single broadcast set.
        let both = try await waitForShells(box, task.id, equals: [shellN, "phone-abc12345"])
        #expect(both?.sorted() == [shellN, "phone-abc12345"].sorted())

        // 3) Closing the desktop shell reconciles down to just the phone's window on the other surface.
        _ = try await desktop.call("closeShell", .object(["ref": .string(ref),
                                                          "window": .string(shellN)]))
        _ = try await waitForShells(box, task.id, equals: ["phone-abc12345"])
        #expect(latestShellWindows(await box.events, task.id) == ["phone-abc12345"])
    }
}
