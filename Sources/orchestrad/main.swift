import Foundation
import OrchestraCore

// orchestrad — the background daemon. Owns all state; runs independent of the app window.

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[orchestrad] \(msg)\n".utf8))
}

let config = ConfigStore.load()
let service = OrchestraService(config: config, store: TaskStore(path: Config.tasksPath))

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

// Reboot/crash recovery — fired async so a slow revival never blocks the daemon coming up.
// Sweep orphaned scratch dirs first (cards that died without a clean archive), then recover.
_Concurrency.Task {
    await service.sweepOrphanScratch()
    await service.sweepOrphanBorrows()     // O3: prune orch-borrow-* worktrees a crashed borrow left behind
    await service.recoverSessions()
    await service.rebuildRemoteWatches()   // BT6: restart remote merge-watches from live cards' lineage
    await service.rebuildMergeRequestNudges()   // re-arm merge-request re-nudge timers from live cards' state
}

// Background poll: continuous liveness reconcile (safety net for crashes / tmux kill).
_Concurrency.Task {
    while true {
        try? await _Concurrency.Task.sleep(for: .seconds(2))
        await service.reconcileLiveness()
        await service.pollTelemetry()   // tail fileTail (Codex) rollouts → parse → report
    }
}

// Park the main thread servicing GCD (accept loop + connection readers).
dispatchMain()
