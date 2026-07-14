import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit
import TestSupport

@Suite("Spawn idempotency (client-minted ids)")
struct IdempotencyTests {
    // Two spawns with the SAME id create ONE card; the second returns the existing card as-is.
    @Test func test_spawnWithClientIdIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let id = UUID()
        let first  = try await env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        let second = try await env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        #expect(first.id == id); #expect(second.id == id)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
    }

    // A partially-acked batch retried with the same per-item ids creates no duplicates.
    @Test func test_batchSpawnRetryIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let ids = [UUID(), UUID(), UUID()]
        let inputs = ids.enumerated().map { SpawnInput(id: $1, prompt: "p", repo: repo, branch: "b\($0)") }
        _ = await env.svc.batchSpawn(inputs)
        _ = await env.svc.batchSpawn(inputs)          // full retry, same ids
        for id in ids { #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1) }
    }

    // CONCURRENT same-id spawns (the real retry-races-original case) create exactly one card AND
    // emit no duplicate/spurious activity (the loser must not fire the "second live card" warning).
    @Test func test_concurrentSameIdSpawnCreatesOne() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let box = EventBox()
        let stream = await env.svc.subscribe()
        let collector = _Concurrency.Task { for await e in stream { await box.add(e.event) } }
        let id = UUID()
        async let a = env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        async let b = env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        _ = try await (a, b)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
        await yieldBriefly()   // negative: let any wrongful warning's fan-out land before asserting none did
        let warnings = await box.events.filter { if case .activity(let it) = $0 { return it.kind == .warning } else { return false } }
        #expect(warnings.isEmpty, "a same-id retry must not emit a spurious multiplicity warning")
        collector.cancel()
    }

    // The WIRE path (command params carry `id`), not just the service API: two spawn requests with the
    // same `id` param dedup to one card — proving the registry handler reads `id` and dedups.
    @Test func test_spawnParamRetryIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let id = UUID()
        let params = JSONValue.object(["id": .string(id.uuidString), "prompt": .string("p"),
                                       "repo": .string(repo), "branch": .string("b")])
        let reg = CommandRegistry()
        let spawn = try #require(reg.command("spawn"))
        _ = try await spawn.run(env.svc, params, .mcp)   // drive the verb through the registry handler
        _ = try await spawn.run(env.svc, params, .mcp)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
    }
}
