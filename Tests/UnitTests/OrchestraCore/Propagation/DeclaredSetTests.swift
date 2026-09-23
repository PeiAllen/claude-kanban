import Foundation
import Testing
@testable import OrchestraCore

@Suite("DeclaredSet — the one definition of in scope")
struct DeclaredSetTests {
    @Test("a declared path absent from both working tree and index is dropped from positives")
    func absentPathDroppedFromPositives() {
        // Pins: add -f exits 128 on a positive matching nothing, so a positive must never be
        // constructed from a path that doesn't exist anywhere.
        let result = DeclaredSet.build(
            paths: ["CLAUDE.md", "ghost.md"], exclusions: [], unignoredLeaves: [],
            existsInWorkingTreeOrIndex: { $0 == "CLAUDE.md" })
        #expect(result.stagingPositives == ["CLAUDE.md"])
    }

    @Test("an un-ignored leaf is dropped from positives and added as an exclude")
    func unignoredLeafDroppedAndExcluded() {
        let result = DeclaredSet.build(
            paths: [".claude/settings.json"], exclusions: [], unignoredLeaves: [".claude/settings.json"],
            existsInWorkingTreeOrIndex: { _ in true })
        #expect(result.stagingPositives.isEmpty)
        #expect(result.stagingPathspec.contains(":(exclude).claude/settings.json"))
    }

    @Test("a literal fixture's declared paths and exclusions round-trip through the pathspec builder")
    func literalFixtureRoundTrips() {
        // Deliberately our own literal fixture, not Claude's real declared set — that belongs to
        // PR5, and reading it here would make this PR depend on the parallel-wave adapter PR.
        let paths = ["fixture-dir", "fixture.md"]
        let exclusions = ["fixture-dir/excluded-child"]
        let result = DeclaredSet.build(
            paths: paths, exclusions: exclusions, unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })

        #expect(result.stagingPositives == paths)
        #expect(result.stagingPathspec == paths + [":(exclude)fixture-dir/excluded-child"])
        #expect(Set(result.outsideQuery) == [":(top)", ":(exclude)fixture-dir", ":(exclude)fixture.md"])
        #expect(result.holesQuery == exclusions)
    }

    @Test("outside-query is :(top) plus one exclude per declared path, as a set")
    func outsideQueryIsTopPlusExcludesPerPath() {
        let paths = ["b.md", "a.md", "c.md"]
        let result = DeclaredSet.build(paths: paths, exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        // Order-independent: git ignores pathspec order.
        #expect(Set(result.outsideQuery) == Set([":(top)"] + paths.map { ":(exclude)\($0)" }))
    }

    @Test("holes-query is the exclusions as plain paths, never merged into the outside-query")
    func holesQueryNeverMergedIntoOutsideQuery() {
        let exclusions = [".claude/skills", ".claude/.cc-writes"]
        let result = DeclaredSet.build(paths: [".claude"], exclusions: exclusions, unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        #expect(result.holesQuery == exclusions)
        // holesQuery carries no pathspec magic, and outsideQuery never contains a bare exclusion path.
        for hole in exclusions {
            #expect(!result.holesQuery.contains(":(exclude)\(hole)"))
            #expect(!result.outsideQuery.contains(hole))
        }
    }

    @Test("stagingPathspec orders positives before exclusion excludes before leaf excludes")
    func stagingPathspecOrder() {
        let result = DeclaredSet.build(
            paths: ["a.md"], exclusions: ["hole.md"], unignoredLeaves: ["leaf.md"],
            existsInWorkingTreeOrIndex: { _ in true })
        #expect(result.stagingPathspec == ["a.md", ":(exclude)hole.md", ":(exclude)leaf.md"])
    }

    @Test("no positives yields an empty staging pathspec when there are no exclusions or leaves either")
    func emptyWhenNothingDeclared() {
        let result = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        #expect(result.stagingPositives.isEmpty)
        #expect(result.stagingPathspec.isEmpty)
        #expect(result.outsideQuery == [":(top)"])
        #expect(result.holesQuery.isEmpty)
    }
}
