import XCTest
import OrchestraKit

/// The provider-neutral push core (N1): the attention transition→intent mapping (incl. fresh-card and
/// background-wait suppression), the scope gating (daemon `shouldSend` + client `shouldPresent`), and the
/// APNs payload shape. Pure logic — no daemon, no APNs, no Simulator.
final class PushCoreTests: XCTestCase {

    private func card(_ title: String = "card",
                      id: UUID = UUID(),
                      status: AgentStatus,
                      wait: WaitReason? = nil,
                      dead: DeadReason? = nil,
                      archived: Bool = false) -> Task {
        Task(id: id, title: title, repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
             status: status, deadReason: dead, waitReason: wait, ctxPct: 0,
             initialPrompt: title, archived: archived)
    }

    // MARK: transition → trigger

    func testTransitionsMapToTriggers() {
        // running → waiting(permission) fires permission
        XCTAssertEqual(AttentionTransition.trigger(prev: .running,
            task: card(status: .waiting, wait: .permission)), .permission)
        // running → waiting(humanTurn) fires needsYou
        XCTAssertEqual(AttentionTransition.trigger(prev: .running,
            task: card(status: .waiting, wait: .humanTurn)), .needsYou)
        // any → dead fires died
        XCTAssertEqual(AttentionTransition.trigger(prev: .running,
            task: card(status: .dead, dead: .agentExited)), .died)
        XCTAssertEqual(AttentionTransition.trigger(prev: .waiting,
            task: card(status: .dead, dead: .sessionVanished)), .died)
    }

    func testFreshCardNeverFires() {
        // prev == nil: a freshly-appended card / post-reconnect wholesale set never fires.
        XCTAssertNil(AttentionTransition.trigger(prev: nil, task: card(status: .waiting, wait: .permission)))
        XCTAssertNil(AttentionTransition.trigger(prev: nil, task: card(status: .dead, dead: .agentExited)))
    }

    func testNoTransitionWhenStatusUnchanged() {
        // Already-waiting stays waiting → no repeat fire. Already-dead stays dead → no repeat fire.
        XCTAssertNil(AttentionTransition.trigger(prev: .waiting,
            task: card(status: .waiting, wait: .permission)))
        XCTAssertNil(AttentionTransition.trigger(prev: .dead,
            task: card(status: .dead, dead: .agentExited)))
    }

    func testBackgroundWaitProducesNoPush() {
        // A card on a background task stays `.running` (no waitReason) — the adapters emit no waiting
        // report. running → running is not a transition, so it never pushes. This is the bg-wait
        // suppression the spec requires, asserted directly.
        XCTAssertNil(AttentionTransition.trigger(prev: .running, task: card(status: .running)))
        // Even a genuinely-running card that was previously waiting (turn resumed) doesn't push.
        XCTAssertNil(AttentionTransition.trigger(prev: .waiting, task: card(status: .running)))
    }

    // MARK: AttentionTracker (stateful observer)

    func testTrackerFiresOncePerTransition() {
        let tracker = AttentionTracker()
        let id = UUID()
        // First sighting (prev == nil) never fires, even if already waiting.
        XCTAssertNil(tracker.observe(card(id: id, status: .running)))
        // running → waiting fires once…
        let intent = tracker.observe(card(id: id, status: .waiting, wait: .permission))
        XCTAssertEqual(intent?.trigger, .permission)
        XCTAssertEqual(intent?.cardId, id)
        // …and does not re-fire while it stays waiting.
        XCTAssertNil(tracker.observe(card(id: id, status: .waiting, wait: .permission)))
        // waiting → dead fires died.
        XCTAssertEqual(tracker.observe(card(id: id, status: .dead, dead: .agentExited))?.trigger, .died)
    }

    func testTrackerReapsArchivedAndForget() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(card(id: id, status: .running))
        // Archiving reaps state; a later re-add is a fresh card (prev == nil) so it won't fire.
        XCTAssertNil(tracker.observe(card(id: id, status: .waiting, wait: .permission, archived: true)))
        XCTAssertNil(tracker.observe(card(id: id, status: .waiting, wait: .permission)))
        // But the NEXT transition off that fresh baseline fires.
        XCTAssertNil(tracker.observe(card(id: id, status: .running)))
        XCTAssertEqual(tracker.observe(card(id: id, status: .dead, dead: .agentExited))?.trigger, .died)
    }

    // MARK: gating

    func testShouldSendDropsOnlyOff() {
        XCTAssertFalse(PushGate.shouldSend(scope: .off))
        XCTAssertTrue(PushGate.shouldSend(scope: .background))
        XCTAssertTrue(PushGate.shouldSend(scope: .always))
    }

    func testShouldPresentForegroundGate() {
        // .always: present regardless of foreground.
        XCTAssertTrue(PushGate.shouldPresent(scope: .always, appForeground: true))
        XCTAssertTrue(PushGate.shouldPresent(scope: .always, appForeground: false))
        // .background: quiet while foreground, present while backgrounded.
        XCTAssertFalse(PushGate.shouldPresent(scope: .background, appForeground: true))
        XCTAssertTrue(PushGate.shouldPresent(scope: .background, appForeground: false))
        // .off: never.
        XCTAssertFalse(PushGate.shouldPresent(scope: .off, appForeground: false))
    }

    // MARK: prefs snapshot

    func testPrefsSnapshotMatchesDefaults() {
        let defaults = UserDefaults(suiteName: "push-core-snapshot-\(UUID().uuidString)")!
        let snap = NotificationPrefs(defaults: defaults).snapshot()
        XCTAssertEqual(snap.permission.scope, .always)
        XCTAssertEqual(snap.permission.sound, .hero)
        XCTAssertEqual(snap.needsYou.scope, .background)
        XCTAssertEqual(snap.needsYou.sound, .submarine)
        XCTAssertEqual(snap.died.scope, .always)
        XCTAssertEqual(snap.died.sound, .basso)
        XCTAssertEqual(snap.entry(for: .needsYou).scope, .background)
    }

    // MARK: APNs payload

    func testPayloadCarriesDeepLinkKeys() throws {
        let id = UUID()
        let intent = NotificationIntent(trigger: .permission, cardId: id,
                                        cardTitle: "Fix auth", cardRef: "fix-auth")
        let payload = APNsPayload.build(intent: intent, sound: .hero)
        // Custom keys the deep-link reads.
        XCTAssertEqual(payload["taskId"]?.stringValue, id.uuidString)
        XCTAssertEqual(payload["trigger"]?.stringValue, "permission")
        XCTAssertEqual(payload["ref"]?.stringValue, "fix-auth")
        // aps.alert + sound.
        let aps = payload["aps"]
        XCTAssertEqual(aps?["alert"]?["title"]?.stringValue, "Fix auth")
        XCTAssertEqual(aps?["alert"]?["body"]?.stringValue, "Agent needs your approval")
        // A named macOS sound (Hero) isn't bundled on iOS, so it maps to the system default (not
        // "Hero.aiff", which the phone has no file for → APNs would drop the sound silently). See #2.
        XCTAssertEqual(aps?["sound"]?.stringValue, "default")
    }

    func testPayloadSoundFieldVariants() {
        XCTAssertEqual(APNsPayload.soundField(.systemDefault), "default")
        XCTAssertNil(APNsPayload.soundField(.none))
        // Named macOS system sounds don't exist in the iOS bundle → map to "default" so a sound actually
        // plays (a bare "Submarine.aiff" would be silently dropped by APNs). #2.
        XCTAssertEqual(APNsPayload.soundField(.submarine), "default")
        XCTAssertEqual(APNsPayload.soundField(.hero), "default")
        // .none → the sound field is omitted entirely.
        let intent = NotificationIntent(trigger: .died, cardId: UUID(), cardTitle: "x", cardRef: "x")
        XCTAssertNil(APNsPayload.build(intent: intent, sound: .none)["aps"]?["sound"])
    }
}
