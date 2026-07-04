import Testing
@testable import OrchestraCore

@Suite("Diff text parser — file sections and split rows")
struct DiffTextParserTests {
    @Test("parse splits files and counts changed lines")
    func parseFilesAndCounts() {
        let escape = "\u{1B}"
        let text = [
            "\(escape)[1mdiff --git a/App/One.swift b/App/One.swift\(escape)[m",
            "index 111..222 100644",
            "--- a/App/One.swift",
            "+++ b/App/One.swift",
            "@@ -1,2 +1,3 @@",
            " keep",
            "-old",
            "+new",
            "+added",
            "\(escape)[1mdiff --git a/App/Two.swift b/App/Two.swift\(escape)[m",
            "--- a/App/Two.swift",
            "+++ b/App/Two.swift",
            "@@ -4,2 +4,1 @@",
            "-gone",
            " same",
        ].joined(separator: "\n")

        let files = DiffFileParser.parse(text)

        #expect(files.map(\.title) == ["App/One.swift", "App/Two.swift"])
        #expect(files.map(\.additions) == [2, 0])
        #expect(files.map(\.deletions) == [1, 1])
        #expect(files.map(\.hunks) == [1, 1])
    }

    @Test("rows carry kinds, computed line numbers, and stripped text; metadata is dropped")
    func rowsComputeLineNumbers() {
        let rows = DiffRows.make([
            "diff --git a/a.txt b/a.txt",
            "index 111..222 100644",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -10,4 +10,5 @@ func greet() {",
            " keep",
            "-old",
            "+new",
            "+added",
            " tail",
        ])

        // Metadata (diff --git / index / --- / +++) is never rendered.
        #expect(rows.map(\.kind) == [.hunk, .context, .remove, .add, .add, .context])
        // Hunk divider carries the section heading, no line numbers.
        #expect(rows[0].text == "func greet() {")
        #expect(rows[0].oldNum == nil && rows[0].newNum == nil)
        // Leading +/-/space is stripped from the code text.
        #expect(rows.map(\.text) == ["func greet() {", "keep", "old", "new", "added", "tail"])
        // Line numbers advance per side: old skips additions, new skips removals.
        #expect(rows.map(\.oldNum) == [nil, 10, 11, nil, nil, 12])
        #expect(rows.map(\.newNum) == [nil, 10, nil, 11, 12, 13])
    }

    @Test("split rows pair removals and additions by position")
    func splitRowsPairChanges() {
        let rows = DiffSplitRows.make([
            "diff --git a/a.txt b/a.txt",
            "@@ -1,3 +1,3 @@",
            " context",
            "-old one",
            "-old two",
            "+new one",
            "+new two",
            "+new three",
        ])

        #expect(rows[0].kind == .hunk)
        #expect(rows[1].kind == .context)
        #expect(rows[1].oldText == "context" && rows[1].newText == "context")
        #expect(rows[1].oldNum == 1 && rows[1].newNum == 1)
        #expect(rows[2].kind == .change)
        #expect(rows[2].oldText == "old one" && rows[2].newText == "new one")
        #expect(rows[3].oldText == "old two" && rows[3].newText == "new two")
        // Third addition has no removal to pair with — the old side is a blank cell.
        #expect(rows[4].oldText == nil && rows[4].newText == "new three")
        #expect(rows[4].newNum == 4)
    }
}
