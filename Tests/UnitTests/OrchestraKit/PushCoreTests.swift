import XCTest
import OrchestraKit

/// The provider-neutral push core (N1): the attention transition→intent mapping (incl. fresh-card and
/// background-wait suppression), the scope gating (daemon `shouldSend` + client `shouldPresent`), and the
/// APNs payload shape. Pure logic — no daemon, no APNs, no Simulator.
final class PushCoreTests: XCTestCase {

    private func card(_ title: String = "card",
                      id: UUID = UUID(),
                      phase: Phase = .live(.running),
                      dead: DeadReason? = nil,
                      archived: Bool = false) -> Task {
        Task(id: id, title: title, repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
             deadReason: dead, phase: phase, ctxPct: 0,
             initialPrompt: title, archived: archived)
    }

    // MARK: transition → trigger

    func testTransitionsMapToTriggers() {
        // running → waiting(permission) fires permission
        XCTAssertEqual(AttentionTransition.trigger(prev: .live(.running),
            task: card(phase: .live(.permissionRequested))), .permission)
        // running → waiting(humanTurn) fires needsYou
        XCTAssertEqual(AttentionTransition.trigger(prev: .live(.running),
            task: card(phase: .live(.waiting))), .needsYou)
        // any → dead fires died
        XCTAssertEqual(AttentionTransition.trigger(prev: .live(.running),
            task: card(phase: .dead(.agentExited))), .died)
        XCTAssertEqual(AttentionTransition.trigger(prev: .live(.waiting),
            task: card(phase: .dead(.sessionVanished))), .died)
    }

    func testFreshCardNeverFires() {
        // prev == nil: a freshly-appended card / post-reconnect wholesale set never fires.
        XCTAssertNil(AttentionTransition.trigger(prev: nil, task: card(phase: .live(.permissionRequested))))
        XCTAssertNil(AttentionTransition.trigger(prev: nil, task: card(phase: .dead(.agentExited))))
    }

    func testIndependentRequestTransitionStillFires() {
        // Turn status and requests are independent: a permission request opening while the previous
        // snapshot was waiting is still a new permission edge and must fire.
        XCTAssertEqual(AttentionTransition.trigger(prev: .live(.waiting),
            task: card(phase: .live(.permissionRequested))), .permission)
        // Already-dead stays dead → no repeat fire.
        XCTAssertNil(AttentionTransition.trigger(prev: .dead(.agentExited),
            task: card(phase: .dead(.agentExited))))
    }

    func testBackgroundWaitProducesNoPush() {
        // The turn is closed, but the provider has committed to resume automatically. Work remains in
        // flight, so this is not a Needs-You edge even though the visible turn status is waiting.
        let autoResume = AgentState(turnStatus: .waiting(.init(resume: .init())))
        XCTAssertNil(AttentionTransition.trigger(prev: .live(.running), task: card(phase: .live(autoResume))))
        // Even a genuinely-running card that was previously waiting (turn resumed) doesn't push.
        XCTAssertNil(AttentionTransition.trigger(prev: .live(.waiting), task: card(phase: .live(.running))))
    }

    // MARK: AttentionTracker (stateful observer)

    func testTrackerFiresOncePerTransition() {
        let tracker = AttentionTracker()
        let id = UUID()
        // First sighting (prev == nil) never fires, even if already waiting.
        XCTAssertNil(tracker.observe(card(id: id, phase: .live(.running))))
        // running → waiting fires once…
        let intent = tracker.observe(card(id: id, phase: .live(.permissionRequested)))
        XCTAssertEqual(intent?.trigger, .permission)
        XCTAssertEqual(intent?.cardId, id)
        // …and does not re-fire while it stays waiting.
        XCTAssertNil(tracker.observe(card(id: id, phase: .live(.permissionRequested))))
        // waiting → dead fires died.
        XCTAssertEqual(tracker.observe(card(id: id, phase: .dead(.agentExited)))?.trigger, .died)
    }

    func testTrackerReapsArchivedAndForget() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(card(id: id, phase: .live(.running)))
        // Archiving reaps state; a later re-add is a fresh card (prev == nil) so it won't fire.
        XCTAssertNil(tracker.observe(card(id: id, phase: .live(.permissionRequested), archived: true)))
        XCTAssertNil(tracker.observe(card(id: id, phase: .live(.permissionRequested))))
        // But the NEXT transition off that fresh baseline fires.
        XCTAssertNil(tracker.observe(card(id: id, phase: .live(.running))))
        XCTAssertEqual(tracker.observe(card(id: id, phase: .dead(.agentExited)))?.trigger, .died)
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

    // MARK: - delivery-stuck / merge-stalled surfacing (B5b)

    /// A card carrying the arm's `deliveryStuckSince` flag and/or the merge-request loop's sticky
    /// `TreeStat.mergeStalled` flag. B5b RENDERS these — it never sets them.
    private func stuckCard(id: UUID = UUID(),
                           phase: Phase = .live(.waiting),
                           deliveryStuck: Bool = false,
                           mergeStalled: Bool = false,
                           treeState: TreeState = .inSync,
                           archived: Bool = false) -> Task {
        let ts: TreeStat? = (mergeStalled || treeState != .inSync)
            ? TreeStat(state: treeState, mergeStalled: mergeStalled) : nil
        return Task(id: id, title: "card", repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
                    model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
                    deadReason: nil, phase: phase,
                    deliveryStuckSince: deliveryStuck ? Date(timeIntervalSince1970: 1000) : nil,
                    ctxPct: 0, initialPrompt: "card", treeStat: ts, archived: archived)
    }

    // currentStuckTrigger — the "which stuck" authority

    func testCurrentStuckTrigger() {
        XCTAssertNil(AttentionTransition.currentStuckTrigger(stuckCard()))
        XCTAssertEqual(AttentionTransition.currentStuckTrigger(stuckCard(deliveryStuck: true)), .deliveryStuck)
        XCTAssertEqual(AttentionTransition.currentStuckTrigger(stuckCard(mergeStalled: true)), .mergeStalled)
        // Both set → delivery wins (matches reason(for:) order).
        XCTAssertEqual(AttentionTransition.currentStuckTrigger(stuckCard(deliveryStuck: true, mergeStalled: true)),
                       .deliveryStuck)
    }

    // stuckRise — the one-shot edge (on the BOOLEAN, not the cause)

    func testStuckRiseFiresOnlyOnRise() {
        let card = stuckCard(deliveryStuck: true)
        // was-not-stuck + seen + now-stuck → fires the current trigger.
        XCTAssertEqual(AttentionTransition.stuckRise(wasStuck: false, seen: true, cur: card), .deliveryStuck)
        // already stuck → no re-fire.
        XCTAssertNil(AttentionTransition.stuckRise(wasStuck: true, seen: true, cur: card))
        // first sighting (not seen) → suppressed even though already stuck.
        XCTAssertNil(AttentionTransition.stuckRise(wasStuck: false, seen: false, cur: card))
        // not stuck → nothing.
        XCTAssertNil(AttentionTransition.stuckRise(wasStuck: false, seen: true, cur: stuckCard()))
    }

    // AttentionTracker one-shot

    func testStuckNotifiesOnceOnFlip() {
        let tracker = AttentionTracker()
        let id = UUID()
        XCTAssertNil(tracker.observe(stuckCard(id: id)))                              // first sighting, not stuck
        let intent = tracker.observe(stuckCard(id: id, deliveryStuck: true))          // rise
        XCTAssertEqual(intent?.trigger, .deliveryStuck)
        XCTAssertEqual(intent?.cardId, id)
    }

    func testStuckRepeatUpsertsSuppressed() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
        // Same stuck state re-upserted → no second push.
        XCTAssertNil(tracker.observe(stuckCard(id: id, deliveryStuck: true)))
    }

    func testUnstickClearsThenReflipNotifiesAgain() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
        // Unstick — clears the memory, no push for the clear itself.
        XCTAssertNil(tracker.observe(stuckCard(id: id)))
        // Re-flip fires again.
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
    }

    func testStuckCauseChangeDoesNotRefire() {
        // The MAJOR-1 pin: a card that stays stuck while its CAUSE changes (delivery clears while merge
        // stalls) never left "stuck", so it must NOT fire a second push.
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
        // deliveryStuckSince cleared (confirm), but mergeStalled now true — still stuck the whole time.
        XCTAssertNil(tracker.observe(stuckCard(id: id, mergeStalled: true)))
    }

    func testBothStuckFlagsRisesOnce() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        // Both flags flip in one event → one push, delivery wins.
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true, mergeStalled: true))?.trigger,
                       .deliveryStuck)
        XCTAssertNil(tracker.observe(stuckCard(id: id, deliveryStuck: true, mergeStalled: true)))
    }

    func testArchiveClearsStuckThenReAddSuppressedThenRises() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
        // Archive reaps stuck memory.
        XCTAssertNil(tracker.observe(stuckCard(id: id, deliveryStuck: true, archived: true)))
        // Re-add of a stuck card is a fresh first-sighting → suppressed.
        XCTAssertNil(tracker.observe(stuckCard(id: id, deliveryStuck: true)))
        // Unstick then a later re-flip rises again off the fresh baseline.
        XCTAssertNil(tracker.observe(stuckCard(id: id)))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
    }

    func testForgetClearsStuckState() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id))
        XCTAssertEqual(tracker.observe(stuckCard(id: id, deliveryStuck: true))?.trigger, .deliveryStuck)
        tracker.forget(id)
        // After forget, a stuck card is a fresh first-sighting → suppressed.
        XCTAssertNil(tracker.observe(stuckCard(id: id, deliveryStuck: true)))
    }

    func testStuckTakesPrecedenceOverNeedsYouInOneObserve() {
        // A single event that is BOTH a turn edge (→ ordinary waiting) AND a stuck rise fires the stuck
        // trigger (more specific), not needsYou.
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(stuckCard(id: id, phase: .live(.running)))
        let intent = tracker.observe(stuckCard(id: id, phase: .live(.waiting), deliveryStuck: true))
        XCTAssertEqual(intent?.trigger, .deliveryStuck)
    }

    func testDiedAndPermissionPhaseEdgesOutrankACoincidentStuckRise() {
        // Notification precedence mirrors the queue: a recovery/permission-critical phase edge wins over a
        // stuck rise in the same observe, so the recovery-critical push is never dropped for a stuck one.
        let died = AttentionTracker()
        let d = UUID()
        _ = died.observe(stuckCard(id: d, phase: .live(.running)))
        XCTAssertEqual(died.observe(stuckCard(id: d, phase: .dead(.agentExited), deliveryStuck: true))?.trigger, .died)

        let perm = AttentionTracker()
        let p = UUID()
        _ = perm.observe(stuckCard(id: p, phase: .live(.running)))
        XCTAssertEqual(perm.observe(stuckCard(id: p, phase: .live(.permissionRequested), deliveryStuck: true))?.trigger,
                       .permission)
    }

    // Prefs defaults + APNs body for the new triggers

    func testStuckTriggerDefaultsAndBody() {
        XCTAssertEqual(NotificationPrefs.defaultScope(.deliveryStuck), .background)
        XCTAssertEqual(NotificationPrefs.defaultScope(.mergeStalled), .background)
        XCTAssertEqual(NotificationPrefs.defaultSound(.deliveryStuck), .submarine)
        XCTAssertEqual(APNsPayload.body(for: .deliveryStuck), "Agent can't reach you — delivery stuck")
        XCTAssertEqual(APNsPayload.body(for: .mergeStalled), "Merge request needs you — agent gave up asking")
    }

    // NotifyPrefsSnapshot wire tolerance (MAJOR-2 pin)

    func testSnapshotThreeArgInitStillCompilesAndDefaults() {
        // The pre-existing 3-arg call site keeps compiling; the two new triggers default to their designed prefs.
        let e = NotifyPrefsSnapshot.Entry(scope: .always, sound: .glass)
        let snap = NotifyPrefsSnapshot(permission: e, needsYou: e, died: e)
        XCTAssertEqual(snap.deliveryStuck.scope, .background)
        XCTAssertEqual(snap.mergeStalled.sound, .submarine)
    }

    func testSnapshotCarriesNonDefaultStuckPrefsThroughEncodeDecode() throws {
        // DISTINCT non-default values for the two new triggers, so a dropped key or a defaulted field would
        // change the assertion (the earlier default-only test couldn't catch that).
        let stuck = NotifyPrefsSnapshot.Entry(scope: .always, sound: .frog)     // != .background/.submarine
        let stall = NotifyPrefsSnapshot.Entry(scope: .off,    sound: .glass)
        let base  = NotifyPrefsSnapshot.Entry(scope: .always, sound: .hero)
        let snap = NotifyPrefsSnapshot(permission: base, needsYou: base, died: base,
                                       deliveryStuck: stuck, mergeStalled: stall)
        let data = try JSONEncoder().encode(snap)
        // The encoder writes ALL FIVE keys (a synthesized encoder over 5 stored props would; guards a
        // hand-rolled encoder regression that dropped one).
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["permission", "needsYou", "died", "deliveryStuck", "mergeStalled"])
        // Non-default values survive the round trip unchanged.
        let decoded = try JSONDecoder().decode(NotifyPrefsSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.deliveryStuck, stuck)
        XCTAssertEqual(decoded.mergeStalled, stall)
    }

    func testSnapshotDecodesOldThreeKeyPayloadWithDefaultStuckEntries() throws {
        // An already-persisted DeviceRegistration / un-updated phone's snapshot has only the 3 original keys.
        let e = NotifyPrefsSnapshot.Entry(scope: .always, sound: .hero)
        let json = try JSONEncoder().encode(["permission": e, "needsYou": e, "died": e])
        let decoded = try JSONDecoder().decode(NotifyPrefsSnapshot.self, from: json)
        XCTAssertEqual(decoded.permission, e)
        // Missing keys fill with the trigger's DESIGNED default entry (not Off) so an old phone still pushes.
        XCTAssertEqual(decoded.deliveryStuck, NotifyPrefsSnapshot.defaultEntry(.deliveryStuck))
        XCTAssertEqual(decoded.mergeStalled, NotifyPrefsSnapshot.defaultEntry(.mergeStalled))
        XCTAssertEqual(decoded.deliveryStuck.scope, .background)
        XCTAssertEqual(decoded.mergeStalled.sound, .submarine)
    }

    func testSnapshotFromPrefsCarriesNonDefaultStuckScopeAndSound() {
        // snapshot() must read the two new triggers' ACTUAL stored prefs, not defaults.
        let d = UserDefaults(suiteName: "push-core-stuck-snap-\(UUID().uuidString)")!
        let prefs = NotificationPrefs(defaults: d)
        prefs.setScope(.always, for: .deliveryStuck); prefs.setSound(.frog, for: .deliveryStuck)
        prefs.setScope(.off, for: .mergeStalled);     prefs.setSound(.glass, for: .mergeStalled)
        let snap = prefs.snapshot()
        XCTAssertEqual(snap.deliveryStuck, .init(scope: .always, sound: .frog))
        XCTAssertEqual(snap.mergeStalled, .init(scope: .off, sound: .glass))
    }
}
