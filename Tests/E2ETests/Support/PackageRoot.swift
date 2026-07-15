import Foundation

/// Walk up from a source file to the package root (the dir containing `Package.swift`). Replaces the
/// fragile `#filePath` + fixed `deletingLastPathComponent()` chains, which broke the moment a test file
/// moved to a different directory depth. `#filePath` as a default argument resolves at the CALL site, so
/// any E2E test can call `PackageRoot.find()` and get the same root regardless of its own subdirectory.
enum PackageRoot {
    static func find(from filePath: String = #filePath) -> String {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // reached the filesystem root — give up
            dir = parent
        }
        return dir.path
    }
}
