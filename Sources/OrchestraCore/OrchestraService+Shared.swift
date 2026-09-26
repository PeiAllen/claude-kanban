import Foundation
import OrchestraKit

/// The paths `orchestra shared adopt` takes when none are named: the three project files the
/// worktree-propagation migration untracks. Repo-relative.
public let sharedAdoptDefaultPaths = ["CLAUDE.md", "AGENTS.md", ".claude/commands/ship.md"]

/// Turns propagation outcomes into the wire result of the `shared` verb: `{op, outcome, paths, message}`.
/// `message` is the one line a CLI prints and an agent reads. Pure — no I/O.
enum SharedResult {
    static func make(op: String, outcome: String, paths: [String] = [], message: String,
                     extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["op": .string(op), "outcome": .string(outcome),
                                      "paths": .array(paths.map { .string($0) }), "message": .string(message)]
        o.merge(extra) { a, _ in a }
        return .object(o)
    }

    static func sync(_ outcome: SyncOutcome, op: String = "sync") -> JSONValue {
        func r(_ kind: String, _ msg: String, _ paths: [String] = []) -> JSONValue {
            make(op: op, outcome: kind, paths: paths, message: msg)
        }
        switch outcome {
        case .skipped(let why): return r("skipped", "This card takes no part in shared files (\(why)).")
        case .nothingShared: return r("nothingShared", "No item is shared for this repo. Nothing to do.")
        // A git older than 2.40 is a host fact, not a card fault: `flush` treats it as "nothing can be lost",
        // so the CLI's exit code does too. Its own outcome string lets a script tell it from a real stand-down.
        case .standDown(.gitTooOld): return r("gitTooOld", "Shared files are off: git is older than 2.40.")
        case .standDown(let why): return r("standDown", "Shared files stood down: \(standDown(why)).")
        case .busy: return r("busy", "A git lock is held. Run `orchestra shared sync` again in a moment.")
        case .completed(let receive, let send):
            return r("completed", "Synced. receive: \(receiveText(receive)). send: \(send.map(sendText) ?? "not sent").")
        case .conflicted(let paths, _): return r("conflicted", conflictText(paths), paths)
        case .partial(let dirty): return r("partial", PropagationService.partialText(dirty), dirty)
        case .refusedOutOfSet(let paths):
            return r("refusedOutOfSet", "Refused: these paths are outside the shared set: \(paths.joined(separator: ", ")).", paths)
        case .failed(let m): return r("failed", "Shared sync failed: \(m)")
        }
    }

    static func resolve(_ outcome: ResolveOutcome) -> JSONValue {
        switch outcome {
        case .resolved: return make(op: "resolve", outcome: "resolved", message: "Conflict resolved and sent to the store.")
        case .nothingToResolve: return make(op: "resolve", outcome: "nothingToResolve", message: "No conflict is standing.")
        case .refusedMarkers(let paths):
            return make(op: "resolve", outcome: "refusedMarkers", paths: paths,
                        message: "Refused: conflict markers remain in \(paths.joined(separator: ", ")). Edit the file, then run resolve again.")
        // Only `.conflicted` happens after HEAD advanced. `refusedOutOfSet` and `partial` return before any
        // commit, so the conflict still stands and the agent must not read them as a success.
        case .sendOutcome(.refusedOutOfSet(let p)):
            return make(op: "resolve", outcome: "refusedOutOfSet", paths: p,
                        message: "Not resolved: these paths are outside the shared set: \(p.joined(separator: ", ")). The conflict still stands.")
        case .sendOutcome(.partial(let dirty)):
            return make(op: "resolve", outcome: "partial", paths: dirty,
                        message: "Not resolved: \(PropagationService.partialText(dirty)) The conflict still stands.")
        case .sendOutcome(.conflicted(let p, _)):
            return make(op: "resolve", outcome: "resolvedThenConflicted", paths: p,
                        message: "Resolution committed, but the store changed again: \(conflictText(p))")
        case .sendOutcome(.pushed), .sendOutcome(.nothingToDo):
            return make(op: "resolve", outcome: "resolved", message: "Conflict resolved and sent to the store.")
        }
    }

    static func adopt(_ outcome: AdoptOutcome) -> JSONValue {
        switch outcome {
        case .adopted(let untracked):
            return make(op: "adopt", outcome: "adopted", paths: untracked,
                        message: untracked.isEmpty ? "Adopted. Nothing was tracked, so nothing was untracked."
                            : "Adopted. Staged `git rm --cached` for: \(untracked.joined(separator: ", ")). Commit it yourself.")
        case .stopped(let stop):
            let (kind, msg, paths): (String, String, [String]) = {
                switch stop {
                case .primarySyncFailed(let o): return ("primarySyncFailed", "Stopped: the primary's sync did not finish. The project is untouched. \(sync(o)["message"]?.stringValue ?? "")", [])
                case .negationRemains(let p): return ("negationRemains", "Stopped: a `!` line in an ignore file still re-includes \(p.joined(separator: ", ")). Remove it, then run adopt again.", p)
                case .policyLoadFailed: return ("policyLoadFailed", "Stopped: propagation.json is corrupt. It was not changed.", [])
                case .policySaveFailed: return ("policySaveFailed", "Stopped: propagation.json could not be saved.", [])
                case .projectGitFailed(let m): return ("projectGitFailed", "Stopped: git failed in the project. Nothing was committed. \(m)", [])
                case .notParticipating(let o): return ("notParticipating", "Stopped: this card takes no part in shared files. \(sync(o)["message"]?.stringValue ?? "")", [])
                }
            }()
            return make(op: "adopt", outcome: kind, paths: paths, message: msg)
        }
    }

    static func conflictText(_ paths: [String]) -> String {
        "Shared-file conflict in \(paths.joined(separator: ", ")). Edit the file to fix it, remove the markers, then run `orchestra shared resolve`."
    }

    private static func standDown(_ why: StandDownReason) -> String {
        switch why {
        case .mergeInProgress: return "a git merge is in progress in the store checkout"
        case .policyLoadFailed: return "propagation.json is corrupt"
        case .gitTooOld: return "git is older than 2.40"
        case .probeUnknown(let d): return "the ignore probe could not answer (\(d))"
        }
    }

    private static func receiveText(_ r: ReceiveOutcome) -> String {
        switch r {
        case .upToDate: return "up to date"
        case .materialized(let w, let d): return "wrote \(w.count), deleted \(d.count)"
        case .partial(let dirty): return "kept \(dirty.count) locally edited"
        case .conflicted(let p, _): return "conflict in \(p.joined(separator: ", "))"
        }
    }

    private static func sendText(_ s: SendOutcome) -> String {
        switch s {
        case .nothingToDo: return "nothing to send"
        case .pushed: return "sent"
        case .refusedOutOfSet(let p): return "refused out-of-set \(p.joined(separator: ", "))"
        case .conflicted(let p, _): return "conflict in \(p.joined(separator: ", "))"
        case .partial(let dirty): return "kept \(dirty.count) locally edited"
        }
    }
}

extension OrchestraService {
    /// The `shared` verb: one entry point per `op`, each a thin call into `PropagationService`.
    /// `status` is read-only and never attaches.
    public func shared(op: String, card: Task, paths: [String], source: ActivitySource) async throws -> JSONValue {
        do {
            switch op {
            case "sync":
                logCommand("shared sync", ref: card, source: source)
                return SharedResult.sync(await propagation.sync(card.cwd, card, .full))
            case "status":
                return Self.statusJSON(try await propagation.status(card))
            case "resolve":
                logCommand("shared resolve", ref: card, source: source)
                return SharedResult.resolve(try await propagation.resolve(card))
            case "adopt":
                // `adopt` writes the project repo (`.gitignore`, the index) and the policy table, so a
                // read-only card cannot ask the daemon to do it for them.
                guard card.access != .readOnly else {
                    throw OrchestraError.invalidParams("a read-only card cannot adopt: adopt edits the project repo")
                }
                let chosen = paths.isEmpty ? sharedAdoptDefaultPaths : paths
                try Self.validateAdoptPaths(chosen)
                logCommand("shared adopt", ref: card, source: source)
                // Inherit the carve-outs of every adapter item that overlaps the path, so adopting `.claude`
                // never untracks `.claude/skills` or the other per-worktree state the adapter excludes.
                let adapterItems = registry.list().flatMap(\.projectFiles)
                let items = chosen.map { path in
                    let inherited = adapterItems.flatMap(\.exclusions).filter {
                        PropagationService.isUnder($0, path) || PropagationService.isUnder(path, $0)
                    }
                    return PropagationItem(name: path, paths: [path], exclusions: Array(Set(inherited)).sorted())
                }
                return SharedResult.adopt(await propagation.adopt(items: items, from: card))
            default:
                throw OrchestraError.invalidParams("op must be sync, status, resolve or adopt")
            }
        } catch let e as PropagationServiceError {
            switch e {
            case .notParticipating(let o):
                // A state, not a bad param: answer in the same shape `sync` uses for the same card.
                return SharedResult.sync(o, op: op)
            case .storeFailed(let m): throw OrchestraError.io(m)
            }
        }
    }

    static let adoptMaxPaths = 32

    /// `adopt` walks each path and probes every leaf, so an untrusted path must be a plain repo-relative
    /// file or directory: not `.`, not `..`, not absolute, no empty component (`a//b`, `a/`).
    static func validateAdoptPaths(_ paths: [String]) throws {
        guard paths.count <= adoptMaxPaths else {
            throw OrchestraError.invalidParams("adopt takes at most \(adoptMaxPaths) paths")
        }
        for p in paths {
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            if p.isEmpty || p.hasPrefix("/") || p.contains("\0") || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw OrchestraError.invalidParams("adopt path must be repo-relative, with no '.', '..' or empty component: \(p)")
            }
        }
    }

    static func statusJSON(_ s: PropagationStatus) -> JSONValue {
        let items = s.items.map { i in
            JSONValue.object(["name": .string(i.name), "policy": .string(i.policy.rawValue),
                              "paths": .array(i.paths.map { .string($0) })])
        }
        var extra: [String: JSONValue] = [
            "repo": .string(s.repo), "items": .array(items),
            "unignoredLeaves": .array(s.unignoredLeaves.map { .string($0) }),
        ]
        if let c = s.conflict { extra["conflict"] = .object(["paths": .array(c.paths.map { .string($0) }), "storeSha": .string(c.storeSha)]) }
        if let cmd = s.readCommand { extra["readCommand"] = .string(cmd) }
        let msg = s.conflict.map { SharedResult.conflictText($0.paths) } ?? "No conflict is standing."
        return SharedResult.make(op: "status", outcome: s.conflict == nil ? "clean" : "conflicted",
                                 paths: s.conflict?.paths ?? [], message: msg, extra: extra)
    }

    /// The `shared-policy` verb (app only): the repo's item table, one item's row, or the row after a change.
    public func sharedPolicy(repo rawRepo: String, item: String?, policy rawPolicy: String?) async throws -> JSONValue {
        let repo = try resolver.resolveRepo(rawRepo)
        let path = config.propagationPath
        let loaded = PropagationStore.load(path: path)
        guard var repoPolicy = loaded.repoPolicy(for: repo) else {
            throw OrchestraError.io("propagation.json is corrupt; it was not changed")
        }
        let adapterItems = registry.list().flatMap(\.projectFiles)
        func row(_ i: PropagationItem, _ p: PropagationPolicy) -> JSONValue {
            .object(["item": .string(i.name), "policy": .string(p.rawValue),
                     "paths": .array(i.paths.map { .string($0) })])
        }
        let items = repoPolicy.mergedItems(withAdapterItems: adapterItems)
        guard let itemName = item else {
            return .object(["repo": .string(repo),
                            "items": .array(items.map { row($0, repoPolicy.policy(for: $0.name)) })])
        }
        guard let found = items.first(where: { $0.name == itemName }) else {
            throw OrchestraError.invalidParams("unknown item: \(itemName)")
        }
        guard let rawPolicy else { return row(found, repoPolicy.policy(for: itemName)) }
        guard let newPolicy = PropagationPolicy(rawValue: rawPolicy) else {
            throw OrchestraError.invalidParams("policy must be tracked, shared or ephemeral")
        }
        repoPolicy.overrides[itemName] = newPolicy
        var table = loaded.table
        table[repo] = repoPolicy
        guard PropagationStore.save(table, path: path) else { throw OrchestraError.io("propagation.json could not be saved") }
        return row(found, newPolicy)
    }

    /// The card whose canonical cwd contains `cwd` (the deepest match). Used by the CLI when neither a ref
    /// nor `ORCHESTRA_TASK_ID` is given.
    public static func cardContaining(cwd: String, in tasks: [Task]) -> Task? {
        let here = PathResolver.canonical(cwd)
        return tasks.filter { t in
            let root = PathResolver.canonical(t.cwd)
            return !root.isEmpty && (here == root || here.hasPrefix(root + "/"))
        }.max { PathResolver.canonical($0.cwd).count < PathResolver.canonical($1.cwd).count }
    }
}
