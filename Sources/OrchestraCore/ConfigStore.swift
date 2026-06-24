import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

/// Load/save the daemon-owned `config.json`.
public enum ConfigStore {
    public static func load(path: String = Config.configPath) -> Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let c = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return c
    }

    @discardableResult
    public static func save(_ config: Config, path: String = Config.configPath) throws -> Config {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(config)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return config
    }
}

/// Absolute path of the currently-running executable.
public func currentExecutablePath() -> String {
    #if canImport(Darwin)
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) == 0 {
        let path = String(cString: buf)
        return PathResolver.canonical(path)
    }
    #endif
    return PathResolver.canonical(CommandLine.arguments.first ?? "orchestra")
}

/// Resolve a sibling binary next to the running executable (e.g. orchestrad -> orchestra).
public func siblingBinary(_ name: String) -> String {
    let dir = (currentExecutablePath() as NSString).deletingLastPathComponent
    let candidate = "\(dir)/\(name)"
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    // Fall back to PATH resolution.
    if let r = try? Proc.run(["which", name]), r.ok {
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
    }
    return candidate
}
