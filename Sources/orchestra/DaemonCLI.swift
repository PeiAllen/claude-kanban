import Foundation
import OrchestraCore

/// `orchestra daemon install|start|stop|status|uninstall`.
enum DaemonCLI {
    static func run(_ args: [String]) {
        let sub = args.first ?? "status"
        let life = DaemonLifecycle()
        let orchestradBin = siblingBinary("orchestrad")
        switch sub {
        case "install", "start":
            do {
                try life.install(orchestradBin: orchestradBin)
                print("orchestrad installed + loaded (\(orchestradBin))")
            } catch { FileHandle.standardError.write(Data("install failed: \(error)\n".utf8)); exit(1) }
        case "stop", "uninstall":
            life.uninstall()
            print("orchestrad unloaded")
        case "status":
            print(life.isRunning() ? "running" : "not running")
        default:
            print("usage: orchestra daemon [install|start|stop|status|uninstall]")
        }
    }
}
