import Foundation
import Testing
import OrchestraKit
import TestSupport
@testable import OrchestraCore

/// The lifecycle glue in `OrchestraService+Propagation.swift`: the Obsidian guard (G6, third writer), the
/// launch grant on an unanswerable probe, and the boot sweep's referenced-set wiring. `PropagationService`'s
/// own behavior is covered in `Propagation/PropagationServiceTests`.
@Suite("OrchestraService — propagation glue")
struct OrchestraServicePropagationTests {

    /// A fake for a repo checkout whose `check-ignore` answers per path: exit 0 for `ignored`, 128 for `broken`.
    private func fake(ignored: Set<String> = [], insideRepo: Bool = true, broken: Bool = false) -> FakeProc {
        let f = FakeProc()
        f.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in
            ProcResult(stdout: insideRepo ? "true\n" : "false\n", stderr: "", exitCode: 0)
        }
        f.on(["git", "check-ignore"]) { argv in
            if broken { return ProcResult(stdout: "", stderr: "fatal: boom", exitCode: 128) }
            // A path is ignored when it sits under an ignored directory (real git: `dir/` also matches children).
            let path = argv.last ?? ""
            return ProcResult(stdout: "", stderr: "", exitCode: ignored.contains { path == $0 || path.hasPrefix($0 + "/") } ? 0 : 1)
        }
        return f
    }

    @Test("Obsidian guard passes when .obsidian and .trash are both ignored")
    func guardPassesWhenIgnored() async throws {
        let env = TestEnv.make(proc: fake(ignored: [".obsidian", ".trash"]))
        try await env.svc.guardObsidianWrites(cwd: env.base)
    }

    @Test("Obsidian guard passes outside a repo")
    func guardPassesOutsideRepo() async throws {
        let env = TestEnv.make(proc: fake(insideRepo: false))
        try await env.svc.guardObsidianWrites(cwd: env.base)
    }

    @Test("Obsidian guard probes a child path, because a `dir/` pattern cannot match a directory that does not exist yet")
    func guardProbesChildren() async throws {
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        // Real git: bare `.obsidian` (absent dir, `.obsidian/` pattern) is NOT ignored; the child is.
        proc.on(["git", "check-ignore"]) { argv in
            ProcResult(stdout: "", stderr: "", exitCode: (argv.last ?? "").contains("/") ? 0 : 1)
        }
        let env = TestEnv.make(proc: proc)
        try await env.svc.guardObsidianWrites(cwd: env.base)
    }

    @Test("Obsidian guard throws, naming the path, when either directory is un-ignored")
    func guardThrowsWhenUnignored() async throws {
        for ignored in [Set<String>(), [".obsidian"], [".trash"]] {
            let env = TestEnv.make(proc: fake(ignored: ignored))
            let missing = ignored.contains(".obsidian") ? ".trash" : ".obsidian"
            await #expect(throws: OrchestraError.self) { try await env.svc.guardObsidianWrites(cwd: env.base) }
            do { try await env.svc.guardObsidianWrites(cwd: env.base) } catch {
                #expect("\(error)".contains(missing))
            }
        }
    }

    @Test("Obsidian guard checks the file it overwrites: `.obsidian/*` ignored but workspace.json re-included is refused")
    func guardChecksWorkspaceJson() async throws {
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        proc.on(["git", "check-ignore"]) { argv in
            let path = argv.last ?? ""
            // `.obsidian/*` + `!.obsidian/workspace.json`, and `.trash/` ignored.
            let ignored = path != ".obsidian/workspace.json"
            return ProcResult(stdout: "", stderr: "", exitCode: ignored ? 0 : 1)
        }
        let env = TestEnv.make(proc: proc)
        await #expect(throws: OrchestraError.self) { try await env.svc.guardObsidianWrites(cwd: env.base) }
        do { try await env.svc.guardObsidianWrites(cwd: env.base) } catch {
            #expect("\(error)".contains(".obsidian/workspace.json"))
        }
    }

    @Test("Obsidian guard throws when the ignore probe cannot answer")
    func guardThrowsOnUnknown() async throws {
        let env = TestEnv.make(proc: fake(broken: true))
        await #expect(throws: OrchestraError.self) { try await env.svc.guardObsidianWrites(cwd: env.base) }
    }

    @Test("launch grant: an unanswerable probe grants nothing; an ignored subset grants only that subset")
    func grantFollowsTheProbe() async throws {
        func card(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)) -> Task {
            Task(id: UUID(), title: "t", repo: "app", branch: "b", cwd: env.base, origin: .worktree,
                 model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                 phase: .launching, initialPrompt: "", archived: false)
        }
        let a = TestEnv.make(proc: fake(broken: true))
        a.adapter.launchWrites = [".stub/a", ".stub/b"]
        #expect(await a.svc.propagationGrant(for: card(a), adapter: a.adapter).writablePaths.isEmpty)

        let b = TestEnv.make(proc: fake(ignored: [".stub/b"]))
        b.adapter.launchWrites = [".stub/a", ".stub/b"]
        #expect(await b.svc.propagationGrant(for: card(b), adapter: b.adapter).writablePaths == [".stub/b"])

        let c = TestEnv.make(proc: fake(insideRepo: false))
        c.adapter.launchWrites = [".stub/a", ".stub/b"]
        #expect(await c.svc.propagationGrant(for: card(c), adapter: c.adapter).writablePaths == [".stub/a", ".stub/b"])
    }

    @Test("boot sweep keeps a git dir for an existing card cwd and removes one whose checkout is gone")
    func bootSweepUsesCardCwds() async throws {
        let env = TestEnv.make()
        let root = await env.svc.getConfig().sharedStoreRoot
        let fm = FileManager.default
        let liveDir = env.base + "/live-checkout"
        try fm.createDirectory(atPath: liveDir, withIntermediateDirectories: true)
        func gitDir(_ hash: String, records path: String) throws -> String {
            let d = "\(root)/repo/checkouts/\(hash).git"
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            try path.write(toFile: d + "/orchestra-checkout", atomically: true, encoding: .utf8)
            return d
        }
        let kept = try gitDir("aaaa", records: liveDir)
        let gone = try gitDir("bbbb", records: env.base + "/no-such-checkout")
        try await env.svc.store.create(Task(
            id: UUID(), title: "t", repo: "app", branch: "b", cwd: liveDir, origin: .worktree,
            model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
            phase: .launching, initialPrompt: "", archived: false))

        await env.svc.propagationBoot()

        #expect(fm.fileExists(atPath: kept))
        #expect(!fm.fileExists(atPath: gone))
    }

    @Test("boot sweep keeps the primary of a borrowed card whose repo field is empty")
    func bootSweepKeepsBorrowedPrimary() async throws {
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let fm = FileManager.default
        let primary = env.base + "/repos/app"
        let worktree = env.base + "/worktrees/app-wt"
        try fm.createDirectory(atPath: primary, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        // The borrowed cwd is inside a WORKTREE; only `rev-parse --git-common-dir` reveals the primary.
        proc.on(["git", "rev-parse", "--show-toplevel"]) { _ in
            ProcResult(stdout: "\(worktree)\n\(primary)/.git\n", stderr: "", exitCode: 0)
        }
        let root = await env.svc.getConfig().sharedStoreRoot
        let dir = "\(root)/repo/checkouts/cccc.git"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try primary.write(toFile: dir + "/orchestra-checkout", atomically: true, encoding: .utf8)
        try await env.svc.store.create(Task(
            id: UUID(), title: "t", repo: "", branch: "", cwd: worktree, origin: .borrowed,
            model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
            phase: .launching, initialPrompt: "", archived: false))

        await env.svc.propagationBoot()

        #expect(fm.fileExists(atPath: dir))
    }
}
