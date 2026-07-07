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
public protocol GhClient: Sendable {
    var available: Bool { get }
    func prState(repo: String, number: Int) -> PrState?
    /// The PR number whose head is `head` (for repairing a published child's base). nil if none/unknown.
    func prNumber(repo: String, head: String) -> Int?
    /// Repoint a published PR's base branch. Best-effort; false on any failure.
    func editBase(repo: String, number: Int, base: String) -> Bool
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

    public func prState(repo: String, number: Int) -> PrState? {
        guard let r = try? Proc.run(
            ["gh", "pr", "view", String(number), "--json", "state,mergedAt,mergeCommit,baseRefName"],
            cwd: repo, env: Self.env(), timeout: Self.timeout), r.ok,
            let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PrState.self, from: data)
    }

    public func prNumber(repo: String, head: String) -> Int? {
        struct Row: Decodable { let number: Int }
        guard let r = try? Proc.run(
            ["gh", "pr", "list", "--head", head, "--state", "open", "--json", "number", "--limit", "1"],
            cwd: repo, env: Self.env(), timeout: Self.timeout), r.ok,
            let data = r.stdout.data(using: .utf8),
            let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.first?.number
    }

    public func editBase(repo: String, number: Int, base: String) -> Bool {
        (try? Proc.run(["gh", "pr", "edit", String(number), "--base", base],
                       cwd: repo, env: Self.env(), timeout: Self.timeout))?.ok ?? false
    }
}
