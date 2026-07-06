import Foundation
import Testing
@testable import OrchestraCore

/// The acceptance harness for the shell-sync fix: a shell opened on one surface must appear on the
/// other. Two `ControlClient`s ("desktop" + "phone") talk to one in-process `ControlServer` over a
/// throwaway UDS, backed by a real tmux session — exactly the topology that used to diverge. We
/// assert that each open/close broadcasts a `shellsChanged` event whose set reaches the *other*
/// client's subscription and always lists BOTH surfaces' windows.
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

        // The PHONE subscribes — it must learn about a shell the DESKTOP opens (the reported bug).
        let box = EventBox()
        let stream = phone.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))

        let task = try await desktop.call("spawn", .object([
            "prompt": .string("shells"), "repo": .string(repo), "branch": .string("feat")]))
            .decode(Task.self)
        let ref = task.shortId

        // 1) Desktop opens a shell (window omitted → a fresh shell-N).
        let opened = try await desktop.call("shell", .object(["ref": .string(ref)]))
        let shellN = try #require(opened["window"]?.stringValue)

        // The phone's subscription received a shellsChanged listing the desktop's shell.
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        #expect(await latestShellWindows(box.events, task.id) == [shellN])

        // 2) Phone opens ITS OWN shell (deterministic phone-<client> window).
        _ = try await phone.call("shell", .object(["ref": .string(ref),
                                                   "window": .string("phone-abc12345")]))
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        // Both surfaces' windows are now in the single broadcast set.
        let both = await latestShellWindows(box.events, task.id)
        #expect(both?.sorted() == [shellN, "phone-abc12345"].sorted())

        // 3) Closing the desktop shell reconciles down to just the phone's window on the other surface.
        _ = try await desktop.call("closeShell", .object(["ref": .string(ref),
                                                          "window": .string(shellN)]))
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        #expect(await latestShellWindows(box.events, task.id) == ["phone-abc12345"])
    }
}
