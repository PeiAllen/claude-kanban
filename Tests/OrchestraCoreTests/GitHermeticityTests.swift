import Foundation
import Testing
@testable import OrchestraCore

/// The canary for bundle-wide git hermeticity.
///
/// Every real-`git` fork in the suite — from tests *and* from the production code under test — goes
/// through `Proc.run`, which rebuilds the child environment from `ProcessInfo.processInfo.environment`
/// on every call. `Tests/GitHermeticBootstrap/bootstrap.c` exploits that: its load-time constructor
/// installs a hermetic git environment into the test process before the first test of either runner
/// (XCTest or swift-testing), so no fork can reach the developer's `~/.gitconfig`.
///
/// That constructor is the single fragile assumption in the design — it works only for as long as
/// SwiftPM keeps linking the C target into the test bundle. These tests are what make a regression
/// LOUD: if the bootstrap ever stops running, the suite goes red here instead of silently going back
/// to reading (and running the keychain credential helper from) the developer's personal git config.
///
/// See notes/designs/2026-07-11-test-suite-git-hermeticity.md.
@Suite("Git hermeticity — the test bundle never reads the developer's git config")
struct GitHermeticityTests {
    /// The escape hatch is honoured by the bootstrap itself, so these assertions only hold when it is
    /// not engaged.
    static var hermeticityDisabled: Bool {
        ProcessInfo.processInfo.environment["ORCHESTRA_TEST_GIT_HERMETIC"] == "0"
    }

    /// The one UNGATED test — it runs even when the escape hatch is engaged.
    ///
    /// Every other test here is gated on `ORCHESTRA_TEST_GIT_HERMETIC=0`, which is right (opting out of
    /// the bootstrap must opt out of its assertions) but leaves a hole: if that variable ever got
    /// exported — a shell profile, a CI env block, an Orchestra card's environment — the suite would
    /// lose hermeticity AND its only guard, skip all five tests, and still exit 0. A safety property
    /// whose guard has a *silent* off-switch is not a safety property.
    ///
    /// So the opt-out stays available, but it can never be quiet: engaging it fails this test, by name.
    @Test("git hermeticity is installed — and the opt-out can never be silent")
    func installedOrLoudlyDisabled() {
        if Self.hermeticityDisabled {
            Issue.record("""
                git hermeticity is DISABLED (ORCHESTRA_TEST_GIT_HERMETIC=0). This run forks git against \
                the developer's real ~/.gitconfig — it may invoke a credential helper and its results \
                are not reproducible. That is fine when you set the variable deliberately to debug a \
                config-sensitive failure; this failure is the alarm, not a bug. Unset the variable to \
                restore hermeticity.
                """)
            return
        }
        let env = ProcessInfo.processInfo.environment
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
    }

    private func repo() throws -> String {
        let dir = NSTemporaryDirectory() + "orch-hermetic-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Proc.checked(["git", "init", "-q"], cwd: dir)
        return dir
    }

    @Test("system + global config are cut", .enabled(if: !hermeticityDisabled))
    func configScopesAreCut() throws {
        let env = ProcessInfo.processInfo.environment
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")

        // git itself reports an EMPTY global config: if the developer's ~/.gitconfig (or the XDG
        // config, which GIT_CONFIG_GLOBAL also displaces) were still in scope, this would list their
        // settings. Note this check is vacuous on a machine that HAS no global config — a clean CI box
        // passes it for free. The env assertions above are what carry the load there.
        let r = try Proc.run(["git", "config", "--global", "--list"], cwd: try repo())
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "global git config leaked into the test bundle: \(r.stdout)")
    }

    /// The whole reason this card exists: `credential.helper = osxkeychain` in the developer's global
    /// config made git invoke the keychain helper during tests, which the Claude Code sandbox denies.
    ///
    /// We assert on the resolved helper *list*, not on the exit code. The key is deliberately SET to
    /// an empty value rather than unset — an empty `credential.helper` is git's documented idiom for
    /// resetting the helper list, and because we inject it via GIT_CONFIG_KEY_* (the env form of
    /// `-c`, the highest-precedence scope) the reset is applied last and clears helpers from every
    /// other scope, including a repo-local one. So `--get` legitimately exits 0 with an empty value.
    @Test("the credential helper is disabled", .enabled(if: !hermeticityDisabled))
    func credentialHelperDisabled() throws {
        let r = try Proc.run(["git", "config", "--get-all", "credential.helper"], cwd: try repo())
        let helpers = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(helpers.isEmpty, "a credential helper survived: \(helpers)")
    }

    @Test("prompts are disabled", .enabled(if: !hermeticityDisabled))
    func promptsDisabled() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_ASKPASS"] == "/usr/bin/false")
    }

    /// Cutting global config also takes away the developer's `user.name`/`user.email`, which several
    /// tests (and gen-slow-repo.sh) commit with. The bootstrap supplies a fixed identity instead, so
    /// committing must work in a repo where NO local identity was configured — and be authored by us,
    /// not by whoever is running the suite.
    @Test("a hermetic identity is supplied — commits work with no local git identity",
          .enabled(if: !hermeticityDisabled))
    func hermeticIdentity() throws {
        let dir = try repo()
        try Proc.checked(["git", "commit", "-q", "--allow-empty", "-m", "hermetic"], cwd: dir)

        let author = try Proc.checked(["git", "log", "-1", "--format=%ae"], cwd: dir)
        #expect(author.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "test@orchestra.invalid")
    }

    /// `init.defaultBranch` is inherited from the developer today; pin it so repos created without an
    /// explicit `-b` are deterministic across machines.
    @Test("the default branch is deterministic", .enabled(if: !hermeticityDisabled))
    func defaultBranchPinned() throws {
        let dir = try repo()
        try Proc.checked(["git", "commit", "-q", "--allow-empty", "-m", "c"], cwd: dir)
        let branch = try Proc.checked(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: dir)
        #expect(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }
}
