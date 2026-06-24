import Foundation

/// Abstraction over `launchctl` so install/uninstall logic is testable with a mock (no real
/// LaunchAgent touched in CI).
public protocol Launchctl: Sendable {
    func run(_ args: [String]) throws -> ProcResult
}

public struct RealLaunchctl: Launchctl {
    public init() {}
    public func run(_ args: [String]) throws -> ProcResult {
        try Proc.run(["launchctl"] + args)
    }
}

/// Install / load / ensureRunning / uninstall the `com.orchestra.daemon` LaunchAgent.
public struct DaemonLifecycle: Sendable {
    public static let label = "com.orchestra.daemon"
    let launchctl: Launchctl
    let plistPath: String
    let socketPath: String

    public init(launchctl: Launchctl = RealLaunchctl(),
                plistPath: String = "\(Config.home)/Library/LaunchAgents/com.orchestra.daemon.plist",
                socketPath: String = Config.socketPath) {
        self.launchctl = launchctl
        self.plistPath = plistPath
        self.socketPath = socketPath
    }

    /// Template path for the plist.
    static var templatePath: String? {
        Bundle.module.path(forResource: "com.orchestra.daemon", ofType: "plist")
    }

    /// Render + write the plist and bootstrap it into the user's GUI domain.
    public func install(orchestradBin: String, logPath: String = Config.logPath) throws {
        let template: String
        if let p = Self.templatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            template = s
        } else {
            template = fallbackPlist
        }
        let rendered = template
            .replacingOccurrences(of: "__ORCHESTRAD_BIN__", with: orchestradBin)
            .replacingOccurrences(of: "__LOG__", with: logPath)
        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try rendered.write(toFile: plistPath, atomically: true, encoding: .utf8)
        load()
    }

    /// Bootstrap + enable (idempotent — ignores "already loaded").
    public func load() {
        let uid = getuid()
        _ = try? launchctl.run(["bootstrap", "gui/\(uid)", plistPath])
        _ = try? launchctl.run(["enable", "gui/\(uid)/\(Self.label)"])
    }

    /// True if a daemon is answering on the control socket.
    public func isRunning() -> Bool {
        guard let fd = try? UDS.connect(path: socketPath) else { return false }
        defer { closeFd(fd) }
        let line = (try? RPCCodec.line(RPCRequest(id: 1, method: "ping"))) ?? Data()
        guard UDS.writeAll(fd, line) else { return false }
        let reader = LineReader(fd: fd)
        return reader.next() != nil
    }

    /// App/CLI call this on launch: if not running, install + load.
    public func ensureRunning(orchestradBin: String) throws {
        if isRunning() { return }
        try install(orchestradBin: orchestradBin)
    }

    public func uninstall() {
        let uid = getuid()
        _ = try? launchctl.run(["bootout", "gui/\(uid)/\(Self.label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private func closeFd(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #endif
    }

    private var fallbackPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.orchestra.daemon</string>
          <key>ProgramArguments</key><array><string>__ORCHESTRAD_BIN__</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>StandardOutPath</key><string>__LOG__</string>
          <key>StandardErrorPath</key><string>__LOG__</string>
        </dict></plist>
        """
    }
}

#if canImport(Darwin)
import Darwin
#endif
