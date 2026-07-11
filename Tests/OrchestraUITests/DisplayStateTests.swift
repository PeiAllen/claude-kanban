import Testing
import Foundation
@testable import OrchestraKit

@Suite struct DisplayStateTests {

    /// The daemon verbs the catalog admits for a phase — the ground truth `validActions` must DERIVE from
    /// (a hand-copied table would diverge from this). `.openNotes` is the only non-catalog (local) extra.
    private func catalogVerbs(_ phase: Phase) -> Set<Verb> {
        Set(CommandCatalog.all.filter { $0.phaseGate.contains(phase.kind) }.map { Verb($0.name) })
    }

    // dead(.spawnFailed) is DEAD — never "Creating…"/"Starting" — and offers restart, not shell-while-born.
    @Test func test_displayStateActionsByPhase() {
        // DERIVATION (not a hand-copy): live's daemon verbs == exactly the catalog's phaseGate admits.
        let live = displayState(phase: .live(.running), connection: .live)
        #expect(live.validActions.subtracting([.openNotes]) == catalogVerbs(.live(.running)))
        #expect(live.statusKey == .running)
        #expect(live.validActions.isSuperset(of: [.shell, .inspect, .move, .send, .restart]))
        #expect(live.validActions.contains(.openNotes))   // cwd materialized
        #expect(live.isBusy == false)
        #expect(live.isStale == false)

        // creatingWorktree: busy, "Starting"; shell/inspect/restart NOT dispatchable yet; no notes dir yet.
        let born = displayState(phase: .creatingWorktree, connection: .live)
        #expect(born.validActions == catalogVerbs(.creatingWorktree))   // no .openNotes (cwd not materialized)
        #expect(born.statusKey == .starting)
        #expect(born.label == "Starting")
        #expect(born.isBusy == true)
        #expect(!born.validActions.contains(.shell))
        #expect(!born.validActions.contains(.inspect))
        #expect(!born.validActions.contains(.restart))
        #expect(!born.validActions.contains(.openNotes))

        // dead(.spawnFailed): DEAD, never "Creating…"; restart/archive/resume/shell available; not busy;
        // NO .openNotes (the worktree never materialized).
        let failed = displayState(phase: .dead(.spawnFailed), connection: .live)
        #expect(failed.validActions == catalogVerbs(.dead(.spawnFailed)))
        #expect(failed.statusKey == .dead)
        #expect(failed.label == "Dead")
        #expect(failed.label != "Starting" && failed.label != "Creating…")
        #expect(failed.isBusy == false)
        #expect(failed.validActions.isSuperset(of: [.restart, .archive, .resume, .shell]))
        #expect(!failed.validActions.contains(.openNotes))

        // Disconnected: EVERY action drops out — including `.openNotes`, which is a daemon RPC
        // (`BoardStore.openNotes` → `client.call`), not a local file op. The contract is "validActions
        // empty when the link is down"; the label stays honest (staleness is a separate signal).
        let offline = displayState(phase: .live(.running), connection: .retrying)
        #expect(offline.isStale == true)
        #expect(offline.validActions.isEmpty)           // no verb — daemon OR openNotes — dispatchable offline
        #expect(!offline.validActions.contains(.openNotes))
        #expect(!offline.validActions.contains(.shell))
        #expect(offline.statusKey == .running)          // staleness is a separate signal from the phase label
    }
}
