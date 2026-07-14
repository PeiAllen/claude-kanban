import Foundation

/// Tri-state remote-tip result — a deleted branch (`gone`, exit 0 + empty) is NEVER conflated with a
/// network/auth failure (`unavailable`, any error). The watch loop treats them differently: `gone`
/// feeds the merge-heuristic ladder; `unavailable` just backs off.
public enum RemoteTip: Equatable, Sendable {
    case oid(String)
    case gone
    case unavailable
}

/// The isolated remote-git tier: private-ref fetches + `ls-remote` tip probes, hardened so a daemon
/// never blocks on a credential prompt. Every remote call runs with `GIT_TERMINAL_PROMPT=0` +
/// `GIT_ASKPASS=/usr/bin/false` and a timeout. All ops are `proc.run(["git","-C",repo,…])` through
/// the injected `ProcRunning` seam (no default — a test must choose `RealProc` or a fake explicitly).
public actor RemoteParents {
    private let proc: any ProcRunning
    public init(proc: any ProcRunning) { self.proc = proc }

    /// The env that neuters every interactive credential path (terminal prompt + askpass helper).
    public static func remoteEnv() -> [String: String] {
        ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false"]
    }
    private static let timeout: Duration = .seconds(20)

    /// Copy `ref` from `origin` into `refs/orch/parents/<name>` with a `+` (force) refspec so a remote
    /// history rewrite is mirrored rather than rejected. Returns the fetched OID. Throws a classified
    /// `.io` on failure (never hangs — timeout + no prompts). `context` is the caller's WHAT-failed object
    /// (e.g. "could not fetch remote parent pr#7") so the surfaced error names the operation, git's own
    /// stderr, and the runnable recovery in one line.
    public func fetch(repo: String, _ ref: RemoteParentRef, context: String? = nil) async throws -> String {
        let object = context ?? "could not fetch remote parent \(ref.canonical)"
        let refspec = "+\(ref.remoteSrc):\(ref.privateRef)"
        let r = try await proc.run(["git", "-C", repo, "fetch", "--no-tags", ref.remoteName, refspec],
                                   cwd: nil, env: Self.remoteEnv(), timeout: Self.timeout)
        guard r.ok else {
            throw OrchestraError.gitIO(object, stderr: r.stderr,
                                       recovery: "check the remote/PR exists and you have access")
        }
        let v = try await proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref.privateRef],
                                   cwd: nil, env: [:], timeout: .seconds(120))
        let oid = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.ok, !oid.isEmpty else {
            throw OrchestraError.io("fetched \(ref.privateRef) but could not resolve its OID — re-run set-parent")
        }
        return oid
    }

    /// `git ls-remote origin <src>` → the tip OID, `.gone` (branch/PR head deleted), or `.unavailable`
    /// (any error: the daemon must not mistake an auth failure for a deletion).
    public func lsRemoteTip(repo: String, _ ref: RemoteParentRef) async -> RemoteTip {
        guard let r = try? await proc.run(["git", "-C", repo, "ls-remote", ref.remoteName, ref.remoteSrc],
                                          cwd: nil, env: Self.remoteEnv(), timeout: Self.timeout) else {
            return .unavailable
        }
        guard r.ok else { return .unavailable }
        let line = r.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let oid = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
        return oid.isEmpty ? .gone : .oid(oid)
    }
}
