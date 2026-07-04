import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit   // Config.dataDir(isLinux:home:env:) is an internal Kit helper post-F1

@Suite("Config.dataDir — platform-specific data directory")
struct ConfigDataDirTests {
    @Test("macOS uses ~/Library/Application Support/Orchestra")
    func macOS() {
        let d = Config.dataDir(isLinux: false, home: "/Users/x", env: [:])
        #expect(d == "/Users/x/Library/Application Support/Orchestra")
    }

    @Test("Linux uses $XDG_DATA_HOME/orchestra when set")
    func linuxXDG() {
        let d = Config.dataDir(isLinux: true, home: "/home/x", env: ["XDG_DATA_HOME": "/home/x/.xdg"])
        #expect(d == "/home/x/.xdg/orchestra")
    }

    @Test("Linux falls back to ~/.local/share/orchestra when XDG unset")
    func linuxDefault() {
        let d = Config.dataDir(isLinux: true, home: "/home/x", env: [:])
        #expect(d == "/home/x/.local/share/orchestra")
    }

    @Test("Linux treats an empty XDG_DATA_HOME as unset")
    func linuxEmptyXDG() {
        let d = Config.dataDir(isLinux: true, home: "/home/x", env: ["XDG_DATA_HOME": ""])
        #expect(d == "/home/x/.local/share/orchestra")
    }
}
