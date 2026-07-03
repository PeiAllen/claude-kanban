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

        #expect(rows[0].full == "diff --git a/a.txt b/a.txt")
        #expect(rows[0].tone == .header)
        #expect(rows[1].full == "@@ -1,3 +1,3 @@")
        #expect(rows[1].tone == .hunk)
        #expect(rows[2].old == " context")
        #expect(rows[2].new == " context")
        #expect(rows[3].old == "-old one")
        #expect(rows[3].new == "+new one")
        #expect(rows[4].old == "-old two")
        #expect(rows[4].new == "+new two")
        #expect(rows[5].old == nil)
        #expect(rows[5].new == "+new three")
    }
}
