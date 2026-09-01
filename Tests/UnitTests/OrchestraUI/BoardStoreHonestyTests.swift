import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

@Suite @MainActor struct BoardStoreHonestyTests {

    // A failed archive must NOT toast "Archived" (the discarded-branch lie). The store is never start()ed,
    // so its client has no transport → client.call fails fast (write failed) → the honest catch fires a
    // red failure toast, never "Archived". Hermetic: no socket touched.
    @Test func test_archiveFailureToastIsHonest() async {
        let store = BoardStore(platform: .noop)         // un-started → client.call always fails
        await store.archive(UUID())
        #expect(!store.toasts.contains { $0.title == "Archived" })
        #expect(store.toasts.contains { $0.color == .red })     // needs ToastColor: Equatable
    }

    @Test func test_sendReturnsFalseWhenTheDaemonRejectsIt() async {
        let store = BoardStore(platform: .noop)   // un-started → client.call fails fast
        let sent = await store.send(UUID(), "keep this draft")
        #expect(sent == false)
        #expect(store.toasts.contains { $0.title == "Couldn't send message" && $0.color == .red })
    }

    // The in-flight guard makes a second spawn (while one is "in flight") a genuine no-op: it returns nil
    // WITHOUT dispatching (no failure toast) and WITHOUT clearing the flag. Simulate the first spawn being
    // in flight by pre-setting isSpawning; a regression that dropped `guard beginSpawn()` from spawn()
    // would instead run the body, hit the failing client, and produce a red "Spawn failed" toast → fails.
    @Test func test_doubleSpawnGuarded() async {
        let store = BoardStore(platform: .noop)
        store.isSpawning = true                         // a spawn is already in flight
        let second = await store.spawn(prompt: "x", repo: "/r", branch: "b", model: nil, startIn: .plan)
        #expect(second == nil)                          // guarded → no-op
        #expect(store.isSpawning == true)               // early return did NOT run `defer { endSpawn() }`
        #expect(store.toasts.isEmpty)                   // no dispatch attempt → no failure toast

        // And the guard primitive itself:
        store.isSpawning = false
        #expect(store.beginSpawn() == true)
        #expect(store.beginSpawn() == false)            // second acquire while held → refused
        store.endSpawn()
        #expect(store.beginSpawn() == true)
    }

    // PR6a carry-forward: a retry of the SAME attempt reuses its client-minted id (→ idempotent dedup =
    // one card); a fresh attempt mints a new id.
    @Test func test_spawnRetryReusesId() {
        let first = BoardStore.spawnAttemptId(reusing: nil)     // first attempt mints
        let retry = BoardStore.spawnAttemptId(reusing: first)   // retry reuses
        #expect(retry == first)
        let fresh = BoardStore.spawnAttemptId(reusing: nil)     // a new attempt mints fresh
        #expect(fresh != first)
    }
}
