import Foundation

/// The one definition of "in scope" for a sync. Pure — no proc, no I/O. Builds the pathspecs a
/// caller (`SharedStore`, PR3) feeds to `add`, `ls-tree` and `diff`.
///
/// **Two guard queries, never one.** `ls-tree` rejects `:(exclude)` outright, and in `diff` an
/// exclude cancels every positive hole path it's paired with — so the out-of-set boundary
/// (`outsideQuery`) and the excluded holes inside the declared set (`holesQuery`) must travel as
/// separate queries, never merged into one pathspec. `ls-tree` also accepts only one tree-ish per
/// call: a query spanning two trees is two separate `ls-tree` calls, one tree-ish each — a second
/// tree-ish argument is silently read as a path, not as a second tree.
public enum DeclaredSet {
    public struct Result: Sendable, Equatable {
        /// Declared paths that exist in the working tree or the index, minus any un-ignored leaf.
        /// `add -f` exits 128 on a positive matching nothing, so a positive that doesn't exist is
        /// never staged.
        public let stagingPositives: [String]
        /// `stagingPositives` plus `:(exclude)` for each exclusion and each un-ignored leaf — what
        /// `add -f` stages.
        public let stagingPathspec: [String]
        /// `:(top)` plus `:(exclude)` for every declared path — for `diff`, which accepts pathspec
        /// magic. Lists everything outside the declared set.
        public let outsideQuery: [String]
        /// The exclusions as plain paths — for `ls-tree`/`diff`. Never combined with `outsideQuery`.
        /// **Empty when an item declares no exclusions — the caller must skip the call rather than
        /// run it.** An empty pathspec means "everything" to `ls-tree`/`diff`, not "nothing", so
        /// running either with an empty `holesQuery` would subtract every candidate — mirroring why
        /// `stagingPathspec`'s positives are skipped when there are none to stage.
        public let holesQuery: [String]

        public init(stagingPositives: [String], stagingPathspec: [String], outsideQuery: [String], holesQuery: [String]) {
            self.stagingPositives = stagingPositives
            self.stagingPathspec = stagingPathspec
            self.outsideQuery = outsideQuery
            self.holesQuery = holesQuery
        }
    }

    /// - Parameters:
    ///   - paths: declared paths of every `shared` item.
    ///   - exclusions: item exclusions — the holes inside a declared directory.
    ///   - unignoredLeaves: leaves not ignored in this checkout, found by `IgnoreProbe`.
    ///   - existsInWorkingTreeOrIndex: a pure predicate over an already-resolved path; the caller
    ///     supplies it (working tree `FileManager` check, or an index lookup) so this file stays
    ///     proc-free.
    public static func build(
        paths: [String], exclusions: [String], unignoredLeaves: Set<String>,
        existsInWorkingTreeOrIndex: (String) -> Bool
    ) -> Result {
        let positives = paths.filter { !unignoredLeaves.contains($0) && existsInWorkingTreeOrIndex($0) }
        let sortedLeaves = unignoredLeaves.sorted()
        let pathspec = positives + exclusions.map { ":(exclude)\($0)" } + sortedLeaves.map { ":(exclude)\($0)" }
        let outsideQuery = [":(top)"] + paths.map { ":(exclude)\($0)" }
        return Result(stagingPositives: positives, stagingPathspec: pathspec, outsideQuery: outsideQuery, holesQuery: exclusions)
    }
}
