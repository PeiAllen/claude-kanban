import Foundation
import Testing
@testable import OrchestraCore

/// The canary for bundle-wide `HOME` isolation.
///
/// Almost everything Orchestra persists is derived from `$HOME` — `Config.dataDir` (the daemon's
/// state, the *rendered Claude/Codex hooks files*), `Config.defaultScratchRoot`, `Config.worktreesRoot`,
/// plus the agents' own homes (`~/.claude`, `~/.claude.json`, `~/.codex`). A test that exercises
/// production code which writes any of those wrote them into the DEVELOPER'S REAL HOME, on their live
/// board, mid-session. That is not hypothetical: `ClaudeCodeAdapter.prepareToLaunch` renders the
/// managed hooks file to `Config.hooksPath` with `__ORCHESTRA_BIN__` resolved from the *running*
/// executable — under `swift test` that is Xcode's `swiftpm-testing-helper`, so the suite wrote a
/// nonexistent `.../libexec/swift/pm/orchestra` into the one settings file every live Claude session
/// was launched with, and every hook in every running card started failing.
///
/// `Tests/GitHermeticBootstrap/bootstrap.c` fixes the class, not the instance: its load-time
/// constructor points `HOME` at a fresh temp dir before the first test of either runner, so *no* test
/// — and no production code under test — can reach the real home no matter what it writes.
///
/// See docs/08-building-operations.md (§Test hermeticity).
@Suite("HOME isolation — the test bundle never writes into the developer's real home")
struct HomeIsolationTests {
    static var isolationDisabled: Bool {
        ProcessInfo.processInfo.environment["ORCHESTRA_TEST_HOME_ISOLATION"] == "0"
    }

    /// The developer's actual home, straight from the password database — the one source of truth the
    /// bootstrap's `setenv("HOME", …)` cannot move.
    static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return "" }
        return String(cString: dir)
    }

    /// The UNGATED test — it runs even when the escape hatch is engaged, so the off-switch can never be
    /// quiet. Exporting `ORCHESTRA_TEST_HOME_ISOLATION=0` (a shell profile, a CI env block, a card's
    /// environment) would otherwise strip the suite of its isolation AND skip every assertion below it,
    /// while still exiting 0.
    @Test("HOME isolation is installed — and the opt-out can never be silent")
    func installedOrLoudlyDisabled() {
        if Self.isolationDisabled {
            Issue.record("""
                HOME isolation is DISABLED (ORCHESTRA_TEST_HOME_ISOLATION=0). This run reads and WRITES \
                the developer's real home — the Orchestra data dir (including the managed Claude/Codex \
                hooks files that every live session is launched with), ~/.orchestra/scratch, ~/.claude. \
                That is fine when you set the variable deliberately to debug a home-sensitive failure; \
                this failure is the alarm, not a bug. Unset the variable to restore isolation.
                """)
            return
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        #expect(!home.isEmpty)
        #expect(home != Self.realHome, "the test bundle is running against the developer's real home")
        #expect(Config.home == home, "Config must resolve HOME from the environment, not the passwd db")
    }

    @Test("the temp home is a writable directory outside both the real home and the repo",
          .enabled(if: !isolationDisabled))
    func tempHomeIsUsableAndOutOfTheWay() throws {
        let home = Config.home
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.isWritableFile(atPath: home))

        #expect(!home.hasPrefix(Self.realHome + "/"))

        // It must also sit outside the checkout: `RepoScannerTests` asserts `Config.defaultReposRoot`
        // (which is just `home`) does not contain "/Documents/Projects", and repo discovery scans
        // recursively under it — a home *inside* the working copy would make the suite scan itself.
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/Tests/OrchestraCoreTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        #expect(!home.hasPrefix(repoRoot + "/"), "the temp home is inside the repo checkout: \(home)")
    }

    @Test("every HOME-derived Config path lands inside the temp home",
          .enabled(if: !isolationDisabled))
    func configPathsFollowTheTempHome() {
        let home = Config.home
        for path in [Config.dataDir, Config.hooksPath,
                     Config.defaultScratchRoot, Config.defaultWorktreesRoot, Config.defaultReposRoot] {
            #expect(path == home || path.hasPrefix(home + "/"), "escapes the temp home: \(path)")
        }
    }

    /// The functional proof — the exact write that broke every live card, replayed.
    ///
    /// `prepareToLaunch` renders the managed settings file to `Config.hooksPath`. Under isolation that
    /// resolves inside the temp home, so the real `~/Library/Application Support/Orchestra/
    /// claude-hooks.json` — the file every running Claude session was launched with, and re-reads
    /// mid-session — is not touched. Asserted against the real file's mtime, not just the path.
    @Test("prepareToLaunch renders the managed hooks file into the temp home, not the live one",
          .enabled(if: !isolationDisabled))
    func adapterHooksRenderStaysInTheTempHome() throws {
        let liveHooks = "\(Self.realHome)/Library/Application Support/Orchestra/claude-hooks.json"
        let before = try? FileManager.default.attributesOfItem(atPath: liveHooks)[.modificationDate] as? Date

        let cwd = NSTemporaryDirectory() + "orch-home-canary-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: cwd))

        #expect(Config.hooksPath.hasPrefix(Config.home + "/"))
        #expect(Config.hooksPath != liveHooks)
        #expect(FileManager.default.fileExists(atPath: Config.hooksPath))

        let after = try? FileManager.default.attributesOfItem(atPath: liveHooks)[.modificationDate] as? Date
        #expect(before == after, "the test suite wrote the LIVE Claude hooks file at \(liveHooks)")
    }
}
