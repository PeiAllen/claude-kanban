import Foundation
import OrchestraCore

// orchestrad — the background daemon. Owns all state; runs independent of the app window.

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[orchestrad] \(msg)\n".utf8))
}

let config = ConfigStore.load()
let terminalSessions = SessionManager()
do {
    if try terminalSessions.reloadTerminalConfiguration() {
        log("reloaded terminal configuration for the existing tmux server")
    }
} catch {
    // An invalid config must be visible to operators, but it must not prevent the daemon from starting:
    // new sessions can still report their launch failure through the normal lifecycle path.
    log("warning: unable to reload terminal configuration: \(error)")
}

// Claude omits its Stop hook when the user interrupts a turn. Bind the local OTLP/HTTP trace receiver
// before the service can launch or adopt any agent, and keep its persisted endpoint stable across daemon
// restarts so surviving sessions continue to report. This is status infrastructure: if it cannot bind,
// fail the daemon startup instead of silently launching Claude cards with a permanently stale interrupt.
let traceReceiver: OTLPHTTPTraceReceiver
do {
    traceReceiver = try OTLPHTTPTraceReceiver(runtimeStateDir: config.runtimeStateDir)
} catch {
    log("fatal: could not start Claude trace receiver: \(error)")
    exit(1)
}
let service = OrchestraService(config: config, store: TaskStore(path: Config.tasksPath), sessions: terminalSessions,
                               traceHTTPBaseURL: traceReceiver.baseURL,
                               proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
traceReceiver.start { observation in
    _Concurrency.Task {
        await service.receivePushedAgentObservation(
            cardId: observation.cardId,
            observedEpoch: observation.sessionEpoch,
            raw: observation.raw
        )
    }
}

// The daemon renders NO hook files — each adapter renders its own in `prepareToLaunch`, per launch,
// so new launches always reflect the current binary path + statusLine config (see [[HooksRenderer]]).

let server = ControlServer(service: service)
server.onConfigChanged = { cfg in
    _ = try? ConfigStore.save(cfg)
}
// Ownership leases are reaped purely by their 30s heartbeat timeout — a disconnected owner's lease
// simply goes stale — so the daemon needs no disconnect→invalidate path.

do {
    try server.start()
    log("listening at \(Config.socketPath)")
} catch {
    log("fatal: could not start control server: \(error)")
    exit(1)
}

// APNs push (N1): a second subscriber to the service event stream that turns attention transitions into
// pushes for registered devices. Delivery is enabled only when APNs credentials are configured
// (ORCH_APNS_* env); otherwise the sender is a documented no-op — push is wired, not exercised.
let pushSender: PushSender
if let apns = APNsConfig.from(env: ProcessInfo.processInfo.environment) {
    pushSender = APNsHTTPSender(config: apns)
    log("push: APNs delivery enabled (\(apns.host), topic \(apns.topic))")
} else {
    pushSender = DisabledPushSender()
    log("push: APNs delivery disabled (no ORCH_APNS_* credentials) — registrations accepted, no send")
}
let pushNotifier = PushNotifier(service: service, sender: pushSender)
_Concurrency.Task { await pushNotifier.run() }

// Reboot/crash recovery — fired async so a slow revival never blocks the daemon coming up. Boot ORDER
// (PR4b): orphan-scratch sweep → one-time marker migration → phase reconciliation (folds the old
// recoverSessions; also wires corrupt-store conservative mode) → orphan-borrow sweep → watch-registry
// reload (delivers conclusions for children terminal-at-reload) → remote watches → merge-request nudges.
_Concurrency.Task {
    await service.sweepOrphanScratch()
    await service.stampMigratedWorktreeMarkersOnce()   // ONE-TIME (sentinel-gated) marker migration
    await service.reconcilePhasesAtBoot()  // re-drive stranded phases; revive .live cards; conservative mode
    await service.reconcileTranscriptMediaAtBoot()  // retain only current media for non-archived cards
    await service.sweepOrphanBorrows()     // O3: prune orch-borrow-* worktrees a crashed borrow left behind
    await service.sweepCardFiles()         // reap orphaned per-card launch-config files (backlog + crash residue)
    await service.redriveArchivedWorktreeReleases()   // finish interrupted removals for archivedComplete cards
    await service.reloadWatchRegistry()    // carry #4: durable watch registry + terminal-at-reload delivery
    await service.rebuildRemoteWatches()   // BT6: restart remote merge-watches from live cards' lineage
    await service.rebuildMergeRequestNudges()   // re-arm merge-request re-nudge timers from live cards' state
}

// Background poll: the continuous reconcile tick (steps transitional cards, launch timeouts, orphan sweep,
// `.live` liveness) + telemetry tail. One `sessions.list()` per tick, hopped off the actor.
_Concurrency.Task {
    while true {
        try? await _Concurrency.Task.sleep(for: .seconds(service.reconcilePollInterval))
        await service.reconcile()
        await service.pollTelemetry()   // tail fileTail (Codex) rollouts → parse → report
    }
}

// Clean-shutdown flush (bug #13): launchd sends SIGTERM before SIGKILL. Flush any debounced telemetry
// `tasks.json` write so a clean restart is lossless (on-disk `rev` catches up to in-memory `rev`), then
// exit. Ignore the default SIGTERM disposition first, then service it on a GCD source off the main queue.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { _Concurrency.Task { await service.flushBeforeShutdown(); exit(0) } }
sigterm.resume()

// Park the main thread servicing GCD (accept loop + connection readers).
dispatchMain()
