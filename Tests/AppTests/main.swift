import AppKit
import Foundation
import Darwin

@MainActor func diffCheckOutput(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print("[DIFF-CHECK] " + String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func diffCheckArgument(_ name: String, default fallback: String = "") -> String {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return fallback
    }
    return CommandLine.arguments[index + 1]
}

let diffCheckApplication = NSApplication.shared
diffCheckApplication.setActivationPolicy(diffCheckArgument("--mode") == "inspect" ? .regular : .accessory)
let diffCheckActivity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .idleDisplaySleepDisabled, .latencyCritical],
    reason: "Native diff UI checks")
var diffCheckProbe: DiffAppProbe?
let diffCheckHeartbeat = Timer(timeInterval: 1, repeats: true) { _ in
    MainActor.assumeIsolated {
        diffCheckOutput(["event": "heartbeat", "phase": diffCheckProbe?.phase ?? "native_checks"])
    }
}
RunLoop.main.add(diffCheckHeartbeat, forMode: .common)
RunLoop.main.add(diffCheckHeartbeat, forMode: .eventTracking)
diffCheckOutput(["event": "start", "pid": ProcessInfo.processInfo.processIdentifier])

if diffCheckArgument("--mode", default: "checks") == "checks" {
    _Concurrency.Task { @MainActor in
        do {
            try await runDiffFileListChecks()
            diffCheckOutput(["event": "pass", "mode": "checks"])
            ProcessInfo.processInfo.endActivity(diffCheckActivity)
            exit(0)
        } catch {
            diffCheckOutput(["event": "failure", "message": String(describing: error)])
            exit(1)
        }
    }
} else {
    do {
        diffCheckProbe = try DiffAppProbe()
        diffCheckProbe!.start()
    } catch {
        diffCheckOutput(["event": "failure", "message": String(describing: error)])
        exit(1)
    }
}
diffCheckApplication.run()
