import Foundation
import OrchestraCore

// orchestrad — the background daemon. Owns all state; runs independent of the app window.

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[orchestrad] \(msg)\n".utf8))
}

let orchestraBin = siblingBinary("orchestra")
let config = ConfigStore.load()
let service = OrchestraService(config: config, store: TaskStore(path: Config.tasksPath))

// Render the managed Claude Code --settings file so it points at the live `orchestra` binary.
do { try HooksRenderer.render(orchestraBin: orchestraBin) }
catch { log("warning: could not render hooks file: \(error)") }

let server = ControlServer(service: service)
server.onConfigChanged = { cfg in
    try? ConfigStore.save(cfg)
    try? HooksRenderer.render(orchestraBin: orchestraBin)
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
    }
}

// Park the main thread servicing GCD (accept loop + connection readers).
dispatchMain()
