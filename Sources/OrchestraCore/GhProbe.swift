import Foundation

/// A pull request's merge state, decoded from `gh pr view --json state,mergedAt,mergeCommit,baseRefName`.
public struct PrState: Decodable, Equatable, Sendable {
    public struct MergeCommit: Decodable, Equatable, Sendable { public let oid: String? }
    public let state: String            // "OPEN" | "MERGED" | "CLOSED"
    public let mergedAt: String?
    public let mergeCommit: MergeCommit?
    public let baseRefName: String      // the branch the PR targets (the grandparent on merge)

    public init(state: String, mergedAt: String?, mergeCommit: MergeCommit?, baseRefName: String) {
        self.state = state; self.mergedAt = mergedAt; self.mergeCommit = mergeCommit; self.baseRefName = baseRefName
    }

    /// GitHub marks a squash/rebase/merge landing as `state == MERGED` (squash-proof — unlike an
    /// ancestry check). `mergedAt` is a redundant belt-and-braces signal.
    public var merged: Bool { state == "MERGED" || mergedAt != nil }
}

/// The `gh` boundary, behind a protocol so the ladder is testable with `FakeGh` and `gh`'s absence is a
/// tier, not a mock gap. NEVER a hard dependency: `available == false` degrades the ladder one step.
///
/// The network methods are **async** (S1-5): each `gh` call is a network round-trip that blocks its
/// thread up to 20 s (40 s on a redirect). When they ran synchronously inside the `OrchestraService`
/// actor, every list/spawn/send/inspector RPC stalled behind a watch tick's `gh` round-trip. The real
/// probe now hops the blocking `Proc.run` onto a detached task, so awaiting it suspends — never blocks —
/// the actor. `available` stays sync: it's a local `which gh`, not a network call.
public protocol GhClient: Sendable {
    var available: Bool { get }
    func prState(repo: String, number: Int) async -> PrState?
    /// The PR number whose head is `head` (for repairing a published child's base). nil if none/unknown.
    func prNumber(repo: String, head: String) async -> Int?
    /// Repoint a published PR's base branch. Best-effort; false on any failure.
    func editBase(repo: String, number: Int, base: String) async -> Bool
}

/// The real probe. `repo` is a filesystem path; `gh` infers the slug from the repo's `origin`, so every
/// call runs with `cwd: repo`. Hardened env (no credential prompts). Any failure ⇒ nil/false (the ladder
/// degrades a tier rather than throwing into the watch loop).
public struct GhProbe: GhClient {
    public init() {}

    public static var toolAvailable: Bool { Proc.toolExists("gh") }
    public var available: Bool { Self.toolAvailable }

    private static func env() -> [String: String] {
        RemoteParents.remoteEnv().merging(["GH_PROMPT_DISABLED": "1"]) { a, _ in a }
    }
    private static let timeout: Duration = .seconds(20)

    /// Run a blocking `Proc.run` off the caller's actor on a detached task, so a 20 s `gh` round-trip
    /// never blocks the service actor (S1-5). Failures surface as nil, mapped by the caller.
    private static func runOffActor(_ argv: [String], cwd: String) async -> ProcResult? {
        await _Concurrency.Task.detached(priority: .utility) {
            try? Proc.run(argv, cwd: cwd, env: env(), timeout: timeout)
        }.value
    }

    public func prState(repo: String, number: Int) async -> PrState? {
        guard let r = await Self.runOffActor(
            ["gh", "pr", "view", String(number), "--json", "state,mergedAt,mergeCommit,baseRefName"],
            cwd: repo), r.ok, let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PrState.self, from: data)
    }

    public func prNumber(repo: String, head: String) async -> Int? {
        struct Row: Decodable { let number: Int }
        guard let r = await Self.runOffActor(
            ["gh", "pr", "list", "--head", head, "--state", "open", "--json", "number", "--limit", "1"],
            cwd: repo), r.ok, let data = r.stdout.data(using: .utf8),
            let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.first?.number
    }

    public func editBase(repo: String, number: Int, base: String) async -> Bool {
        (await Self.runOffActor(["gh", "pr", "edit", String(number), "--base", base], cwd: repo))?.ok ?? false
    }
}
