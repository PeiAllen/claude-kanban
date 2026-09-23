import Foundation
import Testing
@testable import OrchestraCore

@Suite("StoreGit — hermetic argv/env builder")
struct StoreGitTests {
    private let gitDir = "/repo/.orchestra-store.git"
    private let workTree = "/repo/checkout"
    private let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    @Test("every invocation sets all eleven environment variables, including a pinned C locale")
    func setsAllElevenEnvVars() {
        let inv = StoreGit.invocation(gitDir: gitDir, workTree: workTree, emptyTreeHash: emptyTreeHash, extraArgs: ["status"])
        #expect(inv.env["GIT_DIR"] == gitDir)
        #expect(inv.env["GIT_WORK_TREE"] == workTree)
        #expect(inv.env["GIT_INDEX_FILE"] == gitDir + "/index")
        #expect(inv.env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(inv.env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(inv.env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(inv.env["GIT_PAGER"] == "cat")
        #expect(inv.env["GIT_EDITOR"] == "true")
        #expect(inv.env["GIT_OPTIONAL_LOCKS"] == "0")
        // LC_ALL/LANG pinned to C: send/receive classify git's result by matching English stderr
        // substrings ("[rejected]", "non-fast-forward", "unrelated histories", …). A gettext-
        // enabled git (the Linux daemon cross-build target, not macOS) under a translated locale
        // would silently misroute every one of those branches without this pin.
        #expect(inv.env["LC_ALL"] == "C")
        #expect(inv.env["LANG"] == "C")
        #expect(inv.env.count == 11)
    }

    @Test("cwd is always the checkout, so relative hash-object calls resolve correctly")
    func cwdIsCheckout() {
        let inv = StoreGit.invocation(gitDir: gitDir, workTree: workTree, emptyTreeHash: emptyTreeHash, extraArgs: ["status"])
        #expect(inv.cwd == workTree)
    }

    @Test("argv carries --attr-source and the six -c pins, including core.fsmonitor=false")
    func argvCarriesAttrSourceAndPins() {
        let inv = StoreGit.invocation(gitDir: gitDir, workTree: workTree, emptyTreeHash: emptyTreeHash, extraArgs: ["status"])
        #expect(inv.argv.first == "git")
        #expect(inv.argv.contains("--attr-source=\(emptyTreeHash)"))
        let pins = [
            "user.name=Orchestra", "user.email=orchestra@localhost", "commit.gpgsign=false",
            "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.autocrlf=false",
        ]
        for pin in pins {
            #expect(inv.argv.contains(pin), "missing -c \(pin)")
        }
        #expect(inv.argv.filter { $0 == "-c" }.count == pins.count)
    }

    @Test("extraArgs land after the hermetic prefix, in order")
    func extraArgsAppendedInOrder() {
        let inv = StoreGit.invocation(
            gitDir: gitDir, workTree: workTree, emptyTreeHash: emptyTreeHash,
            extraArgs: ["fetch", "/path/to/store.git", "main:refs/remotes/store/main"])
        #expect(inv.argv.suffix(3) == ["fetch", "/path/to/store.git", "main:refs/remotes/store/main"])
    }

    // `StoreGit` owns no fetch/push convenience method and never constructs a URL itself — it only
    // appends whatever `extraArgs` the caller supplies (pinned above by
    // `extraArgsAppendedInOrder`). Whether a real `fetch`/`push` call actually names the store by
    // explicit URL is `SharedStore`'s contract (PR3), not this file's.

    @Test("the empty-tree argv is exposed for the caller to compute, never hard-coded in StoreGit")
    func emptyTreeArgvExposed() {
        // /dev/null positionally, not --stdin: ProcRunning/FakeProc has no stdin parameter, and
        // this exact argv is verified (docs/09) to produce git's well-known empty-tree hash without
        // needing -w to persist the object first.
        #expect(StoreGit.emptyTreeHashArgv == ["git", "hash-object", "-t", "tree", "/dev/null"])
    }

    @Test("version check argv")
    func versionCheckArgv() {
        #expect(StoreGit.versionCheckArgv == ["git", "version"])
    }

    @Test("meetsMinimumVersion gates correctly at the 2.40 floor")
    func versionGating() {
        #expect(StoreGit.meetsMinimumVersion("git version 2.40.0") == true)
        #expect(StoreGit.meetsMinimumVersion("git version 2.50.1") == true)
        #expect(StoreGit.meetsMinimumVersion("git version 2.39.5") == false)
        #expect(StoreGit.meetsMinimumVersion("git version 2.38.0") == false)
        #expect(StoreGit.meetsMinimumVersion("git version 3.0.0") == true)
    }

    @Test("meetsMinimumVersion parses a platform suffix")
    func versionGatingPlatformSuffix() {
        #expect(StoreGit.meetsMinimumVersion("git version 2.50.1 (Apple Git-154)") == true)
    }

    @Test("meetsMinimumVersion fails closed on malformed output")
    func versionGatingMalformed() {
        #expect(StoreGit.meetsMinimumVersion("") == false)
        #expect(StoreGit.meetsMinimumVersion("not a git version string") == false)
    }
}
