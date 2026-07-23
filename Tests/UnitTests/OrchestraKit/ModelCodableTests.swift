import Foundation
import Testing
@testable import OrchestraCore

@Suite("Model Codable — Phase / RunState / Task lifecycle fields")
struct ModelCodableTests {

    @Test("Phase round-trips every case incl. associated values")
    func test_phaseRoundTrips() throws {
        let cases: [Phase] = [
            .creatingWorktree,
            .launching,
            .live(.running),
            .live(.waiting(.permission)),
            .live(.waiting(.humanTurn)),
            .relaunching,
            .dead(.spawnFailed),
            .dead(.agentExited),
            .archived(teardownComplete: false),
            .archived(teardownComplete: true),
        ]
        for phase in cases {
            let data = try OrchestraJSON.wire.encode(phase)
            let back = try OrchestraJSON.decoder.decode(Phase.self, from: data)
            #expect(back == phase, "round-trip mismatch for \(phase)")
        }
    }

    @Test("Phase encodes as {name, detail?} per the wire contract")
    func test_phaseWireShape() throws {
        // Structural (order-independent) checks: `OrchestraJSON.wire` doesn't sort keys, so assert the
        // decoded object shape rather than an exact byte string.
        func obj(_ p: Phase) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: OrchestraJSON.wire.encode(p)) as! [String: Any]
        }
        // Payload-free cases: `name` only, no `detail` key.
        for (p, name) in [(Phase.creatingWorktree, "creatingWorktree"),
                          (.launching, "launching"),
                          (.relaunching, "relaunching")] {
            let o = try obj(p)
            #expect(o["name"] as? String == name)
            #expect(o["detail"] == nil)
        }
        // Nested enums encode recursively: live → {name:live, detail:{name:waiting, detail:permission}}.
        let live = try obj(.live(.waiting(.permission)))
        #expect(live["name"] as? String == "live")
        let run = live["detail"] as? [String: Any]
        #expect(run?["name"] as? String == "waiting")
        #expect(run?["detail"] as? String == "permission")
        // DeadReason stays a raw String in `detail`.
        let dead = try obj(.dead(.agentExited))
        #expect(dead["name"] as? String == "dead")
        #expect(dead["detail"] as? String == "agentExited")
        // archived carries its Bool directly as `detail`.
        let arch = try obj(.archived(teardownComplete: true))
        #expect(arch["name"] as? String == "archived")
        #expect(arch["detail"] as? Bool == true)
    }

    @Test("Phase.kind + isTerminal classify correctly")
    func test_phaseKindAndTerminal() {
        #expect(Phase.creatingWorktree.kind == .creatingWorktree)
        #expect(Phase.launching.kind == .launching)
        #expect(Phase.live(.running).kind == .live)
        #expect(Phase.relaunching.kind == .relaunching)
        #expect(Phase.dead(.agentExited).kind == .dead)
        #expect(Phase.archived(teardownComplete: false).kind == .archivedPending)
        #expect(Phase.archived(teardownComplete: true).kind == .archivedComplete)

        #expect(Phase.dead(.agentExited).isTerminal)
        #expect(Phase.archived(teardownComplete: false).isTerminal)
        #expect(Phase.archived(teardownComplete: true).isTerminal)
        #expect(!Phase.live(.running).isTerminal)
        #expect(!Phase.launching.isTerminal)
    }

    @Test("a fresh Task no longer encodes status/waitReason (flag-day removal)")
    func test_statusFieldRemoved() throws {
        let t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        let obj = try JSONSerialization.jsonObject(
            with: OrchestraJSON.wire.encode(t)) as! [String: Any]
        #expect(obj["status"] == nil, "status must not be on the wire")
        #expect(obj["waitReason"] == nil, "waitReason must not be on the wire")
        #expect(obj["phase"] != nil, "phase is the SSOT on the wire")
        // `AgentStatus` is deleted (compile-level): this file would not compile if any of the
        // model types still referenced it.
    }

    @Test("Task round-trips the phase lifecycle fields")
    func test_taskCarriesPhaseFields() throws {
        let epochDate = Date(timeIntervalSince1970: 1_700_000_000)
        var t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        t.phase = .live(.waiting(.permission))
        t.sessionEpoch = 3
        t.phaseChangedAt = epochDate
        let cutoff = epochDate.addingTimeInterval(60.123_456)
        t.sessionDiscoverySince = cutoff
        t.pendingSeed = "carried context"

        let data = try OrchestraJSON.wire.encode(t)
        let back = try OrchestraJSON.decoder.decode(Task.self, from: data)
        #expect(back.phase == .live(.waiting(.permission)))
        #expect(back.sessionEpoch == 3)
        #expect(back.phaseChangedAt == epochDate)
        let restoredCutoff = try #require(back.sessionDiscoverySince)
        #expect(abs(restoredCutoff.timeIntervalSince(cutoff)) < 0.000_001)
        let shape = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(shape["sessionDiscoverySince"] is NSNumber)   // fractional Unix seconds, not rounded ISO-8601
        var intermediateShape = shape
        intermediateShape["sessionDiscoverySince"] = "2023-11-14T22:13:20Z"
        let intermediate = try OrchestraJSON.decoder.decode(
            Task.self, from: JSONSerialization.data(withJSONObject: intermediateShape))
        #expect(intermediate.sessionDiscoverySince == epochDate)   // accepts the intermediate ISO-8601 shape
        #expect(back.pendingSeed == "carried context")
    }

    @Test("Task round-trips deliveryStuckSince; a record without the key decodes to nil")
    func test_taskCarriesDeliveryStuckSince() throws {
        let stuckAt = Date(timeIntervalSince1970: 1_700_000_500)   // whole-second → exact ISO-8601 round-trip
        var t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        #expect(t.deliveryStuckSince == nil)   // defaults to nil, like pendingSeed
        t.deliveryStuckSince = stuckAt

        let data = try OrchestraJSON.wire.encode(t)
        let back = try OrchestraJSON.decoder.decode(Task.self, from: data)
        #expect(back.deliveryStuckSince == stuckAt)

        // Additive-optional forward-compat: a legacy record lacking the key decodes to nil, never throws.
        var shape = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        shape.removeValue(forKey: "deliveryStuckSince")
        let legacy = try OrchestraJSON.decoder.decode(
            Task.self, from: JSONSerialization.data(withJSONObject: shape))
        #expect(legacy.deliveryStuckSince == nil)
    }

    @Test("Task round-trips pendingQuestion; a record without the key decodes to nil")
    func test_taskCarriesPendingQuestion() throws {
        var t = Task(title: "x", repo: "/r/app", branch: "feat", cwd: "/wt/app/feat",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                     order: 0, initialPrompt: "go")
        #expect(t.pendingQuestion == nil)          // defaults to nil, like note
        // A FRACTIONAL declaredAt — the fence compares sub-second times, so this must survive disk. A
        // whole-second value would round-trip even through `.iso8601` and hide the bug; the fraction is
        // the point.
        let declaredAt = Date(timeIntervalSince1970: 1_700_000_500.123_456)
        t.pendingQuestion = PendingQuestion(text: "ship to main or hold for PR 4?", declaredAt: declaredAt)

        let data = try OrchestraJSON.wire.encode(t)
        let back = try OrchestraJSON.decoder.decode(Task.self, from: data)
        #expect(back.pendingQuestion?.text == "ship to main or hold for PR 4?")
        let restored = try #require(back.pendingQuestion?.declaredAt)
        #expect(abs(restored.timeIntervalSince(declaredAt)) < 0.000_001)   // sub-second, NOT rounded to :00
        // …and it rides as a number on the wire, not an ISO-8601 string (which would round to the second).
        let shape = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((shape["pendingQuestion"] as? [String: Any])?["declaredAt"] is NSNumber)

        // A legacy interim bare-String value must drop only the question, never the whole card.
        var stringShape = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        stringShape["pendingQuestion"] = "an old string-form question"
        let salvaged = try OrchestraJSON.decoder.decode(
            Task.self, from: JSONSerialization.data(withJSONObject: stringShape))
        #expect(salvaged.pendingQuestion == nil)   // question dropped…
        #expect(salvaged.id == t.id)               // …but the card survived

        // Additive-optional forward-compat: every card persisted before this field decodes to nil rather
        // than throwing — a throw would make `FailableTask` DROP the whole card.
        var absentShape = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        absentShape.removeValue(forKey: "pendingQuestion")
        let legacy = try OrchestraJSON.decoder.decode(
            Task.self, from: JSONSerialization.data(withJSONObject: absentShape))
        #expect(legacy.pendingQuestion == nil)

        // …and a card with no question does not emit the key at all (encodeIfPresent).
        var plain = t; plain.pendingQuestion = nil
        let plainShape = try JSONSerialization.jsonObject(
            with: try OrchestraJSON.wire.encode(plain)) as! [String: Any]
        #expect(plainShape["pendingQuestion"] == nil)
    }
}
