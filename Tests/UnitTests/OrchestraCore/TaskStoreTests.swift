import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("TaskStore — atomic Codable persistence")
struct TaskStoreTests {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "orch-store-\(UUID().uuidString)/tasks.json"
    }

    private func sample(_ title: String = "Fix login", column: Column = .plan) -> Task {
        Task(title: title, repo: "/repos/app", branch: "feature", cwd: "/wt/app/feature",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: column, order: 0, initialPrompt: title)
    }

    @Test("create fills id + timestamps + order and persists")
    func createFillsFields() async throws {
        let store = TaskStore(path: tempPath())
        let t = try await store.create(sample()).task
        #expect(t.order == 0)
        #expect(t.phaseDisplay == .running)
        let t2 = try await store.create(sample("Second")).task
        #expect(t2.order == 1)  // appended after the first in the same column
    }

    @Test("update merges only via the mutation and persists")
    func updateMerges() async throws {
        let store = TaskStore(path: tempPath())
        let t = try await store.create(sample()).task
        let updated = try await store.update(t.id) { $0.phase = .live(.waiting(.humanTurn)); $0.desc = "Editing Foo.swift" }.task
        #expect(updated.waitReason != nil)
        #expect(updated.desc == "Editing Foo.swift")
        #expect(updated.updatedAt >= t.updatedAt)
    }

    @Test("load returns [] when the file is absent")
    func loadEmptyWhenAbsent() async throws {
        let store = TaskStore(path: tempPath())
        let tasks = await store.load()
        #expect(tasks.isEmpty)
    }

    @Test("a saved store round-trips through a fresh store on disk")
    func roundTrips() async throws {
        let path = tempPath()
        let store = TaskStore(path: path)
        let t = try await store.create(sample("Persisted")).task
        // Fresh store, same path → loads the persisted task.
        let store2 = TaskStore(path: path)
        let loaded = await store2.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == t.id)
        #expect(loaded.first?.title == "Persisted")
    }

    @Test("malformed file is moved to a timestamped .corrupt backup, load yields [], and loadWasCorrupt is set")
    func malformedToCorruptBackup() async throws {
        let path = tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = TaskStore(path: path)
        let tasks = await store.load()
        #expect(tasks.isEmpty)
        #expect(await store.wasCorrupt())
        // Timestamped backup (`tasks.json.corrupt-<ISO8601>`), NOT the old fixed `.bak`.
        let base = (path as NSString).lastPathComponent
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasPrefix(base + ".corrupt-") } ?? []
        #expect(backups.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test("a second corruption does NOT clobber the first .corrupt backup")
    func secondCorruptionKeepsBoth() async throws {
        let path = tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let base = (path as NSString).lastPathComponent
        func corruptAndLoad(at date: Date) async {
            try? "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
            _ = await TaskStore(path: path, now: { date }).load()
        }
        let t0 = Date()
        await corruptAndLoad(at: t0)
        await corruptAndLoad(at: t0 + 1)          // a distinct ISO8601 second, by injection not by waiting
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasPrefix(base + ".corrupt-") } ?? []
        #expect(backups.count == 2)   // both preserved
    }

    @Test("atomic save survives concurrent writers without corruption")
    func atomicConcurrent() async throws {
        let store = TaskStore(path: tempPath())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try? await store.create(self.sample("T\(i)")) }
            }
        }
        let all = await store.all()
        #expect(all.count == 20)
    }
}

@Suite("TaskStore — one-time on-disk migration to phase") struct TaskStoreMigrationTests {
    private func tmpPath() -> String { NSTemporaryDirectory() + "orch-mig-\(UUID().uuidString)/tasks.json" }

    private func sample(_ title: String) -> Task {
        Task(title: title, repo: "/repos/app", branch: "feat-\(title)", cwd: "/wt/app/\(title)",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .impl, column: .impl, order: 0,
             initialPrompt: title)
    }

    /// Reshape a Task into a PRE-Stage-2 legacy record: drop the phase-era keys and inject the legacy
    /// `status`/`waitReason`/`deadReason`/`archived` keys exactly as an old tasks.json carried them.
    private func legacyRecord(_ t: Task, status: String, waitReason: String? = nil,
                              deadReason: String? = nil, archived: Bool = false) -> [String: Any] {
        var obj = try! JSONSerialization.jsonObject(
            with: OrchestraJSON.wire.encode(t)) as! [String: Any]
        for k in ["phase", "sessionEpoch", "phaseChangedAt", "status", "waitReason", "deadReason"] {
            obj.removeValue(forKey: k)
        }
        obj["status"] = status
        if let w = waitReason { obj["waitReason"] = w }
        if let d = deadReason { obj["deadReason"] = d }
        obj["archived"] = archived
        return obj
    }

    /// The six-record legacy fixture as an array of JSON objects, one per lifecycle case.
    private func legacyRecords() -> [[String: Any]] {
        [
            legacyRecord(sample("running"), status: "running"),
            legacyRecord(sample("wait-nil"), status: "waiting"),                       // nil waitReason
            legacyRecord(sample("wait-perm"), status: "waiting", waitReason: "permission"),
            legacyRecord(sample("done"), status: "done"),
            legacyRecord(sample("dead"), status: "dead", deadReason: "resumeFailed"),
            legacyRecord(sample("arch"), status: "done", archived: true),
        ]
    }

    private func write(_ json: Any, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func assertMigratedPhases(_ tasks: [Task]) {
        func phase(_ title: String) -> Phase? { tasks.first { $0.title == title }?.phase }
        #expect(tasks.count == 6, "no card dropped")
        #expect(phase("running") == .live(.running))
        #expect(phase("wait-nil") == .live(.waiting(.humanTurn)))         // nil waitReason → humanTurn, never unknown
        #expect(phase("wait-perm") == .live(.waiting(.permission)))
        #expect(phase("done") == .dead(.completed))
        #expect(phase("dead") == .dead(.resumeFailed))                    // dead preserves its reason
        #expect(phase("arch") == .archived(teardownComplete: true))
    }

    @Test("migrates a legacy bare [Task] array — every status → phase, rev 0")
    func test_migratesLegacyTasksJson_bareArray() async throws {
        let path = tmpPath()
        try write(legacyRecords(), to: path)
        let store = TaskStore(path: path)
        let loaded = await store.load()
        assertMigratedPhases(loaded)
        #expect(await store.currentRev == 0)                             // bare array → rev 0 (PR1)
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))  // a legacy board is NOT wiped
    }

    @Test("migrates a legacy {rev,tasks} envelope — phases migrate, rev preserved")
    func test_migratesLegacyTasksJson_envelope() async throws {
        let path = tmpPath()
        try write(["rev": 7, "tasks": legacyRecords()], to: path)
        let store = TaskStore(path: path)
        let loaded = await store.load()
        assertMigratedPhases(loaded)
        #expect(await store.currentRev == 7)                             // envelope rev preserved
        #expect(store.peekPersistedRev() == 7)                           // and the sync peek agrees
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test("a garbage/partial legacy record is kept as a safe terminal, not dropped or .bak'd")
    func test_migratesUnknownLegacyRecordToSafeTerminal() async throws {
        let path = tmpPath()
        // Only `id` + a garbage `status`; every other field absent — best-effort decode must fill defaults.
        let id = UUID()
        try write([["id": id.uuidString, "status": "zombie"]], to: path)
        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 1, "the card is kept, not dropped")
        #expect(loaded.first?.id == id)
        #expect(loaded.first?.phase == .dead(.rebootUnrevived))          // unknown status → safe terminal
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))  // one bad record never wipes the board
    }

    @Test("an id-less record drops just itself; the rest of the board loads, no .bak, rev preserved")
    func test_idlessRecordDroppedNotBakked() async throws {
        let path = tmpPath()
        // A {rev,tasks} board: 2 good records + 1 record with NO id (the only true drop case).
        let good1 = try! JSONSerialization.jsonObject(with: OrchestraJSON.wire.encode(sample("keep-1"))) as! [String: Any]
        let good2 = try! JSONSerialization.jsonObject(with: OrchestraJSON.wire.encode(sample("keep-2"))) as! [String: Any]
        var idless = try! JSONSerialization.jsonObject(with: OrchestraJSON.wire.encode(sample("dropme"))) as! [String: Any]
        idless.removeValue(forKey: "id")
        try write(["rev": 5, "tasks": [good1, idless, good2]], to: path)

        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 2, "only the id-less record drops")
        #expect(Set(loaded.map(\.title)) == ["keep-1", "keep-2"])
        #expect(await store.currentRev == 5)                             // envelope rev preserved
        #expect(store.peekPersistedRev() == 5)
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))  // record-level corruption never .bak's the board
    }

    @Test("a present-but-garbage enum field defaults rather than dropping the record")
    func test_garbageEnumFieldDefaultsNotDropped() async throws {
        let path = tmpPath()
        // Valid id, but garbage `origin` and `deadReason` rawValues — must default, not throw/drop.
        var rec = try! JSONSerialization.jsonObject(with: OrchestraJSON.wire.encode(sample("garbage-fields"))) as! [String: Any]
        rec["origin"] = "not-a-real-origin"
        rec["deadReason"] = "not-a-real-reason"
        rec["column"] = "not-a-real-column"
        try write(["rev": 3, "tasks": [rec]], to: path)

        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 1, "the record is kept, not dropped")
        #expect(loaded.first?.title == "garbage-fields")
        #expect(loaded.first?.origin == .worktree)                       // garbage origin → safe default
        #expect(loaded.first?.deadReason == nil)                         // garbage deadReason → nil
        #expect(loaded.first?.column == .impl)                           // garbage column → safe default
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test("stampMarkers makes pre-upgrade worktree dirs adoptable — clean AND dirty, byte-intact")
    func test_migrationStampsMarkers() async throws {
        let (reg, stub, _) = makeRegistry()                 // reuse the WorktreeRegistryTests helper
        let clean = stub.path(repo: "app", branch: "old/clean")
        let dirty = stub.path(repo: "app", branch: "old/dirty")
        for p in [clean, dirty] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        try "keep".write(toFile: dirty + "/uncommitted.txt", atomically: true, encoding: .utf8)
        stub.setDirty(dirty, true)

        await reg.stampMarkers(forMigratedPaths: [clean, dirty])

        let a = try await reg.ensure(repo: "app", branch: "old/clean", cardId: UUID())
        let b = try await reg.ensure(repo: "app", branch: "old/dirty", cardId: UUID())
        #expect(!a.created && !b.created)                             // adopted, not recreated
        #expect(stub.removed.isEmpty)                                // nothing removed
        #expect(FileManager.default.fileExists(atPath: dirty + "/uncommitted.txt"))   // byte-intact
        #expect(try String(contentsOfFile: dirty + "/uncommitted.txt", encoding: .utf8) == "keep")

        // ONE-TIME sentinel: a SECOND `stampMarkers` call (post-migration) must NOT stamp a newly
        // appeared marker-less dir — that would (once Stage 4's non-blocking spawn lands) risk marking a
        // half-created checkout adoptable. A dir added after the sentinel was dropped above stays
        // marker-less, so `ensure` prunes + recreates it (created==true) — it is never silently adopted.
        let late = stub.path(repo: "app", branch: "old/late")
        try FileManager.default.createDirectory(atPath: late, withIntermediateDirectories: true)
        stub.setDirty(late, false)
        await reg.stampMarkers(forMigratedPaths: [late])   // no-op: sentinel already dropped
        let c = try await reg.ensure(repo: "app", branch: "old/late", cardId: UUID())
        #expect(c.created)   // pruned + recreated — never adopted as pre-existing
    }
}

@Suite("TaskStore rev") struct TaskStoreRevTests {
    private func sample(_ title: String = "a", column: Column = .plan) -> Task {
        Task(title: title, repo: "/repos/app", branch: "b", cwd: "/wt/app/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: column, order: 0,
             initialPrompt: title)
    }
    private func tmpPath() -> String { NSTemporaryDirectory() + "orch-rev-\(UUID().uuidString)/tasks.json" }

    @Test("every mutation bumps rev monotonically; no two mutations share a rev")
    func test_everyMutationBumpsRev() async throws {
        let store = TaskStore(path: tmpPath())
        var seen: [Int] = []
        let t = try await store.create(sample()).task
        seen.append(await store.currentRev)
        _ = try await store.update(t.id) { $0.desc = "b" }
        seen.append(await store.currentRev)
        _ = try await store.move(t.id, to: .impl)
        seen.append(await store.currentRev)
        try await store.remove(t.id)
        seen.append(await store.currentRev)
        #expect(seen == seen.sorted())            // strictly increasing (monotonic)
        #expect(Set(seen).count == seen.count)    // unique — no two mutations share a rev
        #expect(seen.first! >= 1)
    }

    @Test("a no-op update does not bump rev")
    func test_noOpUpdateDoesNotBumpRev() async throws {
        let store = TaskStore(path: tmpPath())
        let t = try await store.create(sample()).task
        let revAfterCreate = await store.currentRev

        // No-op closure: leaves the task byte-for-byte identical.
        let (unchanged, revAfterNoOp) = try await store.update(t.id) { _ in }
        #expect(revAfterNoOp == revAfterCreate)
        #expect(await store.currentRev == revAfterCreate)
        #expect(unchanged == t)

        // Setting a field to its current value is also a no-op.
        let (stillUnchanged, revAfterNoOp2) = try await store.update(t.id) { $0.desc = t.desc }
        #expect(revAfterNoOp2 == revAfterCreate)
        #expect(await store.currentRev == revAfterCreate)
        #expect(stillUnchanged == t)

        // A real change still bumps rev.
        let (changed, revAfterRealChange) = try await store.update(t.id) { $0.desc = "actually different" }
        #expect(revAfterRealChange == revAfterCreate + 1)
        #expect(await store.currentRev == revAfterCreate + 1)
        #expect(changed.desc == "actually different")
    }

    @Test("a pre-upgrade bare-array tasks.json reads back rev = 0")
    func test_preUpgradeBareArrayDefaultsRevZero() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let legacy = try OrchestraJSON.pretty.encode([sample("old")])   // legacy = top-level array, no {rev,tasks}
        try legacy.write(to: URL(fileURLWithPath: path))
        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(await store.currentRev == 0)
    }

    // MARK: - Telemetry-persist debounce (bug #13). rev/memory/emit stay SYNCHRONOUS; only the file write coalesces.
    //
    // Every test below sets the debounce/max-deferral windows to an hour. That is NOT a "generous timeout" —
    // it is a SENTINEL meaning "this timer must not fire during the test", and the test then forces the write
    // with `flushPendingWrites()`. None of these tests asserts that the timer eventually fires on its own; they
    // assert COALESCING and ABSORPTION semantics, which have nothing to do with the window's length.
    //
    // The window used to be 10s here, which is a sentinel only if the test finishes in under 10s. Under
    // `--parallel` starvation the 20-delta loop took longer than that, the debounce fired, a real disk write
    // landed, and `diskWriteCount == base` failed — reading like a debounce bug when the store behaved
    // perfectly. An hour is a window the test cannot outlive, so what is under test is the behavior, not the
    // machine's speed.

    @Test("telemetry writes debounce: rev advances synchronously per delta, but the burst coalesces to one disk write")
    func test_telemetryPersistDebounced() async throws {
        let store = TaskStore(path: tmpPath())
        let created = try await store.create(sample()).task          // one immediate write
        await store.setPersistDebounce(.seconds(3600)); await store.setMaxDeferral(.seconds(3600))
        let base = await store.diskWriteCount
        var lastRev = await store.currentRev
        for pct in 1...20 {                                          // 20 rapid telemetry deltas
            let (_, rev) = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = Double(pct) }
            #expect(rev > lastRev); lastRev = rev                    // rev advances synchronously per real change
        }
        #expect(await store.diskWriteCount == base)                 // debounced: no write yet
        #expect(await store.get(created.id)?.ctxPct == 20)          // memory current despite deferred write
        await store.flushPendingWrites()
        #expect(await store.diskWriteCount == base + 1)             // burst coalesced to ONE write
    }

    @Test("debounce AND max-deferral run on the injected clock — advance, don't wait")
    func test_debounceAndCapOnTestClock() async throws {
        let clock = TestClock()
        let store = TaskStore(path: tmpPath(), clock: clock)
        let created = try await store.create(sample()).task            // one immediate write
        let base = await store.diskWriteCount

        // Debounce path: one deferred delta; jump past the quiet period → exactly one write.
        await store.setPersistDebounce(.milliseconds(500)); await store.setMaxDeferral(.seconds(2))
        _ = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = 1 }
        await clock.parked(2)                                          // debounce + cap sleepers both armed
        clock.advance(by: .milliseconds(500))
        try await pollUntil("debounce flush") { await store.diskWriteCount == base + 1 }

        // Cap path: debounce set beyond reach, so ONLY the max-deferral checkpoint can flush.
        // The wall-clock version of this suite could never exercise the cap deterministically.
        await store.setPersistDebounce(.seconds(3600))
        _ = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = 2 }
        await clock.parked(2)
        clock.advance(by: .seconds(2))
        try await pollUntil("max-deferral checkpoint") { await store.diskWriteCount == base + 2 }
    }

    @Test("an immediate mutation force-flushes the pending telemetry write (one write carries both)")
    func test_immediateMutationFlushesPendingTelemetry() async throws {
        let path = tmpPath()
        let store = TaskStore(path: path)
        let created = try await store.create(sample()).task
        await store.setPersistDebounce(.seconds(3600)); await store.setMaxDeferral(.seconds(3600))
        _ = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = 5 }
        let c0 = await store.diskWriteCount
        _ = try await store.move(created.id, to: .impl)             // immediate → absorbs the pending delta
        #expect(await store.diskWriteCount == c0 + 1)              // exactly one write, not two
        // A fresh store over the same path sees BOTH the telemetry delta AND the move.
        let reloaded = TaskStore(path: path)
        let onDisk = await reloaded.load().first { $0.id == created.id }
        #expect(onDisk?.ctxPct == 5)
        #expect(onDisk?.column == .impl)
    }

    @Test("reload before a flush sees the LAST FLUSHED rev, not the debounced-but-unwritten one")
    func test_reloadBeforeFlushSeesLastFlushedRev() async throws {
        let path = tmpPath()
        let store = TaskStore(path: path)
        _ = try await store.create(sample()).task                  // immediate write; on-disk rev == this
        let flushedRev = await store.currentRev
        await store.setPersistDebounce(.seconds(3600)); await store.setMaxDeferral(.seconds(3600))
        let (_, bumpedRev) = try await store.update(await store.all().first!.id, debounceFlush: true) { $0.ctxPct = 9 }
        #expect(bumpedRev == flushedRev + 1)                       // in-memory rev advanced synchronously
        // A fresh store (crash before flush) restores the last FLUSHED rev, below the in-memory rev.
        let reloaded = TaskStore(path: path)
        _ = await reloaded.load()
        #expect(await reloaded.currentRev == flushedRev)
    }

    @Test("reload after flushPendingWrites() sees the current rev AND the delta on disk")
    func test_reloadAfterFlushSeesCurrentRev() async throws {
        let path = tmpPath()
        let store = TaskStore(path: path)
        let created = try await store.create(sample()).task
        await store.setPersistDebounce(.seconds(3600)); await store.setMaxDeferral(.seconds(3600))
        let (_, bumpedRev) = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = 11 }
        await store.flushPendingWrites()
        let reloaded = TaskStore(path: path)
        let onDisk = await reloaded.load().first { $0.id == created.id }
        #expect(await reloaded.currentRev == bumpedRev)
        #expect(onDisk?.ctxPct == 11)
    }

    @Test("a no-op debounced update advances neither rev nor schedules a flush")
    func test_noOpUpdateDoesNotAdvanceRev() async throws {
        let store = TaskStore(path: tmpPath())
        let created = try await store.create(sample()).task
        await store.setPersistDebounce(.seconds(3600)); await store.setMaxDeferral(.seconds(3600))
        let revBefore = await store.currentRev
        let writesBefore = await store.diskWriteCount
        let (unchanged, rev) = try await store.update(created.id, debounceFlush: true) { $0.ctxPct = created.ctxPct }
        #expect(rev == revBefore)                                  // no-op: rev unchanged
        #expect(unchanged == created)
        #expect(await store.currentRev == revBefore)
        // No pending flush was scheduled — a flush now writes nothing.
        await store.flushPendingWrites()
        #expect(await store.diskWriteCount == writesBefore)
    }

    @Test("OrchestraService.flushBeforeShutdown() forwards to the store — a debounced delta lands on disk")
    func test_flushBeforeShutdownPersists() async throws {
        let env = TestEnv.make()
        await env.svc.store.setPersistDebounce(.seconds(3600)); await env.svc.store.setMaxDeferral(.seconds(3600))
        let created = try await env.svc.store.create(sample()).task
        _ = try await env.svc.store.update(created.id, debounceFlush: true) { $0.ctxPct = 7 }
        // Not yet on disk (debounced).
        let peek = TaskStore(path: env.base + "/tasks.json")
        #expect(await peek.load().first { $0.id == created.id }?.ctxPct != 7)
        await env.svc.flushBeforeShutdown()                        // the SIGTERM path
        let peek2 = TaskStore(path: env.base + "/tasks.json")
        #expect(await peek2.load().first { $0.id == created.id }?.ctxPct == 7)
    }
}
