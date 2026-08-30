import XCTest
import OrchestraKit

final class PushCoreTests: XCTestCase {
    private func card(id: UUID = UUID(), phase: Phase = .live(.running),
                      mergeStalled: Bool = false, archived: Bool = false) -> Task {
        let tree = mergeStalled ? TreeStat(state: .inSync, mergeStalled: true) : nil
        return Task(id: id, title: "card", repo: "/repo", branch: "feat/x", cwd: "/repo/.wt/x",
                    model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl, order: 0,
                    phase: phase, initialPrompt: "card", treeStat: tree, archived: archived)
    }

    func testPhaseTransitionsMapToPushTriggers() {
        let running = card()
        let blocked = card(id: running.id,
                           phase: .live(.init(turnStatus: .running, humanNeed: .permission)))
        XCTAssertEqual(AttentionTransition.trigger(prev: running, task: blocked), .humanRequired)
        XCTAssertEqual(AttentionTransition.trigger(
            prev: running, task: card(id: running.id, phase: .dead(.agentExited))), .died)
        XCTAssertNil(AttentionTransition.trigger(prev: nil, task: blocked))
    }

    func testTrackerFiresEachRealPhaseEdgeOnce() {
        let tracker = AttentionTracker()
        let id = UUID()
        XCTAssertNil(tracker.observe(card(id: id)))
        XCTAssertEqual(tracker.observe(card(
            id: id, phase: .live(.init(turnStatus: .running, humanNeed: .permission)))
        )?.trigger, .humanRequired)
        XCTAssertNil(tracker.observe(card(
            id: id, phase: .live(.init(turnStatus: .running, humanNeed: .permission)))))
        XCTAssertEqual(tracker.observe(card(id: id, phase: .dead(.agentExited)))?.trigger, .died)
    }

    func testMergeStalledHasOneRisingEdgeAndRearmsAfterClear() {
        let tracker = AttentionTracker()
        let id = UUID()
        XCTAssertNil(tracker.observe(card(id: id)))
        XCTAssertEqual(tracker.observe(card(id: id, mergeStalled: true))?.trigger, .mergeStalled)
        XCTAssertNil(tracker.observe(card(id: id, mergeStalled: true)))
        XCTAssertNil(tracker.observe(card(id: id)))
        XCTAssertEqual(tracker.observe(card(id: id, mergeStalled: true))?.trigger, .mergeStalled)
    }

    func testPhaseEdgesOutrankMergeStalled() {
        let tracker = AttentionTracker()
        let id = UUID()
        _ = tracker.observe(card(id: id))
        XCTAssertEqual(tracker.observe(card(
            id: id, phase: .dead(.agentExited), mergeStalled: true))?.trigger, .died)
    }

    func testPushScopeGatesAndPayload() {
        XCTAssertFalse(PushGate.shouldSend(scope: .off))
        XCTAssertTrue(PushGate.shouldSend(scope: .background))
        XCTAssertFalse(PushGate.shouldPresent(scope: .background, appForeground: true))
        XCTAssertTrue(PushGate.shouldPresent(scope: .always, appForeground: true))

        let id = UUID()
        let payload = APNsPayload.build(
            intent: .init(trigger: .mergeStalled, cardId: id, cardTitle: "Fix auth", cardRef: "fix-auth"),
            sound: .submarine)
        XCTAssertEqual(payload["taskId"]?.stringValue, id.uuidString)
        XCTAssertEqual(payload["trigger"]?.stringValue, "mergeStalled")
        XCTAssertEqual(payload["aps"]?["alert"]?["body"]?.stringValue,
                       "Merge request needs you — agent gave up asking")
        XCTAssertEqual(payload["aps"]?["sound"]?.stringValue, "default")
    }

    func testMergeStalledPreferencesRoundTripAndLegacySnapshotDefaults() throws {
        XCTAssertEqual(NotificationPrefs.defaultScope(.mergeStalled), .background)
        XCTAssertEqual(NotificationPrefs.defaultSound(.mergeStalled), .submarine)

        let base = NotifyPrefsSnapshot.Entry(scope: .always, sound: .hero)
        let stall = NotifyPrefsSnapshot.Entry(scope: .off, sound: .glass)
        let snapshot = NotifyPrefsSnapshot(humanRequired: base, died: base, mergeStalled: stall)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["humanRequired", "died", "mergeStalled"])
        XCTAssertEqual(try JSONDecoder().decode(NotifyPrefsSnapshot.self, from: data), snapshot)

        let legacy = try JSONEncoder().encode(["permission": base, "died": base])
        let decoded = try JSONDecoder().decode(NotifyPrefsSnapshot.self, from: legacy)
        XCTAssertEqual(decoded.humanRequired, base)
        XCTAssertEqual(decoded.mergeStalled, NotifyPrefsSnapshot.defaultEntry(.mergeStalled))
    }
}
