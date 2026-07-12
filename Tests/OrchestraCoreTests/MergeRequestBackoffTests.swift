import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

/// O2 backoff + give-up cap. The re-nudge loop used to re-prod the parent every 300s FOREVER; it now
/// backs off geometrically and gives up after `mergeRequestNudgeCap` unanswered reminders, flipping the
/// child to the terminal `mergeStalled` badge so a human can see the stuck merge-request.
/// Design: `notes/designs/2026-07-11-merge-request-nudge-backoff.md`.
@Suite("merge-request re-nudge — model")
struct MergeRequestBackoffModelTests {

    @Test("a TreeStat persisted before this change decodes with nudges == 0")
    func legacyTreeStatDecodesWithZeroNudges() throws {
        let legacy = #"{"state":"mergeRequested","behind":0,"parentIsRemote":false}"#
        let ts = try JSONDecoder().decode(TreeStat.self, from: Data(legacy.utf8))
        #expect(ts.state == .mergeRequested)
        #expect(ts.nudges == 0)
        #expect(!ts.mergeStalled)
    }

    @Test("nudges round-trips through Codable")
    func nudgesRoundTrips() throws {
        let ts = TreeStat(state: .mergeRequested, nudges: 8)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.nudges == 8)
    }

    /// BLOCKER (review): a new TreeState rawValue on disk is fatal to an OLDER binary — `Task` decodes
    /// `treeStat` with `decodeIfPresent`, which rethrows a nested decode failure, and `TaskStore`'s
    /// `FailableTask` turns a throwing record into a DROPPED card. Giving up therefore rides on a Bool
    /// FLAG, never an enum case: an unknown *key* is ignored by an older decoder; an unknown *rawValue*
    /// costs the whole card (orphaned worktree, untracked session, no backup).
    @Test("a card carrying an unknown future TreeState survives — it loses the badge, not the record")
    func unknownTreeStateDoesNotDropTheCard() throws {
        let future = #"{"state":"someFutureState","behind":3,"parentIsRemote":false}"#
        let ts = try JSONDecoder().decode(TreeStat.self, from: Data(future.utf8))
        #expect(ts.state == .inSync)     // defaulted, not thrown
        #expect(ts.behind == 3)
    }

    @Test("mergeStalled round-trips as a flag alongside a live tracking state")
    func stalledFlagRidesAlongsideState() throws {
        let ts = TreeStat(state: .stale, behind: 30, nudges: 8, mergeStalled: true)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.mergeStalled)
        #expect(back.state == .stale)    // the card is STILL tracking its parent while stalled
        #expect(back.behind == 30)
    }
}

@Suite("merge-request re-nudge — backoff schedule")
struct NudgeDelayTests {
    private let base = Duration.seconds(300)

    @Test("the delay doubles from the base until it hits the 12x ceiling")
    func doublesThenCeilings() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 0) == .seconds(300))   // 1x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 1) == .seconds(600))   // 2x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 2) == .seconds(1200))  // 4x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 3) == .seconds(2400))  // 8x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 4) == .seconds(3600))  // 12x ceiling
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 5) == .seconds(3600))  // held
    }

    @Test("the ceiling is relative to the base, so an injected fast base stays fast")
    func ceilingIsBaseRelative() {
        let fast = Duration.milliseconds(20)
        #expect(OrchestraService.nudgeDelay(base: fast, attempt: 9) == .milliseconds(240))  // 12 x 20ms
    }

    @Test("a corrupt or absurd persisted count neither traps nor sleeps forever")
    func absurdAttemptIsClamped() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: Int.max) == .seconds(3600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: -5) == .seconds(300))
    }
}

/// The loop itself: it backs off, it counts, and it GIVES UP — instead of re-prodding the parent every
/// 300s until the heat death of the universe. A parent that ignored 8 reminders will not act on the 9th.
@Suite("merge-request re-nudge — give-up cap")
struct MergeRequestCapTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    /// Poll until `check` holds — the loop ticks on its own schedule, so there is nothing to await on.
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("after the cap the loop gives up: the child goes mergeStalled, the timer stops, a warning fires")
    func capFiresAndStalls() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        // Subscribe BEFORE arming: activity items are ephemeral events, not stored state, so a collector
        // started after the flip would miss the warning entirely.
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(3)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(try await eventually { await treeStat(env.svc, child.id)?.mergeStalled == true })

        // Exactly 1 original request + exactly 3 reminders. The cap is a hard stop, not a slower drip.
        let msgs = try await env.svc.inboxPeek(parentCard.id).map(\.text)
        #expect(msgs.filter { $0.contains("reminder") }.count == 3)
        #expect(msgs.filter { $0.hasPrefix("merge-request:") }.count == 1)
        #expect(await treeStat(env.svc, child.id)?.nudges == 3)

        #expect(try await eventually { await env.svc.mergeRequestNudgeActive(child.id) == false })
        try await _Concurrency.Task.sleep(for: .milliseconds(60))   // let the ephemeral event land
        let warns = await collector.activities.filter {
            $0.kind == .warning && $0.text.contains("merge-request stalled")
        }
        #expect(warns.count == 1)   // fires ONCE, on the flip

        // ...and the CHILD — the card that is actually blocked — is told durably, so its agent learns the
        // request died even if no human was watching the feed at that instant (review m4).
        let childMsgs = try await env.svc.inboxPeek(child.id).map(\.text)
        #expect(childMsgs.contains { $0.contains("merge-request stalled") })

        // Terminal: it stays stalled, and stays silent.
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(await treeStat(env.svc, child.id)?.mergeStalled == true)
        let after = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }.count
        #expect(after == 3)
    }

    @Test("the backoff resumes across a daemon restart — the count comes from the store, not the Task")
    func backoffResumesAcrossRestart() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)          // the daemon dies mid-budget

        // 2 of the 3 reminders were already sent before the crash — persisted on the card.
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 2 }

        let svcB = TestEnv.remake(base: env.base)              // restart over the SAME on-disk store
        await svcB.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await svcB.svc.setMergeRequestNudgeCap(3)
        await svcB.svc.rebuildMergeRequestNudges()

        #expect(try await eventually { await treeStat(svcB.svc, child.id)?.mergeStalled == true })
        // The restart did NOT reset the budget: exactly ONE more reminder was owed, not three.
        let reminders = try await svcB.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }
        #expect(reminders.count == 1)
        #expect(await treeStat(svcB.svc, child.id)?.nudges == 3)
    }

    @Test("a fresh merge-request on a stalled child resets the budget and re-arms the loop")
    func reSendResetsTheBudget() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(2)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(try await eventually { await treeStat(env.svc, child.id)?.mergeStalled == true })

        // The human re-sends. A stalled child is NOT deduped (`alreadyPending` tests `.mergeRequested`), so
        // the request is re-enqueued, the parent re-woken, and the whole budget re-armed from zero.
        // Slow the loop RIGHT down first: with the 20ms interval still set, the re-armed loop could tick
        // before we read the card and we'd see nudges=1 — a pass/fail decided by scheduler luck (review m2).
        await env.svc.setMergeRequestNudgeInterval(.seconds(300))
        await env.svc.setMergeRequestNudgeCap(99)   // keep it pending so the reset is observable
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(await treeStat(env.svc, child.id)?.state == .mergeRequested)
        #expect(await treeStat(env.svc, child.id)?.nudges == 0)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)
        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.hasPrefix("merge-request:") }
        #expect(requests.count == 2)   // the original + the re-send
    }
}

/// Review findings (Codex, 2026-07-11). Two ways the cap could be defeated in practice.
@Suite("merge-request re-nudge — the cap cannot be defeated")
struct MergeRequestCapIntegrityTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    /// Poll until `check` holds — the loop ticks on its own schedule, so there is nothing to await on.
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func armedChild(_ env: (svc: OrchestraService, base: String),
                            _ repo: String, _ parentTip: String) async throws -> (Task, Task) {
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        return (parentCard, child)
    }

    /// MAJOR: `mergeRequest` overwrote the whole TreeStat, zeroing `nudges`. A child that re-sends while
    /// ALREADY pending (the dedup path — it doesn't even re-enqueue) would silently re-arm the full budget,
    /// so a card that re-sends periodically could never reach `mergeStalled`. The give-up cap would be
    /// unreachable in exactly the case it exists for.
    @Test("a re-send while already pending preserves the reminder budget (it does not re-arm it)")
    func reSendWhilePendingPreservesBudget() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parentCard, child) = try await armedChild((env.svc, env.base), repo, parentTip)

        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)                     // freeze the loop; drive by hand
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 7 }   // 7 reminders burned

        _ = try await env.svc.mergeRequest(ref: child.ref())              // re-send while still pending
        await env.svc.stopMergeRequestNudge(child.id)

        #expect(await treeStat(env.svc, child.id)?.nudges == 7)           // budget preserved, not reset
        #expect(await treeStat(env.svc, child.id)?.state == .mergeRequested)
        // The dedup path holds: no second t=0 request was enqueued.
        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.hasPrefix("merge-request:") }
        #expect(requests.count == 1)
    }

    /// MAJOR: no generation fence. A re-arm cancels loop A and installs B — but cancelling A does not abort
    /// its in-flight tick, so A finishes, exits, and its terminal cleanup unconditionally nils the slot,
    /// UNTRACKING the live B. B then survives `stop`/archive and double-nudges alongside a later C.
    /// `startRemoteWatch` already fences exactly this with `remoteWatchGen`; the nudge loop never did.
    @Test("a superseded loop's terminal cleanup cannot untrack the loop that replaced it")
    func staleCleanupCannotUntrackTheLiveLoop() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await armedChild((env.svc, env.base), repo, parentTip)

        await env.svc.startMergeRequestNudge(childId: child.id)          // loop A
        let genA = await env.svc.mergeRequestNudgeGeneration(child.id)
        await env.svc.startMergeRequestNudge(childId: child.id)          // re-arm: A cancelled, B installed
        #expect(await env.svc.mergeRequestNudgeGeneration(child.id) != genA)

        // A's terminal cleanup lands LATE, after B is installed. It must no-op, not evict B.
        await env.svc.clearMergeRequestNudge(child.id, gen: genA)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)  // B is still tracked → still cancellable

        await env.svc.stopMergeRequestNudge(child.id)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == false)
    }

    /// MAJOR (review): the give-up write was gated on STATE, not on the count it observed — so it was not a
    /// compare-and-swap. A tick suspends across `inbox.enqueue` AND `wake` (real session I/O, a ms-wide
    /// window). If the card is synced + a FRESH merge-request armed in that window, the new request is also
    /// `.mergeRequested`, so a state-only guard accepts the stale write: nudges 7→8 ≥ cap flips a
    /// brand-new request straight to stalled — terminal on arrival, with a warning about 8 reminders it
    /// never received. The CAS (`nudges == sent - 1`) makes the write valid only for the request it nudged.
    @Test("a stale tick cannot flip a freshly re-armed merge-request to stalled")
    func staleTickCannotKillAFreshRequest() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await armedChild((env.svc, env.base), repo, parentTip)
        await env.svc.setMergeRequestNudgeCap(8)

        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 7 }   // one reminder from the cap
        let genOld = await env.svc.mergeRequestNudgeGeneration(child.id)

        // The world moves under the in-flight tick: the request is resolved, then a NEW one is sent.
        _ = try await env.svc.synced(ref: child.ref())
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        #expect(await treeStat(env.svc, child.id)?.nudges == 0)     // fresh budget

        // The old tick lands late. Even if its generation were somehow current, the CAS must reject it:
        // it was computed against nudges=7, and the card now says 0.
        _ = await env.svc.reNudgeMergeRequest(child.id, gen: genOld)

        let ts = await treeStat(env.svc, child.id)
        #expect(ts?.mergeStalled == false)         // the fresh request is NOT dead on arrival
        #expect(ts?.state == .mergeRequested)      // it is still waiting, as it should be
        #expect(ts?.nudges == 0)                   // and its budget was not stolen by the ghost
    }

    /// MAJOR (fix-verification round): the give-up write is reachable from the ALREADY-EXHAUSTED path (a cap
    /// lowered under us, or `cap <= 0`), which skips the reminder entirely. That path was guarded on state
    /// only — no CAS — so a stale tick that read an exhausted budget could stamp a request that had since
    /// been resolved and freshly re-armed. Terminal on arrival.
    @Test("a stale tick on an exhausted budget cannot stamp a freshly re-armed request")
    func exhaustedPathStaleTickCannotStampAFreshRequest() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await armedChild((env.svc, env.base), repo, parentTip)

        await env.svc.setMergeRequestNudgeCap(2)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 5 }   // budget already blown
        let genOld = await env.svc.mergeRequestNudgeGeneration(child.id)

        // The world moves: the request is resolved, then a NEW one is sent (fresh budget, nudges = 0).
        _ = try await env.svc.synced(ref: child.ref())
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)

        // The exhausted-budget tick lands late. Its CAS was computed against nudges=5; the card says 0.
        _ = await env.svc.reNudgeMergeRequest(child.id, gen: genOld)

        let ts = await treeStat(env.svc, child.id)
        #expect(ts?.mergeStalled == false)         // the fresh request is NOT dead on arrival
        #expect(ts?.state == .mergeRequested)
        #expect(ts?.nudges == 0)
    }

    /// MAJOR (fix-verification round): the give-up used to persist `state = .inSync` as a PLACEHOLDER and
    /// recompute only after the notification awaits. A crash in that window left the card falsely in-sync on
    /// disk — and boot rebuilds only the nudge timers, it does not eagerly recompute tree stats, so the lie
    /// could outlive the crash indefinitely (no ↓N, no stale badge, no merge-down nudge). The give-up now
    /// computes the TRUE state first and writes count + flag + state in ONE update: no placeholder is ever
    /// persisted, so there is no window in which a crash can freeze a lie.
    @Test("the give-up persists the card's TRUE tree state atomically — never a placeholder")
    func giveUpWritesTheTrueStateAtomically() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (_, child) = try await armedChild((env.svc, env.base), repo, parentTip)

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(1)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        // The parent moves ahead WHILE the request is pending — so the card's true state at give-up is
        // `.stale`, not `.inSync`. A placeholder write would record the wrong one.
        try TreeStatTests.advanceParent(repo, 2)

        #expect(try await eventually { await treeStat(env.svc, child.id)?.mergeStalled == true })

        let ts = await treeStat(env.svc, child.id)
        #expect(ts?.state == .stale)     // the TRUE state, written with the flag — not an .inSync placeholder
        #expect((ts?.behind ?? 0) >= 1)  // ...with a real ↓N. (Not pinned to 2: the loop may give up after
                                         // the first of the parent's commits — the point is it is not frozen.)
        #expect(ts?.nudges == 1)
    }

    /// The other half of the same race: a ghost tick from the cancelled loop must not enqueue a reminder
    /// (nor bump the count) after a re-arm has superseded it — otherwise two loops double-nudge the parent.
    @Test("a superseded loop's in-flight tick sends no reminder")
    func staleTickSendsNoReminder() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let (parentCard, child) = try await armedChild((env.svc, env.base), repo, parentTip)

        _ = try await env.svc.mergeRequest(ref: child.ref())
        let genA = await env.svc.mergeRequestNudgeGeneration(child.id)
        await env.svc.startMergeRequestNudge(childId: child.id)          // supersede A
        await env.svc.stopMergeRequestNudge(child.id)                    // quiet the live loop
        let before = try await env.svc.inboxPeek(parentCard.id).count

        // A's tick, arriving after it was superseded: it owns a stale generation, so it must stop, not nudge.
        let stop = await env.svc.reNudgeMergeRequest(child.id, gen: genA)
        #expect(stop)
        #expect(try await env.svc.inboxPeek(parentCard.id).count == before)   // no ghost reminder
        #expect(await treeStat(env.svc, child.id)?.nudges == 0)               // no ghost count bump
    }
}

/// The give-up badge is only useful if it STAYS. The tree-stat funnel recomputes `treeStat` on every
/// parent movement, so `mergeStalled` must be sticky against it exactly as `mergeRequested` is — and must
/// be cleared by the same verbs, or the card would wear a red badge forever after the merge finally lands.
@Suite("merge-request re-nudge — the stalled flag survives, and still tracks")
struct MergeStalledStickinessTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }
    private func stalled(_ svc: OrchestraService, _ id: UUID) async -> Bool {
        await treeStat(svc, id)?.mergeStalled == true
    }

    /// A child whose merge-request was given up on. Forced straight to the flagged state — the loop's own
    /// path there is covered by `MergeRequestCapTests`; this suite is about what the REST of the system does
    /// to the flag once it exists.
    private func stalledChild(_ svc: OrchestraService, _ repo: String, _ parentTip: String) async throws -> Task {
        let child = try await TestEnv.spawnAndAwaitLive(
            svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await svc.mergeRequest(ref: child.ref())
        await svc.stopMergeRequestNudge(child.id)
        _ = try await svc.store.update(child.id) {
            $0.treeStat = TreeStat(state: .inSync, nudges: 8, mergeStalled: true)
        }
        return child
    }

    @Test("a tree-stat recompute does not clobber the stalled flag")
    func recomputeKeepsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        await env.svc.recomputeTreeStat(child.id)
        #expect(await stalled(env.svc, child.id))
        #expect(await treeStat(env.svc, child.id)?.nudges == 8)   // the budget rides across too
    }

    /// MAJOR (review): as an overloaded tree STATE, giving up also froze the recompute funnel — a stalled
    /// child stopped getting `behind` updates and, worse, stopped getting the "parent moved ahead — merge it
    /// down" inbox nudge. It would rot for days against a parent it was never told had advanced, and meet the
    /// drift as conflicts at merge time. As a FLAG, `state` keeps tracking underneath it.
    @Test("a stalled card still tracks its parent: it goes stale, and is still told to merge down")
    func stalledCardStillTracksItsParent() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        try TreeStatTests.advanceParent(repo, 3)          // the parent lands 3 commits while we're stalled
        await env.svc.recomputeTreeStat(child.id)

        let ts = await treeStat(env.svc, child.id)
        #expect(ts?.mergeStalled == true)                // still visibly given-up-on...
        #expect(ts?.state == .stale)                     // ...AND still tracking
        #expect(ts?.behind == 3)                         // ↓N is live, not frozen at the give-up moment
        // The stale nudge still reaches the child — it is not blind to the parent it will have to merge.
        let msgs = try await env.svc.inboxPeek(child.id).map(\.text)
        #expect(msgs.contains { $0.contains("moved ahead") })
    }

    /// "A restart cannot resurrect the spam" — the whole point of giving up. `rebuildMergeRequestNudges()`
    /// re-arms only `.mergeRequested` cards, and a given-up card no longer holds that state.
    @Test("a daemon restart does not re-arm the loop for a stalled card")
    func restartDoesNotResurrectAStalledLoop() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)
        let before = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }.count

        let svcB = TestEnv.remake(base: env.base)        // restart over the SAME on-disk store
        await svcB.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await svcB.svc.rebuildMergeRequestNudges()
        #expect(await svcB.svc.mergeRequestNudgeActive(child.id) == false)   // no loop re-armed

        try await _Concurrency.Task.sleep(for: .milliseconds(120))           // well past several intervals
        let after = try await svcB.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }.count
        #expect(after == before)                                             // and the parent stays unspammed
        #expect(await stalled(svcB.svc, child.id))                           // the flag survived the restart
    }

    @Test("synced clears the stalled badge (the merge finally happened)")
    func syncedClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        _ = try await env.svc.synced(ref: child.ref())
        #expect(await stalled(env.svc, child.id) == false)
    }

    /// The badge is sticky against the recompute funnel, so every terminal verb must clear it EXPLICITLY —
    /// otherwise a card whose merge finally landed wears the red "unanswered" badge forever.
    @Test("shipped clears the stalled badge")
    func shippedClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        try TreeStatTests.advanceParent(repo, 1)          // simulate the merge (the S2-2 gate)
        _ = try await env.svc.shipped(ref: child.ref())
        #expect(await stalled(env.svc, child.id) == false)
    }

    @Test("set-parent clears the stalled badge (the child was re-pointed elsewhere)")
    func setParentClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env.svc, repo, parentTip)

        _ = try await env.svc.setParent(ref: child.ref(), parent: "main", mode: "move")
        #expect(await stalled(env.svc, child.id) == false)
    }
}
