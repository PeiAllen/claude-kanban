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

do {
    try server.start()
    log("listening at \(Config.socketPath)")
} catch {
    log("fatal: could not start control server: \(error)")
    exit(1)
}

// Reboot/crash recovery — fired async so a slow revival never blocks the daemon coming up.
// Sweep orphaned scratch dirs first (cards that died without a clean archive), then recover.
_Concurrency.Task {
    await service.sweepOrphanScratch()
    await service.recoverSessions()
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
